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
import qualified Network.Socket as S
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Applicative
import           Control.Monad
import           Control.Exception

import qualified Data.Binary as BN
import qualified Data.ByteString as B

import           Blockchain.ExtWord
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.UDPServer
import           Blockchain.BlockNotify
import           Blockchain.RawTXNotify

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
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import           Blockchain.Data.DataDefs
import           Blockchain.DB.SQLDB

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
    when flags_runUDPServer $ do
      _ <- liftIO $ async $ S.withSocketsDo $ bracket (connectMe listenPort) S.sClose (runEthUDPServer cxt myPriv)
      return ()
           
    liftIO $ runTCPServer (serverSettings listenPort "*") $ \app -> do
      peer <- fmap fst $ runResourceT $ flip runStateT cxt $ getPeerByIP (sockAddrToIP $ appSockAddr app)
      let unwrappedPeer = case (SQL.entityVal <$> peer) of 
                            Nothing -> error "peer is nothing after call to getPeerByIP"
                            Just peer' -> peer'
                          
      (_,cState) <-
        appSource app $$+ (tcpHandshakeServer (fromIntegral myPriv) (pPeerPubkey unwrappedPeer)) `fuseUpstream` appSink app

      runEthCryptMLite cxt cState $ do
        let rSource = appSource app
            txSource = txNotificationSource (liteSQLDB cxt) (notifHandler1 cxt)
                      =$= CL.map (Notif . TransactionNotification)
            blockSource = blockNotificationSource (liteSQLDB cxt) (notifHandler2 cxt)
                      =$= CL.map (Notif . uncurry BlockNotification)

        mSource' <- runResourceT $ mergeSources [rSource =$= recvMsgConduit, transPipe liftIO blockSource, transPipe liftIO txSource] 2::(EthCryptMLite ContextMLite) (Source (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification) 


        runResourceT $ do 
          liftIO $ putStrLn "server session starting"
          (mSource' $$ handleMsgConduit =$= appSink app)
          liftIO $ putStrLn "server session ended"

 
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
            encryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
            decryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
            egressMAC=SHA3.update (SHA3.init 256) $
                     (macEncKey `bXor` otherNonce) `B.append` eceisMsgOBytes,
            egressKey=macEncKey,
            ingressMAC=SHA3.update (SHA3.init 256) $ 
                     (macEncKey `bXor` myNonceBS) `B.append` (BL.toStrict hsBytes),
            ingressKey=macEncKey,
            peerId = calculatePublic theCurve prv,
            isClient = False,
            afterHello = False
          }

    return cState
