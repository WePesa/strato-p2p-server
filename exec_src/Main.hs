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
import           Data.Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Network
import qualified Data.Conduit.Network.UDP as UDP
import qualified Data.Conduit.Binary as CBN
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as NB
import           Network.Haskoin.Crypto 

import qualified Data.ByteString.Char8 as C
import           Data.Conduit.TMChan
import           Text.Printf              (printf)
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Data.Word8               (_cr)
import           Control.Monad
import           Control.Concurrent       (forkIO)
import           Control.Concurrent.Async 
import           Control.Exception
import           Blockchain.Data.DataDefs 
import qualified Data.Binary as BN


import           Data.Time
import           Data.Time.Clock.POSIX
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16

import           Blockchain.Data.Wire hiding (Ping, Pong)
import           Blockchain.UDP
import           Blockchain.Data.Address
import           Blockchain.SHA
import           Blockchain.Data.Transaction
import           Blockchain.Util
import           Blockchain.Database.MerklePatricia
import           Blockchain.Data.RLP
import           Blockchain.ExtWord
import           Blockchain.Format
import           Blockchain.RLPx
import           Blockchain.Frame
import           Blockchain.Communication
import           Blockchain.Handshake
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.DBM

import qualified Database.Persist            as P
import qualified Database.Esqueleto          as E
import qualified Database.Persist.Postgresql as SQL

import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BL
import           Database.Persist.TH

import           Data.Maybe
import           Control.Monad.State
import           Control.Monad.Reader
import           Control.Monad.Trans
import           Control.Monad.Trans.Resource
import           Control.Monad.Logger
import           Control.Monad.IO.Class
import           Prelude 
import           Data.Word
import qualified Network.Haskoin.Internals as H
import           System.Entropy
import           System.Environment

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3
import qualified Crypto.Hash.SHA256 as SHA256

import           Crypto.Cipher.AES

import           Data.Bits
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import           Data.List.Split
import           Control.Applicative
import           Control.Concurrent.STM.TBMChan

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
       otherPubkey = getPubKeyFromSignature signature messageHash  
       yIsOdd = v == 1
{-
   putStrLn $ "r:       " ++ (show r)
   putStrLn $ "r:       " ++ (show $ B16.encode $ BS.take 32 $ BS.drop 32 $ msg)
   putStrLn $ "r:       " ++ (show $ BS.unpack $ BS.take 32 $ BS.drop 32 $ msg)                              
   putStrLn $ "s:       " ++ (show s)
   putStrLn $ "s:       " ++ (show $ B16.encode $ BS.take 32 $ BS.drop 64 $ msg)
   putStrLn $ "s:       " ++ (show $ BS.unpack $ BS.take 32 $ BS.drop 64 $ msg)
   putStrLn $ "v:       " ++ (show v)
   putStrLn $ "v:       " ++ (show $ B16.encode $ BS.take 1 $ BS.drop 96 $ msg)
-}

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


ecdsaSign::H.PrvKey->Word256->H.SecretT IO ExtendedSignature
ecdsaSign prvKey' theHash = do
    extSignMsg theHash prvKey'
    

hPubKeyToPubKey::H.PubKey->Point
hPubKeyToPubKey (H.PubKeyU _) = error "PubKeyU not supported in hPubKeyToPUbKey yet"
hPubKeyToPubKey (H.PubKey hPoint) = Point (fromIntegral x) (fromIntegral y)
  where
     x = fromMaybe (error "getX failed in prvKey2Address") $ H.getX hPoint
     y = fromMaybe (error "getY failed in prvKey2Address") $ H.getY hPoint
                                                    
theCurve :: Curve
theCurve = getCurveByName SEC_p256k1

ethHPrvKey ::H.PrvKey
Just ethHPrvKey = H.makePrvKey 0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620e3d9b38e

add :: B.ByteString->B.ByteString->B.ByteString
add acc val | B.length acc ==32 && B.length val == 32 = SHA3.hash 256 $ val `B.append` acc
add _ _ = error "add called with ByteString of length not 32"

intToBytes::Integer->[Word8]
intToBytes x = map (fromIntegral . (x `shiftR`)) [256-8, 256-16..0]

ctr::[Word8]
ctr=[0,0,0,1]

s1::[Word8]
s1 = []

