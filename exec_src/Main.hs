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

import           Data.Bits
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import           Data.List.Split
import           Blockchain.UDP
import           System.Environment
import           Blockchain.PeerUrls
import           Blockchain.TCPServer
portS :: String
portS = "30303"

thePort :: Int
thePort = 30303

connectMe :: IO S.Socket
connectMe = do
  (serveraddr:_) <- S.getAddrInfo
                      (Just (S.defaultHints {S.addrFlags = [S.AI_PASSIVE]}))
                      Nothing (Just portS)
  sock <- S.socket (S.addrFamily serveraddr) S.Datagram S.defaultProtocol
  S.bindSocket sock (S.addrAddress serveraddr) >> return sock

udpHandshakeServer :: H.PrvKey -> TContext -> S.Socket  -> IO ()
udpHandshakeServer prv cxt conn = do
   (msg,addr) <- NB.recvFrom conn 1280

   putStrLn $ "from addr: " ++ show addr
   let ip = sockAddrToIP addr


   putStrLn $ "connection from ip: " ++ ip
   
   let r = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 32 $ msg
       s = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 64 msg
       v = head . B.unpack $ B.take 1 $ B.drop 96 msg

       theType = head . B.unpack $ B.take 1$ B.drop 97 msg
       theRest = B.unpack $ B.drop 98 msg
       (rlp, _) = rlpSplit theRest

       signature = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd
                         
       SHA messageHash = hash $ B.pack $ [theType] ++ B.unpack (rlpSerialize rlp)
       otherPubkey = fromMaybe (error "malformed signature in udpHandshakeServer") $ getPubKeyFromSignature signature messageHash  
       yIsOdd = v == 1

   putStrLn $ "other pubkey: " ++ (show $ B16.encode $ B.pack $ pointToBytes $ hPubKeyToPubKey $ otherPubkey)
   putStrLn $ "other pubkey as point: " ++ (show $ hPubKeyToPubKey $ otherPubkey)
   
   time <-  round `fmap` getPOSIXTime

   let (theType, theRLP) = ndPacketToRLP $
                                (Pong (Endpoint "127.0.0.1" 30303 30303) 4 (time+50):: NodeDiscoveryPacket)
                                
       theData = B.unpack $ rlpSerialize theRLP
       SHA theMsgHash = hash $ B.pack $ (theType:theData)

   ExtendedSignature signature yIsOdd <- liftIO $ H.withSource H.devURandom $ ecdsaSign  prv theMsgHash

   let v = if yIsOdd then 1 else 0 
       r = H.sigR signature
       s = H.sigS signature
       theSignature = word256ToBytes (fromIntegral r) ++ word256ToBytes (fromIntegral s) ++ [v]
       theHash = B.unpack $ SHA3.hash 256 $ B.pack $ theSignature ++ [theType] ++ theData

   cxt' <- readTVarIO cxt
   let prevPeers = peers cxt'
       
   atomically $ writeTVar cxt (cxt'{peers=(Map.insert ip (hPubKeyToPubKey otherPubkey) prevPeers)} )

   putStrLn $ "about to send PONG"
   _ <- NB.sendTo conn ( B.pack $ theHash ++ theSignature ++ [theType] ++ theData) addr
   
   udpHandshakeServer prv cxt conn
   return () 

connStr::BC.ByteString
connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

createTrigger :: PS.Connection -> IO ()
createTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS tx_notify ON raw_transaction;\n\
\CREATE OR REPLACE FUNCTION tx_notify() RETURNS TRIGGER AS $tx_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('new_transaction', TG_TABLE_NAME || ',id,' || NEW.id ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $tx_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER tx_notify AFTER INSERT OR DELETE ON raw_transaction FOR EACH ROW EXECUTE PROCEDURE tx_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


parseNotifPayload::String -> Int
parseNotifPayload s = read $ last $ splitOn "," s :: Int

notificationSource::PS.Connection->Source IO Notification
notificationSource conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    notif <- liftIO $ getNotification conn
    yield notif

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
  
