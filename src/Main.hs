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
import qualified Data.ByteString.Char8 as C
import           Data.Conduit.TMChan
import           Text.Printf              (printf)
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Data.Word8               (_cr)
import           Control.Monad
import           Control.Concurrent.Async (concurrently)
import           Control.Exception        (finally)
import           Blockchain.Data.DataDefs (entityDefs,migrateAll)

import           Data.Time
import           Data.Time.Clock.POSIX
import qualified Data.ByteString as BS

import           Blockchain.Data.Address
import           Blockchain.SHA
import           Blockchain.Data.Transaction
import           Blockchain.Util
import           Blockchain.Database.MerklePatricia

import qualified Database.Persist            as P
import qualified Database.Esqueleto          as E
import qualified Database.Persist.Postgresql as SQL

import           Blockchain.Data.RLP
import           Blockchain.ExtWord

import qualified Data.ByteString.Base16 as B16

import           Database.Persist.TH

import           Control.Monad.State
import           Control.Monad.Reader
import           Control.Monad.Trans
import           Control.Monad.Trans.Resource
import           Control.Monad.Logger
import           Control.Monad.IO.Class
import           Prelude 
import           Data.Word
import           System.IO (stdout)


share [ mkPersist sqlSettings ]
    entityDefs

data AppState = AppState { sqlDB :: SQL.ConnectionPool, server :: Server }
type AppStateM = StateT AppState (ResourceT IO)


getBlock :: AppState -> Integer -> IO ([ SQL.Entity Block ])
getBlock appState n = SQL.runSqlPersistMPool actions $ (sqlDB appState)
 where actions =   E.select $ E.from $ \(bdRef, block) -> do
                                   E.where_ ( (bdRef E.^. BlockDataRefNumber E.==. E.val n ) E.&&. ( bdRef E.^. BlockDataRefBlockId E.==. block E.^. BlockId ))
                                   return block
                               
{-
getBlockSql :: Integer -> AppStateM [ SQL.Entity Block ]
getBlockSql n = do
 ctx <- get
 runResourceT $
    SQL.runSqlPool actions $ sqlDB ctx

 where actions = (SQL.selectList [] [] )
-}

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
  , clientChan     :: TMChan Message
  , clientApp      :: AppData
  }
 
instance Show Client where
    show client =
        C.unpack (clientName client) ++ "@"
            ++ show (appSockAddr $ clientApp client)
 
data Server = Server {
    clients :: TVar (Map.Map ClientName Client)
}
 
data Message = Notice BS.ByteString
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
 
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
    clientmap <- readTVar clients
    mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)
 
 
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = writeTMChan clientChan msg
 
(<++>) = BS.append
 
handleMessage :: AppState -> Client -> Conduit Message IO BS.ByteString
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
 
 
sendToName :: Server -> ClientName -> Message -> STM Bool
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
 
main :: IO ()
main = do
    runResourceT $ do
        appState <- initState
        lift $ runTCPServer (serverSettings 4000 "*") $ \app -> do
            (fromClient, client) <-
                appSource app $$+ readName (server appState) app `fuseUpstream` appSink app
            print client
            (runClient fromClient appState client)
                `finally` (removeClient appState client)
        return ()


  {- runStdoutLoggingT $ SQL.withPostgresqlPool connStr 10 $ \pool ->
     liftIO $ flip SQL.runSqlPersistMPool pool $
        (SQL.selectSource [] [ SQL.LimitTo 100 ] :: Conduit () (ReaderT SQL.SqlBackend (NoLoggingT (ResourceT IO)))(SQL.Entity Block))
          $= CL.map show $$  sinkHandle stdout
    -}
            
