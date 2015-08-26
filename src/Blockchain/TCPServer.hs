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
import qualified Network.Socket.ByteString as NB
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Control.Applicative
import           Control.Monad
import           Control.Exception
import qualified Data.Binary as BN


import           Data.Time.Clock.POSIX
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16

import           Blockchain.UDP
import           Blockchain.SHA
import           Blockchain.Data.RLP
import           Blockchain.ExtWord
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.DBM
import           Blockchain.UDPServer
import           Blockchain.TriggerNotify

import qualified Data.ByteString.Lazy as BL

import           Data.Maybe
import           Control.Monad.State
import           Prelude 
import           Data.Word
import qualified Network.Haskoin.Internals as H

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3

import           Crypto.Cipher.AES

import           Data.Bits
import qualified Database.Persist.Postgresql as SQL
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import           Data.List.Split
import           Blockchain.UDP
import           Blockchain.Data.DataDefs
import           Control.Monad.State
import           Prelude 
import           Data.Word
import qualified Network.Haskoin.Internals as H

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3

import           Crypto.Cipher.AES
import           Blockchain.P2PUtil
import           Control.Concurrent.Async.Lifted


add :: B.ByteString
    -> B.ByteString
    -> B.ByteString
add acc val | B.length acc ==32 && B.length val == 32 = SHA3.hash 256 $ val `B.append` acc
add _ _ = error "add called with ByteString of length not 32"

runEthServer :: (MonadResource m, MonadIO m, MonadBaseControl IO m) 
             => SQL.ConnectionString     
             -> PrivateNumber
             -> Int
             -> m ()
runEthServer connStr myPriv listenPort = do  
    cxt <- initContextLite connStr

    liftIO $ createTrigger (notifHandler cxt)
    liftIO $ async $ S.withSocketsDo $ bracket connectMe S.sClose (runEthUDPServer cxt myPriv)

    liftIO $ runTCPServer (serverSettings listenPort "*") $ \app -> do
      peer <- fmap fst $ runResourceT $ flip runStateT cxt $ getPeerByIP (sockAddrToIP $ appSockAddr app)
      let unwrappedPeer = case (SQL.entityVal <$> peer) of 
                            Nothing -> undefined
                            Just peer' -> peer'
                          
      (_,cState) <-
        appSource app $$+ (tcpHandshakeServer (fromIntegral myPriv) (pPeerPubkey unwrappedPeer)) `fuseUpstream` appSink app

      runEthCryptMLite cxt cState $ do
        let rSource = appSource app
            nSource = notificationSource (notifHandler cxt)
                      =$= CL.map (Notif . TransactionNotification .  parseNotifPayload . BC.unpack . notificationData)

        mSource' <- runResourceT $ mergeSources [rSource =$= recvMsgConduit, transPipe liftIO nSource] 2::(EthCryptMLite ContextMLite) (Source (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification) 


        runResourceT $ mSource' $$ handleMsgConduit  `fuseUpstream` appSink app

tcpHandshakeServer :: PrivateNumber -> Point -> ConduitM B.ByteString B.ByteString IO EthCryptStateLite
tcpHandshakeServer prv otherPoint = go
  where
  go = do
    hsBytes <- CBN.take 307
    
    let eceisMsgIncoming = (BN.decode $ hsBytes :: ECEISMessage)
        eceisMsgIBytes = (decryptECEIS prv eceisMsgIncoming )

    let iv = B.replicate 16 0
            
    lift $ putStrLn $ "received from pubkey: " ++ (show $ otherPoint)
    
    let SharedKey sharedKey = getShared theCurve prv otherPoint
        otherNonce = B.take 32 $ B.drop 161 $ eceisMsgIBytes
        msg = fromIntegral sharedKey `xor` (bytesToWord256 $ B.unpack otherNonce)
        r = bytesToWord256 $ B.unpack $ B.take 32 $ eceisMsgIBytes
        s = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 32 $ eceisMsgIBytes
        v = head . B.unpack $ B.take 1 $ B.drop 64 eceisMsgIBytes
        yIsOdd = v == 1

        extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd


        otherEphemeral = hPubKeyToPubKey $ fromMaybe (error "malformed signature in tcpHandshakeServer") $ getPubKeyFromSignature extSig msg


    entropyPool <- liftIO createEntropyPool
    let g = cprgCreate entropyPool :: SystemRNG
        (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1

    let myEphemeral = calculatePublic theCurve myPriv
        
    let myNonce = 25 :: Word256

    let ackMsg = AckMessage { ackEphemeralPubKey=myEphemeral, ackNonce=myNonce, ackKnownPeer=False } 

    let eceisMsgOutgoing = encryptECEIS myPriv otherPoint iv ( BL.toStrict $ BN.encode $ ackMsg )
    let eceisMsgOBytes = BL.toStrict $ BN.encode eceisMsgOutgoing
            
    yield $ eceisMsgOBytes

    let SharedKey ephemeralSharedSecret = getShared theCurve myPriv otherEphemeral
        ephemeralSharedSecretBytes = intToBytes ephemeralSharedSecret
  --  lift $ putStrLn $ "otherEphemeral as a point: " ++ (show $ otherEphemeral)
  --  lift $ putStrLn $ "otherEphemeral bytes      : " ++ (show $ pointToBytes otherEphemeral)
  --  lift $ putStrLn $ "ephemeral shared secret: " ++ (show $ intToBytes ephemeralSharedSecret)

    let myNonceBS = B.pack $ word256ToBytes myNonce

        -- frameDecKey = otherNonce `add` myNonceBS `add` shared2' `add` shared2'
        -- macEncKey = frameDecKey `add` shared2'

        frameDecKey = otherNonce `add` myNonceBS `add` (B.pack ephemeralSharedSecretBytes) `add` (B.pack ephemeralSharedSecretBytes)
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
            peerId = calculatePublic theCurve prv
          }

    return cState
