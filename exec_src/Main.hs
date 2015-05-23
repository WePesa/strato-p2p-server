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
import           Control.Concurrent.Async 
import           Control.Exception
import           Blockchain.Data.DataDefs 
import qualified Data.Binary as BN


import           Data.Time
import           Data.Time.Clock.POSIX
import qualified Data.ByteString as BS
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
   
   let r = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 32 $ msg
       s = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 64 msg
       v = head . BS.unpack $ BS.take 1 $ BS.drop 96 msg
       -- theHash = BS.unpack $ BS.take 32 msg
       theType = head . BS.unpack $ BS.take 1$ BS.drop 97 msg
       theRest = BS.unpack $ BS.drop 98 msg
       (rlp, _) = rlpSplit theRest

       signature = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd
                         
       SHA messageHash = hash $ BS.pack $ [theType] ++ BS.unpack (rlpSerialize rlp)
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
--   putStrLn $ "theHash: " ++ (show $ theHash)
--   putStrLn $ "theHash: " ++ (show $ B16.encode $ BS.take 32 $ msg)

--   let extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd


  -- let otherPubkey = getPubKeyFromSignature extSig (bytesToWord256 theHash)
   putStrLn $ "other pubkey: " ++ (show $ B16.encode $ BS.pack $ pointToBytes $ hPubKeyToPubKey $ otherPubkey)
   putStrLn $ "other pubkey as point: " ++ (show $ hPubKeyToPubKey $ otherPubkey)
   
   --  putStrLn $ show $ hPubKeyToPubKey $ derivePubKey $ ethHPrvKey

