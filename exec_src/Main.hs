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
import           Control.Concurrent.Async (concurrently)
import           Control.Exception
import           Blockchain.Data.DataDefs 
import qualified Data.Binary as BN

import           Data.Time
import           Data.Time.Clock.POSIX
import qualified Data.ByteString as BS

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
import           Blockchain.Handshake
import           Data.Bits

data AppState = AppState { sqlDB :: SQL.ConnectionPool, server :: Server }
type AppStateM = StateT AppState (ResourceT IO)


getBlock :: AppState -> Integer -> IO ([ SQL.Entity Block ])
getBlock appState n = SQL.runSqlPersistMPool actions $ (sqlDB appState)
 where actions =   E.select $ E.from $ \(bdRef, block) -> do
                                   E.where_ ( (bdRef E.^. BlockDataRefNumber E.==. E.val n ) E.&&. ( bdRef E.^. BlockDataRefBlockId E.==. block E.^. BlockId ))
                                   return block
                               
connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

initState :: ResourceT IO AppState
initState = do
  serv <- lift $ newServer
  sqldb <- runNoLoggingT  $ SQL.createPostgresqlPool connStr 20
  SQL.runSqlPool (SQL.runMigration migrateAll) sqldb
  return $ AppState { sqlDB = sqldb, server = serv }

 
type ClientName = BS.ByteString
 
data Client = Client
  { clientName     :: ClientName
  , clientChan     :: TMChan Msg
  , clientApp      :: AppData
  }
 
instance Show Client where
    show client =
        C.unpack (clientName client) ++ "@"
            ++ show (appSockAddr $ clientApp client)
 
data Server = Server {
    clients :: TVar (Map.Map ClientName Client)
}
 
data Msg     = Notice BS.ByteString
             | Tell ClientName BS.ByteString
             | Broadcast ClientName BS.ByteString
             | Command BS.ByteString
              deriving Show
 
newServer :: IO Server
newServer = do
  c <- newTVarIO Map.empty
  return Server { clients = c }
 
newClient :: ClientName -> AppData -> STM Client
newClient name app = do
    chan <- newTMChan
    return Client { clientName     = name
                  , clientApp      = app
                  , clientChan     = chan
                  }
 
broadcast :: Server -> Msg -> STM ()
broadcast Server{..} msg = do
    clientmap <- readTVar clients
    mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)
 
 
sendMessage :: Client -> Msg -> STM ()
sendMessage Client{..} msg = writeTMChan clientChan msg
 
(<++>) = BS.append
 
handleMessage :: AppState -> Client -> Conduit Msg IO BS.ByteString
handleMessage appState client@Client{..} = awaitForever $ \case
    Notice msg -> output $ "*** " <++> msg
    Tell name msg      -> output $ "*" <++> name <++> "*: " <++> msg
    Broadcast name msg -> output $ "<" <++> name <++> ">: " <++> msg
    Command msg        -> case C.words msg of
        ["/tell", who, what] -> do
            ok <- liftIO $ atomically $
                sendToName serv who $ Tell clientName what
            unless ok $ output $ who <++> " is not connected."
        ["/help"] ->
            mapM_ output [ "------ help -----"
                         , "/tell <who> <what> - send a private message"
                         , "/list - list users online"
                         , "/help - show this message"
                         , "/quit - leave"
                         ]
        ["/list"] -> do
            cl <- liftIO $ atomically $ listClients serv
            output $ C.concat $
                "----- online -----\n" : map ((flip C.snoc) '\n') cl
 
        ["/quit"] -> do
            error . C.unpack $ clientName <++> " has quit"
 
        ["/block", n] -> do 
           let maybeNum = C.readInteger n
           case maybeNum of 
            (Just (num,rest)) -> do
               blk <- lift $ getBlock appState num
               output $ C.concat $ "requested block: " : [ (C.pack . show $  blk) ]
            Nothing -> do 
               output $ C.concat $ "failed to parse integer: " : [ n ]

        [""] -> return ()
        [] -> return ()
 
        -- broadcasts
        ws ->
            if C.head (head ws) == '/' then
                output $ "Unrecognized command: " <++> msg
            else
                liftIO $ atomically $
                    broadcast serv $ Broadcast clientName msg
  where
    output s = yield (s <++> "\n")
    serv = server appState
 
