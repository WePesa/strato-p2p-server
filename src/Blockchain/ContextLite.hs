{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  TContext,
 -- isDebugEnabled,
  initContextLite,
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
type ContextMLite = StateT ContextLite DBMLite

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
  runResourceT $
    SQL.runSqlPool actions db
  where actions = SQL.insert $ peer                      

getPeerByIP :: (HasSQLDB m, MonadResource m, MonadBaseControl IO m, MonadThrow m)=>String->m (Maybe PPeer)
getPeerByIP ip = do
  db <- getSQLDB
  entPeer <- runResourceT $ SQL.runSqlPool actions db
  
  case entPeer of 
    [] -> return Nothing
    lst -> return $ Just . SQL.entityVal . head $ lst

  where actions = SQL.selectList [ PPeerIp SQL.==. (T.pack ip) ] []

  
{-
isDebugEnabled::ContextMLite Bool
isDebugEnabled = do
  cxt <- ask
  cxt' <- readTVar cxt
  return $ debugEnabled cxt 
-}

