{-# LANGUAGE OverloadedStrings #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  TContext,
 -- isDebugEnabled,
  addPingCountLite,
  initContextLite
  ) where


import Control.Monad.IfElse
import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Resource

import Blockchain.Constants
import Blockchain.DBM

import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.DataDefs
import Blockchain.Data.Transaction

import Blockchain.Data.RLP
import qualified Blockchain.Database.MerklePatricia as MPDB
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
import qualified Database.PostgreSQL.Simple as PS
import Database.PostgreSQL.Simple.Notification



data ContextLite =
  ContextLite {
    neededBlockHashes::[SHA],
    newBlocks::[Block],        -- for propagating mined blocks, or possibly blocks at the head
    newTransactions::[Transaction],
    pingCount::Int,
    peers:: Map.Map String Point,
    debugEnabled::Bool,
    notifHandler::PS.Connection
  } 

type TContext = TVar ContextLite
type ContextMLite = StateT ContextLite DBMLite

initContextLite :: IO ContextLite
initContextLite = do
  notif <- PS.connect PS.defaultConnectInfo {
            PS.connectPassword = "api",
            PS.connectDatabase = "eth"
           }
  return  ContextLite {
                    neededBlockHashes = [],
                    newBlocks = [],
                    newTransactions = [],
                    pingCount = 0,
                    peers = Map.fromList $ [],
                    debugEnabled = False,
                    notifHandler=notif
                 }
{-
isDebugEnabled::ContextMLite Bool
isDebugEnabled = do
  cxt <- ask
  cxt' <- readTVar cxt
  return $ debugEnabled cxt 
-}

addPingCountLite :: ContextMLite Int
addPingCountLite = do
  cxt <- get
  let pc = (pingCount cxt)+1
  put cxt{pingCount = pc}
  return $ pc

