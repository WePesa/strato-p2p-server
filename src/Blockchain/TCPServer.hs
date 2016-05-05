{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}

module Blockchain.TCPServer (
  runEthServer
  ) where

import           Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Network
import qualified Data.Conduit.Binary as CB
import qualified Network.Socket as S

import           Control.Applicative
import           Control.Monad
import           Control.Exception

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import           Blockchain.Data.RLP
import           Blockchain.Data.Wire
import           Blockchain.Frame
import           Blockchain.ModTMChan
import           Blockchain.UDPServer
import           Blockchain.BlockNotify
import           Blockchain.RawTXNotify
import           Blockchain.RLPx
import           Blockchain.Util

import qualified Data.ByteString.Lazy as BL

import           Data.Maybe
import           Control.Monad.State
import           Prelude 

import           Crypto.PubKey.ECC.DH

import qualified Database.Persist.Postgresql as SQL
import System.Log.Logger



import           Blockchain.Data.DataDefs

import           Blockchain.P2PUtil
import           Control.Concurrent.Async.Lifted

import           Blockchain.ServOptions
    
runEthServer :: (MonadResource m, MonadIO m, MonadBaseControl IO m) 
             => SQL.ConnectionString     
             -> PrivateNumber
             -> Int
             -> m ()
runEthServer connStr myPriv listenPort = do  
    cxt <- initContextLite connStr

    liftIO $ createTXTrigger (notifHandler1 cxt)
    liftIO $ createBlockTrigger (notifHandler2 cxt)
    if flags_runUDPServer 
      then do
        liftIO $ errorM "p2pServer" "Starting UDP server"
        _ <- liftIO $ async $ S.withSocketsDo $ bracket (connectMe listenPort) S.sClose (runEthUDPServer cxt myPriv)
        return ()
      else liftIO $ errorM "p2pServer" "UDP server disabled"
       
    liftIO $ runTCPServer (serverSettings listenPort "*") $ \app -> do
      errorM "p2pServer" $ "|||| Incoming connection from " ++ show (appSockAddr app)
      peer <- fmap fst $ runResourceT $ flip runStateT cxt $ getPeerByIP (sockAddrToIP $ appSockAddr app)
      let unwrappedPeer = case (SQL.entityVal <$> peer) of 
                            Nothing -> error "peer is nothing after call to getPeerByIP"
                            Just peer' -> peer'
                          
      (_, (outCxt, inCxt)) <-
            appSource app $$+
            ethCryptAccept myPriv (pPeerPubkey unwrappedPeer) `fuseUpstream`
            appSink app

      runEthCryptMLite cxt $ runResourceT $ do
        let rSource = appSource app
            txSource = txNotificationSource (liteSQLDB cxt) 
                      =$= CL.map (Notif . TransactionNotification)
            blockSource = blockNotificationSource (liteSQLDB cxt) 
                      =$= CL.map (Notif . uncurry BlockNotification)

        eventSource <- mergeSources [
          rSource =$=
          appSource app =$=
          ethDecrypt inCxt =$=
          transPipe liftIO bytesToMessages =$=
          -- tap (displayMessage False) =$=
          CL.map EthMessage,
          blockSource,
          txSource
          ] 2


        liftIO $ errorM "p2pServer" "server session starting"

        eventSource =$=
          handleMsgConduit (pPeerPubkey unwrappedPeer) (show $ appSockAddr app) =$=
          --transPipe liftIO (tap (displayMessage True)) =$=
          messagesToBytes =$=
          ethEncrypt outCxt $$
          transPipe liftIO (appSink app)

        liftIO $ errorM "p2pServer" "server session ended"

--cbSafeTake::Monad m=>Int->Consumer B.ByteString m B.ByteString
cbSafeTake::Monad m=>Int->ConduitM BC.ByteString o m BC.ByteString
cbSafeTake i = do
  ret <- fmap BL.toStrict $ CB.take i
  if B.length ret /= i
    then error "safeTake: not enough data"
    else return ret
                                             
getRLPData::Monad m=>Consumer B.ByteString m B.ByteString
getRLPData = do
  first <- fmap (fromMaybe $ error "no rlp data") CB.head
  case first of
   x | x < 128 -> return $ B.singleton x
   x | x >= 192 && x <= 192+55 -> do
         rest <- cbSafeTake $ fromIntegral $ x - 192
         return $ x `B.cons` rest
   x | x >= 0xF8 && x <= 0xFF -> do
         length' <- cbSafeTake $ fromIntegral x-0xF7
         rest <- cbSafeTake $ fromIntegral $ bytes2Integer $ B.unpack length'
         return $ x `B.cons` length' `B.append` rest
   x -> error $ "missing case in getRLPData: " ++ show x


bytesToMessages::Conduit B.ByteString IO Message
bytesToMessages = forever $ do
    msgTypeData <- cbSafeTake 1
    let word = fromInteger (rlpDecode $ rlpDeserialize msgTypeData::Integer)

    objBytes <- getRLPData
    yield $ obj2WireMessage word $ rlpDeserialize objBytes

messagesToBytes::Monad m=>Conduit Message m B.ByteString
messagesToBytes = do
    maybeMsg <- await
    case maybeMsg of
     Nothing -> return ()
     Just msg -> do
        let (theWord, o) = wireMessage2Obj msg
        yield $ theWord `B.cons` rlpSerialize o
        messagesToBytes
