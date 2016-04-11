{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  TContext,
  runEthCryptMLite,
 -- isDebugEnabled,
  initContextLite,
  getBlockHeaders,
  putBlockHeaders,
  getSyncedBlock,
  setSynced,
  addPeer,
  getPeerByIP,
  EthCryptMLite,
  EthCryptStateLite(..)
  ) where


import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Resource

import Blockchain.Data.BlockHeader
import Blockchain.DBM
import Blockchain.DB.SQLDB
import Blockchain.Data.DataDefs
import qualified Blockchain.AESCTR as AES

import qualified Data.ByteString as B
import qualified Crypto.Hash.SHA3 as SHA3
import qualified Database.Persist.Postgresql as SQL
import qualified Database.PostgreSQL.Simple as PS

import           Crypto.Types.PubKey.ECC

import Control.Concurrent.STM

import qualified Data.Text as T

data EthCryptStateLite =
  EthCryptStateLite {
    encryptState::AES.AESCTRState,
    decryptState::AES.AESCTRState,
    egressMAC::SHA3.Ctx,
    ingressMAC::SHA3.Ctx,
    egressKey::B.ByteString,
    ingressKey::B.ByteString,
    peerId::Point,
    isClient::Bool,
    afterHello::Bool
  } 

type EthCryptMLite a = StateT EthCryptStateLite a

data ContextLite =
  ContextLite {
    liteSQLDB::SQLDB,
    notifHandler1::PS.Connection,
    notifHandler2::PS.Connection,
    debugEnabled::Bool,
    blockHeaders::[BlockHeader],
    contextSynced::Maybe Integer
  } deriving Show


instance Show PS.Connection where
  show _ = "Postgres Simple Connection"

type TContext = TVar ContextLite
type ContextMLite = StateT ContextLite (ResourceT IO)

instance HasSQLDB ContextMLite where
  getSQLDB = fmap liteSQLDB get

getBlockHeaders::ContextMLite [BlockHeader]
getBlockHeaders = do
  cxt <- get
  return $ blockHeaders cxt

putBlockHeaders::[BlockHeader]->ContextMLite ()
putBlockHeaders headers = do
  cxt <- get
  put cxt{blockHeaders=headers}

getSyncedBlock::ContextMLite (Maybe Integer)
getSyncedBlock = do
  cxt <- get
  return $ contextSynced cxt

setSynced::Integer->ContextMLite ()
setSynced number = do
  cxt <- get
  put cxt{contextSynced=Just number}

runEthCryptMLite::ContextLite->EthCryptStateLite->EthCryptMLite ContextMLite a->IO ()
runEthCryptMLite cxt cState f = do
  _ <- runResourceT $
       flip runStateT cxt $
       flip runStateT cState $
       f
  return ()


initContextLite :: (MonadResource m, MonadIO m, MonadBaseControl IO m) => SQL.ConnectionString -> m ContextLite
initContextLite _ = do
  notif1 <- liftIO $ PS.connect PS.defaultConnectInfo {   -- bandaid, should eventually be added to monad class
            PS.connectPassword = "api",
            PS.connectDatabase = "eth"
           }
  notif2 <- liftIO $ PS.connect PS.defaultConnectInfo {   -- bandaid, should eventually be added to monad class
            PS.connectPassword = "api",
            PS.connectDatabase = "eth"
           }
  dbs <- openDBs
  return ContextLite {
                    liteSQLDB = sqlDB' dbs,                    
                    notifHandler1=notif1,
                    notifHandler2=notif2,
                    debugEnabled = False,
                    blockHeaders=[],
                    contextSynced=Nothing
                 }

addPeer :: (HasSQLDB m, MonadResource m, MonadBaseControl IO m, MonadThrow m)=>PPeer->m (SQL.Key PPeer)
addPeer peer = do
  db <- getSQLDB
  maybePeer <- getPeerByIP (T.unpack $ pPeerIp peer)
  runResourceT $
    SQL.runSqlPool (actions maybePeer) db
  where actions mp = case mp of
            Nothing -> do
              peerid <- SQL.insert $ peer        
              return peerid
  
            Just peer'-> do 
              SQL.update (SQL.entityKey peer') [PPeerPubkey SQL.=.(pPeerPubkey peer)]  
              return (SQL.entityKey peer')

getPeerByIP :: (HasSQLDB m, MonadResource m, MonadBaseControl IO m, MonadThrow m)=>String->m (Maybe (SQL.Entity PPeer))
getPeerByIP ip = do
  db <- getSQLDB
  entPeer <- runResourceT $ SQL.runSqlPool actions db
  
  case entPeer of 
    [] -> return Nothing
    lst -> return $ Just . head $ lst

  where actions = SQL.selectList [ PPeerIp SQL.==. (T.pack ip) ] []

  