listClients :: Server -> STM [ClientName]
listClients Server{..} = do
    c <- readTVar clients
    return $ Map.keys c
 
 
sendToName :: Server -> ClientName -> Msg -> STM Bool
sendToName server@Server{..} name msg = do
    clientmap <- readTVar clients
    case Map.lookup name clientmap of
        Nothing -> return False
        Just client -> sendMessage client msg >> return True
 
 
checkAddClient :: Server -> ClientName -> AppData -> IO (Maybe Client)
checkAddClient server@Server{..} name app = atomically $ do
    clientmap <- readTVar clients
    if Map.member name clientmap then
        return Nothing
    else do
        client <- newClient name app
        writeTVar clients $ Map.insert name client clientmap
        broadcast server  $ Notice (name <++> " has connected")
        return (Just client)
 
 
readName :: Server -> AppData -> ConduitM BS.ByteString BS.ByteString IO Client
readName server app = go
  where
  go = do
    yield "What is your name? "
    name <- lineAsciiC $ takeCE 80 =$= filterCE (/= _cr) =$= foldC
    if BS.null name then
        go
    else do
        ok <- liftIO $ checkAddClient server name app
        case ok of
            Nothing -> do
                respond "The name '%s' is in use, please choose another\n" name
                go
            Just client -> do
                respond "Welcome, %s!\nType /help to list commands.\n" name
                return client
  respond msg name = yield $ C.pack $ printf msg $ C.unpack name
 
 
clientSink :: Client -> Sink BS.ByteString IO ()
clientSink Client{..} = mapC Command =$ sinkTMChan clientChan True
 
runClient :: ResumableSource IO BS.ByteString -> AppState -> Client -> IO ()
runClient clientSource appState client@Client{..} =
    void $ concurrently
        (clientSource $$+- linesUnboundedAsciiC =$ clientSink client)
        (sourceTMChan clientChan
            $$ handleMessage appState client
            =$ appSink clientApp)
 
removeClient :: AppState -> Client -> IO ()
removeClient appState client@Client{..} = atomically $ do
    modifyTVar' (clients $ server $ appState) $ Map.delete clientName
    broadcast (server appState) $ Notice (clientName <++> " has disconnected")

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
  
handler :: H.PrvKey -> S.Socket -> IO ()
handler prv conn = do
   (msg,addr) <- NB.recvFrom conn 1024

   let r = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 32 $ msg
   let s = bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 64 msg
   let v = head . BS.unpack $ BS.take 1 $ BS.drop 96 msg
   let theHash = BS.unpack $ BS.take 32 msg
         
   let yIsOdd = v == 1

   putStrLn $ "r:       " ++ (show r)
   putStrLn $ "s:       " ++ (show s)
   putStrLn $ "v:       " ++ (show v)
   putStrLn $ "theHash: " ++ (show $ theHash)
        
   let extSig = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd


   putStrLn $ show $ hPubKeyToPubKey $ getPubKeyFromSignature extSig (bytesToWord256 theHash)
   -- putStrLn $ show $ hPubKeyToPubKey $ derivePubKey $ ethHPrvKey

   let (theType, theRLP) = ndPacketToRLP $
                                (Pong "xy" 34453 :: NodeDiscoveryPacket)
                                
       theData = BS.unpack $ rlpSerialize theRLP
       SHA theMsgHash = hash $ BS.pack $ (theType:theData)

   ExtendedSignature signature yIsOdd <- liftIO $ H.withSource H.devURandom $ encrypt prv theMsgHash

   let v = if yIsOdd then 1 else 0 
       r = H.sigR signature
       s = H.sigS signature
       theSignature = word256ToBytes (fromIntegral r) ++ word256ToBytes (fromIntegral s) ++ [v]
       theHash = BS.unpack $ SHA3.hash 256 $ BS.pack $ theSignature ++ [theType] ++ theData

   _ <- NB.sendTo conn ( BS.pack $ theHash ++ theSignature ++ [theType] ++ theData) addr
   return () 
  -- unless (null msg) $ S.sendTo conn msg d >> handler conn

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


