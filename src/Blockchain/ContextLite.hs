{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  TContext,
  runEthCryptMLite,
 -- isDebugEnabled,
  initContextLite,
  addPeer,
  getPeerByIP,
  EthCryptMLite(..),
  EthCryptStateLite(..)
  ) where


import Control.Monad.IfElse
import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Resource

import Blockchain.Constants
import Blockchain.DBM
import qualified Data.ByteString as B
import qualified Crypto.Hash.SHA3 as SHA3
import qualified Database.Persist.Postgresql as SQL

import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.DB.SQLDB
import Blockchain.Data.DataDefs
import Blockchain.Data.Transaction

import Blockchain.Data.RLP

import Blockchain.ExtWord
import Blockchain.SHA
import Blockchain.Util

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC

import qualified Data.NibbleString as N

import Data.Conduit.Network
import Network.Socket
import Network.Haskoin.Crypto

import Control.Concurrent.STM

import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PS
import Database.PostgreSQL.Simple.Notification
import qualified Blockchain.AESCTR as AES

data EthCryptStateLite =
  EthCryptStateLite {
    encryptState::AES.AESCTRState,
    decryptState::AES.AESCTRState,
    egressMAC::SHA3.Ctx,
    ingressMAC::SHA3.Ctx,
    egressKey::B.ByteString,
    ingressKey::B.ByteString,
    peerId::Point
    } 

type EthCryptMLite a = StateT EthCryptStateLite a

data ContextLite =
  ContextLite {
    peers:: Map.Map String Point, 
    liteSQLDB::SQLDB,
    notifHandler::PS.Connection,
    debugEnabled::Bool
  } deriving Show


instance Show PS.Connection where
  show conn = "Postgres Simple Connection"

type TContext = TVar ContextLite
type ContextMLite = StateT ContextLite (ResourceT IO)

instance HasSQLDB ContextMLite where
  getSQLDB = fmap liteSQLDB get

runEthCryptMLite::ContextLite->EthCryptStateLite->EthCryptMLite ContextMLite a->IO ()
runEthCryptMLite cxt cState f = do
  _ <- runResourceT $
       flip runStateT cxt $
       flip runStateT cState $
       f
  return ()


initContextLite :: (MonadResource m, MonadIO m, MonadBaseControl IO m) => SQL.ConnectionString -> m ContextLite
initContextLite str = do
  notif <- liftIO $ PS.connect PS.defaultConnectInfo {   -- bandaid, should eventually be added to monad class
            PS.connectPassword = "api",
            PS.connectDatabase = "eth"
           }
  dbs <- openDBsLite str
  return ContextLite {
                    peers = Map.fromList $ [],
                    liteSQLDB = sqlDBLite dbs,                    
                    notifHandler=notif,
                    debugEnabled = False
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

  
{-
isDebugEnabled::ContextMLite Bool
isDebugEnabled = do
  cxt <- ask
  cxt' <- readTVar cxt
  return $ debugEnabled cxt 
-}

