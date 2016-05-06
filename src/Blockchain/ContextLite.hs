{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  runEthCryptMLite,
  initContextLite,
  getBlockHeaders,
  putBlockHeaders,
  addPeer,
  getPeerByIP
  ) where


import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Resource

import Blockchain.Data.BlockHeader
import Blockchain.DBM
import Blockchain.DB.SQLDB
import Blockchain.Data.DataDefs

import qualified Database.Persist.Postgresql as SQL
import qualified Database.PostgreSQL.Simple as PS

import qualified Data.Text as T

data ContextLite =
  ContextLite {
    liteSQLDB::SQLDB,
    blockHeaders::[BlockHeader]
  } deriving Show


instance Show PS.Connection where
  show _ = "Postgres Simple Connection"

type ContextMLite = StateT ContextLite (ResourceT IO)

instance HasSQLDB ContextMLite where
  getSQLDB = fmap liteSQLDB get

getBlockHeaders::MonadState ContextLite m=>m [BlockHeader]
getBlockHeaders = do
  cxt <- get
  return $ blockHeaders cxt

putBlockHeaders::MonadState ContextLite m=>[BlockHeader]->m ()
putBlockHeaders headers = do
  cxt <- get
  put cxt{blockHeaders=headers}

runEthCryptMLite::ContextLite->ContextMLite a->IO ()
runEthCryptMLite cxt f = do
  _ <- runResourceT $
       flip runStateT cxt $
       f
  return ()


initContextLite :: (MonadResource m, MonadIO m, MonadBaseControl IO m) => SQL.ConnectionString -> m ContextLite
initContextLite _ = do
  dbs <- openDBs
  return ContextLite {
                    liteSQLDB = sqlDB' dbs,                    
                    blockHeaders=[]
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

  

