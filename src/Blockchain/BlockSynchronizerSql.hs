{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Blockchain.BlockSynchronizerSql (
   getBestBlockHash,
   getBestBlock,
   getBlockHashes,
   handleBlockRequest
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

getBestBlockHash :: (EthCryptMLite ContextMLite) (SHA, Integer)
getBestBlockHash = do
  cxt <- lift $ lift $ get
  blks <-  E.runSqlPool actions $ sqlDBLite cxt

  return $ head $ map (\t -> (blockDataRefHash t, blockDataRefDifficulty t))(map E.entityVal (blks :: [E.Entity BlockDataRef])) 
  
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
      
  blkShas <- fmap (map (blockDataRefHash . E.entityVal) ) $ E.runSqlPool (actions (firstNumber) (max (firstNumber - (fromIntegral $ total)) 0 )) $ sqlDBLite cxt

  liftIO $ putStrLn $ "got back: " ++ (show $ length blkShas) ++ " blocks with eventual child " ++ (show firstNumber)
  return $ blkShas
  
  where find h =   E.select $
                       E.from $ \(bdRef) -> do
                       E.where_ ( (bdRef E.^. BlockDataRefHash) E.==. E.val h )
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef
                       
        actions upperLimit lowerLimit =
                   E.select $
                       E.from $ \(bdr `E.InnerJoin` blk) -> do
                       E.on ( ( bdr E.^. BlockDataRefBlockId E.==. blk E.^. BlockId) )
                       E.orderBy [E.desc (bdr E.^. BlockDataRefNumber)]
                       E.where_ $ ( (bdr E.^. BlockDataRefNumber E.>=. E.val (fromIntegral $ lowerLimit) )
                                   E.&&. (bdr E.^. BlockDataRefNumber E.<. E.val (fromIntegral $ upperLimit )))
                       
                       E.limit $ fromIntegral $ (upperLimit - lowerLimit+1)
                       return bdr

maxBlockHashes :: Int
maxBlockHashes = 512

maxBlocks :: Int
maxBlocks = 512

{-
 Cheats and assumes the SHA list is contiguous.
 We'll see how this goes vis-a-vis our peer rating. This strategy is likely to dramatically speed up the queries
 compared to making separate SQL requests for each SHA.
-}
handleBlockRequest :: [SHA] -> (EthCryptMLite ContextMLite) [Block]
handleBlockRequest shaList = do
  let len = length shaList
      first = head shaList
      
  cxt <- lift $ lift $ get
  firstBdRef <- E.runSqlPool (find first) $ sqlDBLite cxt

  let firstNumber = blockDataRefNumber $ (E.entityVal . head) $ firstBdRef
      total = min maxBlocks len
      
  blks <- E.runSqlPool (actions firstNumber (firstNumber+ (fromIntegral $ total-1))) $ sqlDBLite cxt

  liftIO $ putStrLn $ "serving: " ++ (show total) ++ " blocks, starting with number " ++ (show firstNumber)
  return $ (map E.entityVal (blks :: [E.Entity Block])) 
  
  where find h =   E.select $
                       E.from $ \(bdRef) -> do
                       E.where_ ( (bdRef E.^. BlockDataRefHash) E.==. E.val h )
                       E.limit $ 1 
                       E.orderBy [E.desc (bdRef E.^. BlockDataRefNumber)]
                       return bdRef
                       
        actions fn ln =
                   E.select $
                       E.from $ \(bdr `E.InnerJoin` blk) -> do
                       E.on ( ( bdr E.^. BlockDataRefBlockId E.==. blk E.^. BlockId) )
                       E.limit $ fromIntegral $ (ln-fn)
                       E.where_ $ ( (bdr E.^. BlockDataRefNumber E.>=. E.val (fromIntegral $ fn) )
                                   E.&&. (bdr E.^. BlockDataRefNumber E.<=. E.val (fromIntegral $ ln )))
                       E.orderBy [E.desc (bdr E.^. BlockDataRefNumber)]
                       return blk


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
