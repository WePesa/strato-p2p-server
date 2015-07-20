{-# LANGUAGE OverloadedStrings, RecordWildCards, LambdaCase #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE ScopedTypeVariables        #-}

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
import           Control.Concurrent.Async 
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
--import           System.Entropy

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3

import           Crypto.Cipher.AES
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification

import           Data.Bits
import qualified Data.ByteString.Char8 as BC
import           Blockchain.UDP
import           System.Environment
import           Blockchain.PeerUrls
import           Blockchain.TCPServer
import           Blockchain.UDPServer
import           Blockchain.P2PUtil
import           Blockchain.TriggerNotify

thePort :: Int
thePort = 30303

connStr::BC.ByteString
connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

privateKey::Integer
privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

main :: IO ()
main = do
{-
  entropyPool <- liftIO createEntropyPool

  let g = cprgCreate entropyPool :: SystemRNG
      (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1
-}
  args <- getArgs

  let (ipAddress, thePort') =
        case args of
          [] -> ipAddresses !! 1 --default server                                                                  
          [x] -> ipAddresses !! read x
          ["-a", address] -> (address, 30303)
          [x, prt] -> (fst (ipAddresses !! read x), fromIntegral $ read prt)
          ["-a", address, prt] -> (address, fromIntegral $ read prt)
          _ -> error "usage: p2p-server [servernum] [port]"


  let myPriv = privateKey
  serverPubKey <- getServerPubKey (H.PrvKey $ fromIntegral myPriv) ipAddress thePort'
      
  putStrLn $ "server public key is : " ++ (show $ B16.encode $ B.pack $ pointToBytes serverPubKey)

--  let myPublic = calculatePublic theCurve myPriv
  let myPublic = calculatePublic theCurve (fromIntegral myPriv)

  putStrLn $ "my pubkey is: " ++ (show $ B16.encode $ B.pack $ pointToBytes myPublic)
  putStrLn $ "as a point:   " ++ (show myPublic)
  
  cxt <- initContextLite
  tCxt <- newTVarIO cxt

  createTrigger (notifHandler cxt)

  _ <- async $ S.withSocketsDo $ bracket connectMe S.sClose (udpHandshakeServer (H.PrvKey $ fromIntegral myPriv) tCxt )

  _ <- runResourceT $ do
    db <- openDBsLite connStr
    lift $ runTCPServer (serverSettings thePort "*") $ \app -> do
      curr <- readTVarIO tCxt
      putStrLn $ "current context: " ++ (show curr)
      
      (_,cState) <-
        appSource app $$+ (tcpHandshakeServer (fromIntegral myPriv) ((peers curr) Map.! (sockAddrToIP $ appSockAddr app) ) ) `fuseUpstream` appSink app

      runEthCryptMLite db cxt cState $ do
        let rSource = appSource app
            nSource = notificationSource (notifHandler cxt)
                      =$= CL.map (Notif . TransactionNotification .  parseNotifPayload . BC.unpack . notificationData)

        mSource' <- runResourceT $ mergeSources [rSource =$= recvMsgConduit, transPipe liftIO nSource] 2::(EthCryptMLite ContextMLite) (Source (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification) 


        runResourceT $ mSource' $$ handleMsgConduit  `fuseUpstream` appSink app 

  return ()
  
