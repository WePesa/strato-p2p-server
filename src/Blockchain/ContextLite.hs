{-# LANGUAGE OverloadedStrings #-}

module Blockchain.ContextLite (
  ContextLite(..),
  ContextMLite,
  isDebugEnabled,
  addPingCountLite,
  initContextLite
  ) where


import Control.Monad.IfElse
import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Resource

import Blockchain.Constants
import Blockchain.DBM
import Blockchain.Data.Peer
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.DataDefs
import Blockchain.Data.RLP
import qualified Blockchain.Database.MerklePatricia as MPDB
import Blockchain.ExtWord
import Blockchain.SHA
import Blockchain.Util

import qualified Data.NibbleString as N

--import Debug.Trace

data ContextLite =
  ContextLite {
    neededBlockHashes::[SHA],
    pingCount::Int,
    peers::[Peer],
    debugEnabled::Bool
    }

type ContextMLite = StateT ContextLite DBMLite


initContextLite :: ContextLite
initContextLite = ContextLite {
                    neededBlockHashes = [],
                    pingCount = 0,
                    peers = [],
                    debugEnabled = False
                   }

isDebugEnabled::ContextMLite Bool
isDebugEnabled = do
  cxt <- get
  return $ debugEnabled cxt 

addPingCountLite :: ContextMLite Int
addPingCountLite = do
  cxt <- get
  let pc = (pingCount cxt)+1
  put cxt{pingCount = pc}
  return $ pc