--   runStateT $
     
   time <-  round `fmap` getPOSIXTime

   let (theType, theRLP) = ndPacketToRLP $
                                (Pong (Endpoint "127.0.0.1" 30303 30303) 4 (time+50):: NodeDiscoveryPacket)
                                
       theData = BS.unpack $ rlpSerialize theRLP
       SHA theMsgHash = hash $ BS.pack $ (theType:theData)

   ExtendedSignature signature yIsOdd <- liftIO $ H.withSource H.devURandom $ encrypt prv theMsgHash

   let v = if yIsOdd then 1 else 0 
       r = H.sigR signature
       s = H.sigS signature
       theSignature = word256ToBytes (fromIntegral r) ++ word256ToBytes (fromIntegral s) ++ [v]
       theHash = BS.unpack $ SHA3.hash 256 $ BS.pack $ theSignature ++ [theType] ++ theData


  
   
   cxt' <- readTVarIO cxt
   let prevPeers = peers cxt'
       
  
   atomically $ writeTVar cxt (cxt'{peers=(Map.insert ip (hPubKeyToPubKey otherPubkey) prevPeers)} )

   putStrLn $ "about to send PONG"
   _ <- NB.sendTo conn ( BS.pack $ theHash ++ theSignature ++ [theType] ++ theData) addr
   
   udpHandshakeServer prv cxt conn
   return () 


encrypt::H.PrvKey->Word256->H.SecretT IO ExtendedSignature
encrypt prvKey' theHash = do
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
Just ethHPrvKey = H.makePrvKey 0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620e3d9b38d

add :: BS.ByteString->BS.ByteString->BS.ByteString
add acc val | BS.length acc ==32 && BS.length val == 32 = SHA3.hash 256 $ val `BS.append` acc
add _ _ = error "add called with ByteString of length not 32"

intToBytes::Integer->[Word8]
intToBytes x = map (fromIntegral . (x `shiftR`)) [256-8, 256-16..0]

ctr::[Word8]
ctr=[0,0,0,1]

s1::[Word8]
s1 = []

tcpHandshakeServer :: PrivateNumber -> Point -> ConduitM BS.ByteString BS.ByteString IO EthCryptStateLite
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
    
    let iv = BS.replicate 16 0
            
--    lift $ putStrLn $ "received from pubkey: " ++ (show $ B16.encode $ BS.pack otherPointBytes)
    lift $ putStrLn $ "received from pubkey: " ++ (show $ otherPoint)
    
 --   lift $ putStrLn $ "received: " ++ (show . BS.length $ hsBytesStr) ++ " bytes "

   -- lift $ putStrLn $ "received msg: " ++ (show eceisMsgIncoming)
  --  lift $ putStrLn $ "ciphertext bytes: " ++ (show . BS.length $ eceisCipher eceisMessage)
        
  --  lift $ putStrLn $ "decrypted msg bytes: " ++ (show . BS.length $ msgBytes)
--    lift $ putStrLn $ "decrypted msg: " ++ (show $ eceisMsgIBytes)
--    lift $ putStrLn $ "test: prv: " ++ (show prv)
    
    let SharedKey sharedKey = getShared theCurve prv otherPoint
        otherNonce = BS.take 32 $ BS.drop 161 $ eceisMsgIBytes
        msg = fromIntegral sharedKey `xor` (bytesToWord256 $ BS.unpack otherNonce)
        r = bytesToWord256 $ BS.unpack $ BS.take 32 $ eceisMsgIBytes
        s = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 32 $ eceisMsgIBytes
        v = head . BS.unpack $ BS.take 1 $ BS.drop 64 eceisMsgIBytes
        yIsOdd = v == 1

        extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd

              -- let otherPubkey = getPubKeyFromSignature extSig (bytesToWord256 theHash)  
        otherEphemeral = hPubKeyToPubKey $ getPubKeyFromSignature extSig msg
   --     let r = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 32 $ msgBytes
     --   let s = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 64 msgBytes
--        lift $ putStrLn $ "last byte of msg: " ++ show (BS.drop 96 msgBytes)
        
  --      let v = head . BS.unpack $ BS.take 1 $ BS.drop 96 msgBytes
  --      let theHash = BS.unpack $ BS.take 32 msgBytes
         
 --       let yIsOdd = v == 1

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

    let myNonceBS = BS.pack $ word256ToBytes myNonce
        shared2' = BS.pack $ intToBytes sharedKey2

        -- frameDecKey = otherNonce `add` myNonceBS `add` shared2' `add` shared2'
        -- macEncKey = frameDecKey `add` shared2'

        frameDecKey = otherNonce `add` myNonceBS `add` (BS.pack ephemeralSharedSecretBytes) `add` (BS.pack ephemeralSharedSecretBytes)
        macEncKey = frameDecKey `add` (BS.pack ephemeralSharedSecretBytes)
        
--    lift $  putStrLn $ "otherNonce: " ++ (show $ BS.unpack otherNonce)
 --   lift $  putStrLn $ "myNonce:    " ++ (show $ BS.unpack myNonceBS)
 
 --  lift $  putStrLn $ "otherNonce `add` myNonce: " ++ (show $ BS.unpack $ (otherNonce `add` myNonceBS))
 --   lift $  putStrLn $ "otherNonce `add` myNonce `add` shared: " ++ (show  $ BS.unpack $ (otherNonce `add` myNonceBS) `add` shared2' )
    

--    lift $  putStrLn $ "frameDecKey: " ++ (show $ BS.unpack $ frameDecKey)
--    lift $  putStrLn $ "macEncKey: " ++ (show $ BS.unpack $ macEncKey)

    let cState =
          EthCryptStateLite {
            encryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ BS.replicate 16 0) 0,
            decryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ BS.replicate 16 0) 0,
            egressMAC=SHA3.update (SHA3.init 256) $
                     (macEncKey `bXor` otherNonce) `BS.append` eceisMsgOBytes,
            egressKey=macEncKey,
            ingressMAC=SHA3.update (SHA3.init 256) $ 
                     (macEncKey `bXor` myNonceBS) `BS.append` (BL.toStrict hsBytes),
            ingressKey=macEncKey,
            peerId = calculatePublic theCurve prv
          }

    return cState

connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