tcpHandshakeServer :: PrivateNumber -> ConduitM BS.ByteString BS.ByteString IO ()
tcpHandshakeServer prv = go
  where
  go = do
    hsBytes <- CBN.take 307

    let hsBytesStr = (BL.toStrict $ hsBytes)
        
    let eceisMessage = (BN.decode $ hsBytes :: ECEISMessage)
    let msgBytes = (decryptECEIS  prv eceisMessage )
--        lift $ putStrLn $ "pubkey, maybe: " ++ (show $ bytesToPoint $ BS.unpack $ BS.take 64 (BS.drop 1 msgBytes))
    let otherPoint = bytesToPoint $ BS.unpack $ BS.take 64 (BS.drop 1 hsBytesStr)

    let iv =  BS.replicate 16 0
            
  --  lift $ putStrLn $ "received from pubkey: " ++ (show otherPoint)
    lift $ putStrLn $ "received: " ++ (show . BS.length $ hsBytesStr) ++ " bytes "

    lift $ putStrLn $ "received msg: " ++ (show eceisMessage)
    lift $ putStrLn $ "ciphertext bytes: " ++ (show . BS.length $ eceisCipher eceisMessage)
        
    lift $ putStrLn $ "decrypted msg bytes: " ++ (show . BS.length $ msgBytes)
    lift $ putStrLn $ "decrypted msg: " ++ (show $ msgBytes)

    let SharedKey sharedKey = getShared theCurve prv otherPoint

    lift $ putStrLn $ "shared key: " ++ (show sharedKey)

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

    lift $ putStrLn $ "my ephemeral: " ++ (show $ myEphemeral)
        -- let otherNonce = (BL.toStrict $ BN.encode sharedKey) `bXor` (BS.take 32 $ BS.drop 64 msgBytes)
            
     --    lift $ putStrLn $ "otherNonce: " ++ (show $ otherNonce)
     
--        lift $ putStrLn $ "otherNonce2: " ++ (show $ (bytesToWord256 $ BS.unpack $ BS.take 32 $ BS.drop 64 msgBytes))

    let ackMsg = AckMessage { ackEphemeralPubKey = myEphemeral, ackNonce=myNonce, ackKnownPeer=False } 
            
    let eceisMsg = encryptECEIS prv otherPoint iv ( BL.toStrict $ BN.encode $ ackMsg )
    let eceisMsgBytes = BL.toStrict $ BN.encode eceisMsg
            
    lift $ putStrLn $ "sending back: " ++ (show $ eceisMsg)
    yield $ eceisMsgBytes

    nextMsg <- await
    lift $ putStrLn $ "probably the Hello Message, encrypted: " ++ (show nextMsg)
        
main :: IO ()
main = do
  entropyPool <- liftIO createEntropyPool

  let g = cprgCreate entropyPool :: SystemRNG
      (myPriv, _) = generatePrivate g $ getCurveByName SEC_p256k1

  let myPublic = calculatePublic theCurve myPriv
  putStrLn $ "my pubkey is: " ++ show myPublic
  
  S.withSocketsDo $ bracket connectMe S.sClose (handler (H.PrvKey $ fromIntegral myPriv))

  runTCPServer (serverSettings thePort "*") $ \app -> do
    (initCond,_) <-
      appSource app $$+ (tcpHandshakeServer myPriv) `fuseUpstream` appSink app
      
--    void $ initCond $$++ recvMsgConduit =$= handleMsgConduit =$= initCond
    return ()
  {-
  runResourceT $ do
        appState <- initState
        lift $ runTCPServer (serverSettings thePort "*") $ \app -> do
            cond <-
                appSource app $$ (tcpHandshakeServer myPriv) `fuseUpstream` appSink app
            (runClient fromClient appState client)
                `finally` (removeClient appState client)
        return ()
-}
  return ()
 
