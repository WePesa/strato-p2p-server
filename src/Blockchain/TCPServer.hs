{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}

module Blockchain.TCPServer (
  runEthServer,
  tcpHandshakeServer  
  ) where

import           Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Network
import qualified Data.Conduit.Binary as CBN
import qualified Data.Conduit.Binary as CB
import qualified Network.Socket as S
import           Network.Haskoin.Crypto 

import           Control.Applicative
import           Control.Monad
import           Control.Exception

import qualified Data.Binary as BN
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import           Blockchain.ExtWord
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Data.RLP
import           Blockchain.Data.Wire
import           Blockchain.Frame
import           Blockchain.Handshake
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
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3
import           Crypto.Cipher.AES
import qualified Network.Haskoin.Internals as H

import           Data.Bits
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
                          
      (x, (outCxt, inCxt)) <-
            appSource app $$+
            ethCryptAccept myPriv (pPeerPubkey unwrappedPeer) `fuseUpstream`
            appSink app

      runEthCryptMLite cxt EthCryptStateLite{peerId=pPeerPubkey unwrappedPeer} $ runResourceT $ do
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
          handleMsgConduit (show $ appSockAddr app) =$=
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

--This must exist somewhere already
tap::MonadIO m=>(a->m ())->Conduit a m a
tap f = do
  awaitForever $ \x -> do
    lift $ f x
    yield x

                          

tcpHandshakeServer :: PrivateNumber 
                   -> Point 
                   -> ConduitM B.ByteString B.ByteString IO EthCryptStateLite
tcpHandshakeServer prv otherPoint = go
  where
  go = do
    hsBytes <- CBN.take 307
    
    let eceisMsgIncoming = (BN.decode $ hsBytes :: ECEISMessage)
        eceisMsgIBytes = (decryptECEIS prv eceisMsgIncoming )
        iv = B.replicate 16 0     
    
    let SharedKey sharedKey = getShared theCurve prv otherPoint
        otherNonce = B.take 32 $ B.drop 161 $ eceisMsgIBytes
        msg = fromIntegral sharedKey `xor` (bytesToWord256 $ B.unpack otherNonce)
        r = bytesToWord256 $ B.unpack $ B.take 32 $ eceisMsgIBytes
        s = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 32 $ eceisMsgIBytes
        v = head . B.unpack $ B.take 1 $ B.drop 64 eceisMsgIBytes
        yIsOdd = v == 1

        extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd
        otherEphemeral = hPubKeyToPubKey $ 
                            fromMaybe (error "malformed signature in tcpHandshakeServer") $ 
                            getPubKeyFromSignature extSig msg


    entropyPool <- liftIO createEntropyPool
    let g = cprgCreate entropyPool :: SystemRNG
        (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1
        myEphemeral = calculatePublic theCurve myPriv
        myNonce = 25 :: Word256 
        ackMsg = AckMessage { ackEphemeralPubKey=myEphemeral, ackNonce=myNonce, ackKnownPeer=False } 
        eceisMsgOutgoing = encryptECEIS myPriv otherPoint iv ( BL.toStrict $ BN.encode $ ackMsg )
        eceisMsgOBytes = BL.toStrict $ BN.encode eceisMsgOutgoing
            
    yield $ eceisMsgOBytes

    let SharedKey ephemeralSharedSecret = getShared theCurve myPriv otherEphemeral
        ephemeralSharedSecretBytes = intToBytes ephemeralSharedSecret
  
        myNonceBS = B.pack $ word256ToBytes myNonce
        frameDecKey = otherNonce `add` 
                        myNonceBS `add` 
                        (B.pack ephemeralSharedSecretBytes) `add` 
                        (B.pack ephemeralSharedSecretBytes)
        macEncKey = frameDecKey `add` (B.pack ephemeralSharedSecretBytes)
        
    let cState =
          EthCryptStateLite {
            peerId = calculatePublic theCurve prv
{-            encryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
            decryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
            egressMAC=SHA3.update (SHA3.init 256) $
                     (macEncKey `bXor` otherNonce) `B.append` eceisMsgOBytes,
            egressKey=macEncKey,
            ingressMAC=SHA3.update (SHA3.init 256) $ 
                     (macEncKey `bXor` myNonceBS) `B.append` (BL.toStrict hsBytes),
            ingressKey=macEncKey,
            isClient = False,
            afterHello = False -}
          }

    return cState