sockAddrToIP :: S.SockAddr -> String
sockAddrToIP (S.SockAddrInet port host) = show host
sockAddrToIP (S.SockAddrInet6 port _ host _) = show host
sockAddrToIP (S.SockAddrUnix str) = str
sockAddrToIP addr = takeWhile (\t -> t /= ']') $ drop 1 $ (dropWhile (\t -> t /= ':') (drop 3 (show addr)))

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

listenConduit :: PS.Connection -> Producer IO MessageOrNotification
listenConduit conn = do
    res <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    liftIO $ putStrLn ("should be listening, with result: " ++ show res)
    notif <- liftIO $ getNotification conn
    liftIO $ putStrLn $ "got notification on channel new_transaction"
    liftIO $ putStrLn . show . notificationChannel $ notif
    liftIO $ putStrLn . show . notificationPid $ notif
    liftIO $ putStrLn . show . notificationData $ notif

    yield . Notif .  TransactionNotification .  parseNotifPayload $ BC.unpack . notificationData $ notif
    listenConduit conn

{-                             
listenForNotification :: PS.Connection -> IO ()
listenForNotification conn = do
  res <- PS.execute_ conn "LISTEN new_transaction;"
  putStrLn ("should be listening, with result: " ++ show res)
  notif <- getNotification conn
  putStrLn $ "got notification on channel new_transaction"
  putStrLn . show . notificationChannel $ notif
  putStrLn . show . notificationPid $ notif
  listenForNotification conn               
-}

main :: IO ()
main = do
  entropyPool <- liftIO createEntropyPool

  let g = cprgCreate entropyPool :: SystemRNG
      (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1

  let myPublic = calculatePublic theCurve myPriv
  putStrLn $ "my pubkey is: " ++ (show $ B16.encode $ BS.pack $ pointToBytes myPublic)
  putStrLn $ "as a point:   " ++ (show myPublic)
  
  cxt <- initContextLite
  tCxt <- newTVarIO cxt

  createTrigger (notifHandler cxt)
--  async $ (listenForNotification (notifHandler cxt))  
  
  async $ S.withSocketsDo $ bracket connectMe S.sClose (udpHandshakeServer (H.PrvKey $ fromIntegral myPriv) tCxt )

  runResourceT $ do
    db <- openDBsLite connStr
    _ <- flip runStateT db $
           flip runStateT cxt $
                  
                  lift $ lift $ lift $ runTCPServer (serverSettings thePort "*") $ \app -> do
                    putStrLn $ "connection: appSockAddr: " ++ (show (appSockAddr app))
      
                    curr <- readTVarIO tCxt
                    putStrLn $ "current context: " ++ (show curr)

  
                    (initCond,cState) <-
                      appSource app $$+ (tcpHandshakeServer myPriv ((peers curr) Map.! (sockAddrToIP $ appSockAddr app) ) ) `fuseUpstream` appSink app
                    (unwrap, _) <- unwrapResumable initCond

                    putStrLn $ "connection established, now handling messages"


                    runResourceT $ do
                       _ <- flip runStateT db $
                         flip runStateT cxt $
                           flip runStateT cState $
                             runResourceT $ do

                               (feedHandler :: Conduit BS.ByteString (EthCryptMLite ContextMLite)  MessageOrNotification )  <- mergeConduits [ transPipe (lift . lift . lift . lift . lift)
                                                                                                                                                 (listenConduit (notifHandler cxt)),
                                                                                                                                               recvMsgConduit ]
                                                                                                                                              16
--                               (transPipe (lift . lift . lift . lift . lift) unwrap) $$
--                                   (transPipe lift feedHandler) =$= handleMsgConduit  `fuseUpstream` appSink app

                               (transPipe (lift . lift . lift . lift . lift) unwrap) $$
                                   recvMsgConduit =$= handleMsgConduit  `fuseUpstream` appSink app
                   
                       return ()

                    putStrLn $ "closed session with: " ++ (show $ appSockAddr app)

                     
    return ()
 
    
  