tcpHandshakeServer :: PrivateNumber -> Point -> ConduitM B.ByteString B.ByteString IO EthCryptStateLite
tcpHandshakeServer prv otherPoint = go
  where
  go = do
    hsBytes <- CBN.take 307
    
    let hsBytesStr = (BL.toStrict $ hsBytes)
        
    let eceisMsgIncoming = (BN.decode $ hsBytes :: ECEISMessage)
        eceisMsgIBytes = (decryptECEIS prv eceisMsgIncoming )

--    lift $ putStrLn $ "length of decrypted message: " ++ (show $ BS.length eceisMsgIBytes)
--    lift $ putStrLn $ "decrypted message: " ++ (show $ BS.unpack eceisMsgIBytes)
    
--    let otherEphemeralBytes = BS.unpack $ BS.take 64 $ BS.drop 1 hsBytesStr
  --      otherEphemeral = bytesToPoint otherEphemeralBytes
--        lift $ putStrLn $ "pubkey, maybe: " ++ (show $ bytesToPoint $ BS.unpack $ BS.take 64 (BS.drop 1 msgBytes))
--    let otherPointBytes = BS.unpack $ BS.take 64 (BS.drop 1 hsBytesStr)
--    let otherPoint = bytesToPoint $ otherPointBytes
    
    let iv = B.replicate 16 0
            
--    lift $ putStrLn $ "received from pubkey: " ++ (show $ B16.encode $ BS.pack otherPointBytes)
    lift $ putStrLn $ "received from pubkey: " ++ (show $ otherPoint)
    
 --   lift $ putStrLn $ "received: " ++ (show . BS.length $ hsBytesStr) ++ " bytes "

   -- lift $ putStrLn $ "received msg: " ++ (show eceisMsgIncoming)
  --  lift $ putStrLn $ "ciphertext bytes: " ++ (show . BS.length $ eceisCipher eceisMessage)
        
  --  lift $ putStrLn $ "decrypted msg bytes: " ++ (show . BS.length $ msgBytes)
