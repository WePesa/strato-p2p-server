{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Blockchain.TCPClient (
  runEthClient,
  tcpHandshakeClient
  ) where

import           Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Network
import qualified Data.Conduit.Binary as CBN
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Monad

import qualified Data.Binary as BN
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import           Data.Maybe

import           Blockchain.UDP
import           Blockchain.ExtWord
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.RawTXNotify
import           Blockchain.P2PUtil

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import qualified Crypto.Hash.SHA3 as SHA3
import           Crypto.Cipher.AES
import qualified Network.Haskoin.Internals as H

import qualified Database.Persist.Postgresql as SQL
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import Blockchain.DB.SQLDB

myNonce :: Word256
myNonce = 25

runEthClient :: (MonadResource m, MonadIO m, MonadBaseControl IO m)
             => SQL.ConnectionString
             -> PrivateNumber
             -> String
             -> Int
             -> m ()
runEthClient connStr myPriv ip port = do
  serverPubKeyOrError <- liftIO $ getServerPubKey (fromMaybe (error "invalid private number in call to runEthClient") $ H.makePrvKey $ fromIntegral myPriv) ip (fromIntegral $ port)

  let serverPubKey = either (error . ("couldn't get peer pubkey: " ++) . show) id serverPubKeyOrError

  liftIO $ putStrLn $ "server public key is : " ++ (show serverPubKey)       

  cxt <- initContextLite connStr
             
  liftIO $ runTCPClient (clientSettings port (BC.pack ip)) $ \server -> do
    (_,cState) <-
          appSource server $$+ (tcpHandshakeClient (fromIntegral myPriv) serverPubKey (B.pack $ word256ToBytes myNonce)) `fuseUpstream` appSink server


    runEthCryptMLite cxt cState $ do
      let rSource = appSource server
          nSource = txNotificationSource (liteSQLDB cxt) (notifHandler cxt)
                    =$= CL.map (Notif . TransactionNotification)

      mSource' <- runResourceT $ mergeSources [rSource =$= recvMsgConduit, transPipe liftIO nSource] 2::(EthCryptMLite ContextMLite) (Source (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification) 


--      runResourceT $ mSource' $$ handleMsgConduit  `fuseUpstream` appSink server

      runResourceT $ do
        liftIO $ putStrLn "client session starting"
        mSource' $$ handleMsgConduit =$= appSink server
        liftIO $ putStrLn "client session ended"
 
tcpHandshakeClient :: PrivateNumber -> Point -> B.ByteString -> ConduitM B.ByteString B.ByteString IO EthCryptStateLite
tcpHandshakeClient myPriv otherPubKey myNonce' = do
  handshakeInitBytes <- lift $ getHandshakeBytes myPriv otherPubKey myNonce'
  yield handshakeInitBytes
  
  handshakeReplyBytes <- CBN.take 210
  let replyECEISMsg = (BN.decode $ handshakeReplyBytes :: ECEISMessage)

  when (BL.length handshakeReplyBytes /= 210) $ error "handshake reply didn't contain enough bytes"
  
  let ackMsg = bytesToAckMsg $ B.unpack $ decryptECEIS myPriv replyECEISMsg

  let m_originated = False 
      otherNonce = B.pack $ word256ToBytes $ ackNonce ackMsg

      SharedKey shared' = getShared theCurve myPriv (ackEphemeralPubKey ackMsg)
      shared = B.pack $ intToBytes shared'

      frameDecKey = myNonce' `add` otherNonce `add` shared `add` shared
      macEncKey = frameDecKey `add` shared

      ingressCipher = if m_originated then handshakeInitBytes else (BL.toStrict handshakeReplyBytes)
      egressCipher = if m_originated then (BL.toStrict handshakeReplyBytes) else handshakeInitBytes

  let cState =
        EthCryptStateLite {
          peerId = calculatePublic theCurve myPriv,
          encryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
          decryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
          egressMAC=SHA3.update (SHA3.init 256) $
                    (macEncKey `bXor` otherNonce) `B.append` egressCipher,
          egressKey=macEncKey,
          ingressMAC=SHA3.update (SHA3.init 256) $ 
                     (macEncKey `bXor` myNonce') `B.append` ingressCipher,
          ingressKey=macEncKey,
          isClient = True,
          afterHello = False
        }
  liftIO $ putStrLn $ "handshake negotiated: " ++ (show (peerId cState))

  
  return cState
