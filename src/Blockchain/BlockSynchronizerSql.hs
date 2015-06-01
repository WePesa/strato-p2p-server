{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Blockchain.BlockSynchronizerSql (
   getBestBlockHash,
   getBestBlock,
   getBlockHashes,
   handleBlockRequest,
   getTransactionFromNotif
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

import qualified Data.Text as T
import qualified Database.Persist.Sql as SQL
import qualified Database.Esqueleto as E

ethVersion :: Int
ethVersion = 60

getBestBlockHash :: (EthCryptMLite ContextMLite) (SHA, Integer)
getBestBlockHash = do
  cxt <- lift $ lift $ get
  blks <-  E.runSqlPool actions $ sqlDBLite cxt

  return $ head $ map (\t -> (blockDataRefHash t, blockDataRefTotalDifficulty t))(map E.entityVal (blks :: [E.Entity BlockDataRef])) 
  
  where actions =   E.select $
                       E.from $ \(bdRef) -> do
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef

getBestBlock :: (EthCryptMLite ContextMLite) Block
getBestBlock = do
  cxt <- lift $ lift $ get
  blks <-  E.runSqlPool actions $ sqlDBLite cxt

  return $ head $ (map E.entityVal (blks :: [E.Entity Block])) 
  
  where actions =   E.select $
                       E.from $ \(bdRef `E.InnerJoin` blk) -> do
                       E.on ( ( bdRef E.^. BlockDataRefBlockId E.==. blk E.^. BlockId) )
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return blk

getBlockHashes :: [SHA] -> Integer  -> (EthCryptMLite ContextMLite) [SHA]
getBlockHashes shas numBlocks = do
  cxt <- lift $ lift $ get
   
  firstBdRef <- E.runSqlPool (find $ head shas) $ sqlDBLite cxt

  let firstNumber = blockDataRefNumber $ (E.entityVal . head) $ firstBdRef
      total = min maxBlockHashes (fromIntegral numBlocks)
      
  (blks :: [ SQL.Single SHA ] ) <- SQL.runSqlPool (actions (firstNumber) (max (firstNumber - (fromIntegral $ total)) 0 )) $ sqlDBLite cxt

  let blkShas = map SQL.unSingle blks
        
  liftIO $ putStrLn $ "got back: " ++ (show $ length blkShas) ++ " blockHashes with eventual child " ++ (show firstNumber)
  return $ blkShas
  
  where find h =   E.select $
                       E.from $ \(bdRef) -> do
                       E.where_ ( (bdRef E.^. BlockDataRefHash) E.==. E.val h )
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef


        actions upperLimit lowerLimit  =
                   SQL.rawSql 
		       (
                        T.pack $ 
                        "SELECT hash FROM block_data_ref WHERE number >= "
                        ++ show lowerLimit
                        ++ " AND number < "
                        ++ show upperLimit ++ " ORDER BY number DESC"
                        ++ " LIMIT " ++ show maxBlockHashes
                       )
                       [ ]                       

maxBlockHashes :: Int
maxBlockHashes = 2048

maxBlocks :: Int
maxBlocks = 512

shaList2Filter :: (E.Esqueleto query expr backend) =>(expr (E.Entity BlockDataRef), expr (E.Entity Block))-> [SHA] -> expr (E.Value Bool)
shaList2Filter (bdRef, blk) shaList = (foldl1 (E.||.) (map (\sha -> bdRef E.^. BlockDataRefHash E.==. E.val sha) shaList))

handleBlockRequest :: [SHA] -> (EthCryptMLite ContextMLite) [Block]
handleBlockRequest shaList = do
  let len = length shaList

  cxt <- lift $ lift $ get

  let total = min maxBlocks len
      
  blks <- E.runSqlPool (actions shaList total) $ sqlDBLite cxt

  liftIO $ putStrLn $ "serving: " ++ (show total) ++ " blocks "
  return $ (map E.entityVal (blks :: [E.Entity Block])) 
  
  where find h =   E.select $
                       E.from $ \(bdRef) -> do
                       E.where_ ( (bdRef E.^. BlockDataRefHash) E.==. E.val h )
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef
                       
        actions shas lim  =
                   E.select $
                       E.from $ \(bdr `E.InnerJoin` blk) -> do
                       E.on ( ( bdr E.^. BlockDataRefBlockId E.==. blk E.^. BlockId) )
                       E.limit $ fromIntegral $ lim
                       E.where_ $ ( shaList2Filter (bdr, blk) shas)
                       E.orderBy [E.asc (bdr E.^. BlockDataRefNumber)]
                       return blk

getTransactionFromNotif :: Int -> (EthCryptMLite ContextMLite ) [RawTransaction]
getTransactionFromNotif row = do
    cxt <- lift $ lift $ get
    tx <- SQL.runSqlPool (actions row) $ sqlDBLite cxt
    return (map SQL.entityVal tx)

    where actions nt = SQL.selectList [ RawTransactionId SQL.==. (SQL.toSqlKey $ fromIntegral $ row ) ]
                                      [ SQL.LimitTo 1]
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