--    lift $ putStrLn $ "decrypted msg: " ++ (show $ eceisMsgIBytes)
--    lift $ putStrLn $ "test: prv: " ++ (show prv)
    
    let SharedKey sharedKey = getShared theCurve prv otherPoint
        otherNonce = B.take 32 $ B.drop 161 $ eceisMsgIBytes
        msg = fromIntegral sharedKey `xor` (bytesToWord256 $ B.unpack otherNonce)
        r = bytesToWord256 $ B.unpack $ B.take 32 $ eceisMsgIBytes
        s = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 32 $ eceisMsgIBytes
        v = head . B.unpack $ B.take 1 $ B.drop 64 eceisMsgIBytes
        yIsOdd = v == 1

        extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd


        otherEphemeral = hPubKeyToPubKey $ getPubKeyFromSignature extSig msg


    entropyPool <- liftIO createEntropyPool
    let g = cprgCreate entropyPool :: SystemRNG
        (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1

    let myEphemeral = calculatePublic theCurve myPriv
        
    let myNonce = 25 :: Word256

--    lift $ putStrLn $ "my ephemeral: " ++ (show $ B16.encode $ BS.pack $ pointToBytes myEphemeral)
--    lift $ putStrLn $ "my ephemeral as a point: " ++ (show $ myEphemeral)
--    let otherNonce = (BL.toStrict $ BN.encode sharedKey) `bXor` (BS.take 32 $ BS.drop 64 msgBytes)
            
 --   lift $ putStrLn $ "otherNonce: " ++ (show $ otherNonce)
     
 --   lift $ putStrLn $ "otherNonce2: " ++ (show $ (bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 64 msgBytes))

    let ackMsg = AckMessage { ackEphemeralPubKey=myEphemeral, ackNonce=myNonce, ackKnownPeer=False } 

    let eceisMsgOutgoing = encryptECEIS myPriv otherPoint iv ( BL.toStrict $ BN.encode $ ackMsg )
    let eceisMsgOBytes = BL.toStrict $ BN.encode eceisMsgOutgoing
            
--    lift $ putStrLn $ "sending back: " ++ (show $ eceisMsgOutgoing)
    yield $ eceisMsgOBytes

    let SharedKey sharedKey2 = getShared theCurve myPriv otherPoint
    
  --  lift $ putStrLn $ "shared key 2: " ++ (show $ intToBytes sharedKey2)

    let SharedKey ephemeralSharedSecret = getShared theCurve myPriv otherEphemeral
        ephemeralSharedSecretBytes = intToBytes ephemeralSharedSecret
  --  lift $ putStrLn $ "otherEphemeral as a point: " ++ (show $ otherEphemeral)
  --  lift $ putStrLn $ "otherEphemeral bytes      : " ++ (show $ pointToBytes otherEphemeral)
  --  lift $ putStrLn $ "ephemeral shared secret: " ++ (show $ intToBytes ephemeralSharedSecret)

    let myNonceBS = B.pack $ word256ToBytes myNonce
        shared2' = B.pack $ intToBytes sharedKey2

        -- frameDecKey = otherNonce `add` myNonceBS `add` shared2' `add` shared2'
        -- macEncKey = frameDecKey `add` shared2'

        frameDecKey = otherNonce `add` myNonceBS `add` (B.pack ephemeralSharedSecretBytes) `add` (B.pack ephemeralSharedSecretBytes)
        macEncKey = frameDecKey `add` (B.pack ephemeralSharedSecretBytes)
        
--    lift $  putStrLn $ "otherNonce: " ++ (show $ BS.unpack otherNonce)
 --   lift $  putStrLn $ "myNonce:    " ++ (show $ BS.unpack myNonceBS)
 
 --  lift $  putStrLn $ "otherNonce `add` myNonce: " ++ (show $ BS.unpack $ (otherNonce `add` myNonceBS))
 --   lift $  putStrLn $ "otherNonce `add` myNonce `add` shared: " ++ (show  $ BS.unpack $ (otherNonce `add` myNonceBS) `add` shared2' )
    

--    lift $  putStrLn $ "frameDecKey: " ++ (show $ BS.unpack $ frameDecKey)
--    lift $  putStrLn $ "macEncKey: " ++ (show $ BS.unpack $ macEncKey)

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

connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

sockAddrToIP :: S.SockAddr -> String
sockAddrToIP (S.SockAddrInet6 port _ host _) = show host
-- sockAddrToIP (S.SockAddrInet port host) = show host   -- convert to dot dash
sockAddrToIP (S.SockAddrUnix str) = str
sockAddrToIP addr = takeWhile (\t -> t /= ':') (show addr)
  --takeWhile (\t -> t /= ']') $ drop 1 $ (dropWhile (\t -> t /= ':') (drop 3 (show addr)))

createTrigger :: PS.Connection -> IO ()
createTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS tx_notify ON raw_transaction;\n\
\CREATE OR REPLACE FUNCTION tx_notify() RETURNS TRIGGER AS $tx_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('new_transaction', TG_TABLE_NAME || ',id,' || NEW.id ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $tx_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER tx_notify AFTER INSERT OR UPDATE OR DELETE ON raw_transaction FOR EACH ROW EXECUTE PROCEDURE tx_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


parseNotifPayload :: String -> Int
parseNotifPayload s = read $ last $ splitOn "," s :: Int

bufSize = 16

--notificationSource::MonadIO m=>PS.Connection->Source m Notification
notificationSource::PS.Connection->Source IO Notification
notificationSource conn = forever $ do
    res <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    notif <- liftIO $ getNotification conn
    yield notif

{-
    liftIO $ putStrLn ("should be listening, with result: " ++ show res)
    liftIO $ putStrLn $ "got notification on channel new_transaction"
    liftIO $ putStrLn . show . notificationChannel $ notif
    liftIO $ putStrLn . show . notificationPid $ notif
    liftIO $ putStrLn . show . notificationData $ notif
return . Notif .  TransactionNotification .  parseNotifPayload $ BC.unpack . notificationData $ notif
-}

{-
listenChan :: PS.Connection -> IO (TBMChan MessageOrNotification)
listenChan conn = do
    chan <- atomically $ newTBMChan bufSize
    forkListener chan conn
    putStrLn $ "in listenChan, after forkListener"
    return chan

  where
    forkListener chan conn = void . forkIO $ do
      putStrLn $ "in forkListener, about to listen"
      next <- listenConn conn
      putStrLn $ "in forkListener, after listen - writing atomically"
      atomically $ writeTBMChan chan next
      forkListener chan conn	
-}

privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

--type EthCryptMLite a = StateT EthCryptStateLite a
--type ContextMLite = StateT ContextLite DBMLite
--type DBMLite = StateT DBsLite (ResourceT IO)

--EthCryptMLite ContextMLite a = StateT EthCryptStateLite (StateT ContextLite (StateT DBsLite (Resource IO)))

runEthCryptMLite::DBsLite->ContextLite->EthCryptStateLite->EthCryptMLite ContextMLite a->IO ()
runEthCryptMLite db cxt cState f = do
  _ <- runResourceT $
       flip runStateT db $
       flip runStateT cxt $
       flip runStateT cState $
       f
  return ()

runContextMLite::ContextMLite a->IO a
runContextMLite = undefined

main :: IO ()
main = do
  entropyPool <- liftIO createEntropyPool
{-
  let g = cprgCreate entropyPool :: SystemRNG
      (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1
-}

  let myPriv = privateKey
      
--  let myPublic = calculatePublic theCurve myPriv
  let myPublic = calculatePublic theCurve (fromIntegral myPriv)

  putStrLn $ "my pubkey is: " ++ (show $ B16.encode $ B.pack $ pointToBytes myPublic)
  putStrLn $ "as a point:   " ++ (show myPublic)
  
  cxt <- initContextLite
  tCxt <- newTVarIO cxt

  createTrigger (notifHandler cxt)

  async $ S.withSocketsDo $ bracket connectMe S.sClose (udpHandshakeServer (H.PrvKey $ fromIntegral myPriv) tCxt )

  runResourceT $ do
    db <- openDBsLite connStr
    lift $ runTCPServer (serverSettings thePort "*") $ \app -> do
      curr <- readTVarIO tCxt
      putStrLn $ "current context: " ++ (show curr)
      
      (initCond,cState) <-
        appSource app $$+ (tcpHandshakeServer (fromIntegral myPriv) ((peers curr) Map.! (sockAddrToIP $ appSockAddr app) ) ) `fuseUpstream` appSink app

      runEthCryptMLite db cxt cState $ do
        let rSource = appSource app
            nSource = notificationSource (notifHandler cxt)
                      =$= CL.map (Notif . TransactionNotification .  parseNotifPayload . BC.unpack . notificationData)

        mSource' <- runResourceT $ mergeSources [rSource =$= recvMsgConduit, transPipe liftIO nSource] 2::(EthCryptMLite ContextMLite) (Source (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification) 


        runResourceT $ mSource' $$ handleMsgConduit  `fuseUpstream` appSink app 


--        return () 



  return ()

{-
runResourceT $ do
    db <- openDBsLite connStr
    _ <- flip runStateT db $
           flip runStateT cxt $
                  
                  lift $ lift $ lift $ runTCPServer (serverSettings thePort "*") $ \app -> do
                    putStrLn $ "connection: appSockAddr: " ++ (show (appSockAddr app))
      
                    curr <- readTVarIO tCxt
                    putStrLn $ "current context: " ++ (show curr)

                     
                    (initCond,cState) <-
                      appSource app $$+ (tcpHandshakeServer (fromIntegral myPriv) ((peers curr) Map.! (sockAddrToIP $ appSockAddr app) ) ) `fuseUpstream` appSink app
                    (unwrap, _) <- unwrapResumable initCond

                    putStrLn $ "connection established, now handling messages"

                    let nSource = notificationSource (notifHandler cxt)
                                  =$= CL.map (Notif . TransactionNotification .  parseNotifPayload . BC.unpack . notificationData)


                    mSource <- (runResourceT $ mergeSources [nSource] 2)::IO (Source (ResourceT IO) MessageOrNotification)
                    
                    let rSource =
                          runResourceT $ 
                          flip runStateT db $
                          flip runStateT cxt $
                          flip runStateT cState $
                          runResourceT $ do
                            recvMsgConduit
                               
                    mSource' <- (mergeSources [rSource] 2) -- ::IO (Source (ResourceT IO) MessageOrNotification)
                               
--                               (transPipe (lift . lift . lift . lift . lift) unwrap) $$
--                                   (recvMsgConduit chan) =$= handleMsgConduit  `fuseUpstream` appSink app 
                    transPipe (lift . lift . lift . lift) mSource' $$ handleMsgConduit  `fuseUpstream` appSink app 
                   
                    --   return ()

--                    runResourceT $ mSource =$= handleMsgConduit $$ appSink app

                    putStrLn $ "closed session with: " ++ (show $ appSockAddr app)

-}

                     

 
    
  
