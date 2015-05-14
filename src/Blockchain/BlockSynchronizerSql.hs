{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Blockchain.BlockSynchronizerSql (
   getBestBlockHash
  ) where

import Control.Monad.Trans.State
import Control.Monad.IO.Class
import Control.Monad.Trans
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import System.IO


import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Crypto.Cipher.AES
import qualified Crypto.Hash.SHA3 as SHA3
import Data.Bits
import qualified Data.ByteString as B
import System.IO

import Blockchain.SHA

import qualified Blockchain.AESCTR as AES
import Blockchain.Data.RLP
import Blockchain.Data.Wire
import Blockchain.Data.DataDefs
import Blockchain.DBM
import Blockchain.RLPx
import Blockchain.ContextLite

import Conduit
import Data.Conduit
import qualified Data.Conduit.Binary as CBN

import Blockchain.ContextLite
import Data.Conduit.Serialization.Binary
import Data.Bits

import qualified Database.Esqueleto as E

ethVersion :: Int
ethVersion = 60


getBestBlockHash :: (EthCryptMLite ContextMLite) SHA
getBestBlockHash = do
  cxt <- lift $ lift $ get
  blks <-  E.runSqlPool actions $ sqlDBLite cxt

  return $ head $ map blockDataRefHash (map E.entityVal (blks :: [E.Entity BlockDataRef])) 
  
  where actions =   E.select $
                       E.from $ \(bdRef) -> do
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef


{-
findFirstHashAlreadyInDB::[SHA]->ContextM (Maybe SHA)

handleNewBlockHashes::[SHA]->EthCryptM ContextM ()

handleNewTransactions::[Transaction]-> 
askForSomeBlocks::EthCryptM ContextM ()

handleNewBlocks::[Block]->EthCryptM ContextM ()

getBestBlockHash::ContextM SHA

getGenesisBlockHash::ContextM SHA

getBestBlock::ContextM Block

replaceBestIfBetter::Block->ContextM ()

handleBlockRequest::[SHA]->EthCryptM ContextM ()
-}
