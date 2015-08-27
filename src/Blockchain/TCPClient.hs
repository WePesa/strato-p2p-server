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
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as NB
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Concurrent.STM
import qualified Data.Map as Map
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

myNonce = 25 :: Word256

runEthClient :: (MonadResource m, MonadIO m, MonadBaseControl IO m)
             => SQL.ConnectionString
             -> PrivateNumber
             -> String
             -> Int
             -> m ()
runEthClient connStr myPriv ip port = do
  serverPubKey <- liftIO $ getServerPubKey (H.PrvKey $ fromIntegral myPriv) ip (fromIntegral $ port)
  liftIO $ putStrLn $ "server public key is : " ++ (show serverPubKey)       

  liftIO $ runTCPClient (clientSettings port (BC.pack ip)) $ \server -> do
    (_,_) <-
          appSource server $$+ (tcpHandshakeClient (fromIntegral myPriv) serverPubKey (B.pack $ word256ToBytes myNonce)) `fuseUpstream` appSink server
    return ()
 
tcpHandshakeClient :: PrivateNumber -> Point -> B.ByteString -> ConduitM B.ByteString B.ByteString IO ()
tcpHandshakeClient prv otherPubKey myNonce = do
  bytes <- lift $ getHandshakeBytes prv otherPubKey myNonce
  yield bytes
  response <- await
  liftIO $ putStrLn $ "in tcpHandshakeClient, got: " ++ (show response)
