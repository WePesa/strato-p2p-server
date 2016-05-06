{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Blockchain.CommunicationConduit (
  handleMsgConduit
  ) where

import Control.Monad
import Control.Monad.State
import Control.Monad.Trans

import           Crypto.Types.PubKey.ECC

import Data.List
import Data.Maybe

import qualified Data.Set as S
import Network.Kafka.Protocol (Offset)

import Numeric

import System.Log.Logger

import Blockchain.Data.BlockHeader
import Blockchain.Data.Wire
import qualified Blockchain.Colors as C
import Blockchain.ContextLite
import Blockchain.BlockSynchronizerSql
import Blockchain.Data.BlockDB
import Blockchain.Data.BlockOffset
import Blockchain.Data.DataDefs
import Blockchain.Data.NewBlk
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.DetailsDB hiding (getBestBlockHash)
import Blockchain.DB.SQLDB
import Blockchain.Event
import Blockchain.Format
import Blockchain.SHA
import Blockchain.Stream.VMEvent

import Blockchain.ServOptions

import Blockchain.Util
import Blockchain.Verification

import Conduit

ethVersion :: Int
ethVersion = 61

fetchLimit::Offset
fetchLimit = 50

setTitleAndProduceBlocks::HasSQLDB m=>[Block]->m Int
setTitleAndProduceBlocks blocks = do
  
  lastVMEvents <- liftIO $ fetchLastVMEvents fetchLimit
  let lastBlockHashes = [blockHash b | ChainBlock b <- lastVMEvents]
  let newBlocks = filter (not . (`elem` lastBlockHashes) . blockHash) blocks
  when (not $ null newBlocks) $ do
    liftIO $ errorM "p2p-server" $ "Block #" ++ show (maximum $ map (blockDataNumber . blockBlockData) newBlocks)
    --liftIO $ C.setTitle $ "Block #" ++ show (maximum $ map (blockDataNumber . blockBlockData) newBlocks)
    _ <- produceVMEvents $ map ChainBlock newBlocks

    return ()

  return $ length newBlocks



maxReturnedHeaders::Int
maxReturnedHeaders=1000

format'::Event->String
format' (MsgEvt (BlockHeaders _)) = C.blue "BlockHeaders:"
format' (MsgEvt x) = format x
format' x = show x

shortFormatSHA::SHA->String
shortFormatSHA (SHA x) = C.yellow $ take 6 $ padZeros 64 $ showHex x ""

commaUnwords::[String]->String
commaUnwords = intercalate ", "

filterRequestedBlocks::[SHA]->[Block]->[Block]
filterRequestedBlocks _ [] = []
filterRequestedBlocks [] _ = []
filterRequestedBlocks (h:hRest) (b:bRest) | blockHash b == h = b:filterRequestedBlocks hRest bRest
filterRequestedBlocks hashes (_:bRest) = filterRequestedBlocks hashes bRest

respondMsgConduit::(MonadIO m, MonadResource m, HasSQLDB m, MonadState ContextLite m)=>
                   String->Conduit Event m Message
respondMsgConduit peerName = awaitForever $ \msg -> do
   liftIO $ errorM "p2p-server" $ "<<<<<<<" ++ peerName ++ "\n" ++ (format' msg)
   
   case msg of
    MsgEvt Hello{} -> error "peer reinitiate the handshake after it has completed"
    MsgEvt Status{} -> error "peer reinitiating the handshake after it has completed"
    MsgEvt Ping -> do
         yield Pong
         liftIO $ errorM "p2p-server" $ ">>>>>>>>>>>" ++ peerName ++ "\n" ++ (format Pong)

    MsgEvt (Transactions txs) -> lift $ insertTXIfNew Nothing txs

    MsgEvt (NewBlock block' _) -> do
         lift $ putNewBlk $ blockToNewBlk block'
         let parentHash' = blockDataParentHash $ blockBlockData block'
         blockOffsets <- lift $ getBlockOffsetsForHashes [parentHash']
         case blockOffsets of
          [x] | blockOffsetHash x == parentHash' -> do
                  _ <- lift $ setTitleAndProduceBlocks [block']
                  return ()
          _ -> do
            liftIO $ putStrLn "#### New block is missing its parent, I am resyncing"
            syncFetch



    MsgEvt (BlockHeaders headers) -> do
         liftIO $ errorM "p2p-server" $ "(" ++ commaUnwords (map (\h -> "#" ++ (show $ number h) ++ " [" ++ (shortFormatSHA $ headerHash h) ++ "....]") headers) ++ ")"
         alreadyRequestedHeaders <- lift getBlockHeaders
         when (null alreadyRequestedHeaders) $ do
           let headerHashes = S.fromList $ map headerHash headers
               neededParentHashes = S.fromList $ map parentHash $ filter ((/= 0) . number) headers
               allNeeded = headerHashes `S.union` neededParentHashes
           found <- lift $ fmap (S.fromList . map blockOffsetHash) $ getBlockOffsetsForHashes $ S.toList allNeeded
           let unfoundParents = S.toList $ neededParentHashes S.\\ headerHashes S.\\found
               
           when (not $ null unfoundParents) $ do
             error $ "incoming blocks don't seem to have existing parents: " ++ unlines (map format $ unfoundParents)

           let neededHeaders = filter (not . (`elem` found) . headerHash) headers

           lift $ putBlockHeaders neededHeaders
           liftIO $ errorM "p2p-server" $ "putBlockHeaders called with length " ++ show (length neededHeaders)
           yield $ GetBlockBodies $ map headerHash neededHeaders
                
    MsgEvt (NewBlockHashes _) -> syncFetch
         
    MsgEvt (BlockBodies []) -> return ()
    MsgEvt (BlockBodies bodies) -> do
         headers <- lift getBlockHeaders
         let verified = and $ zipWith (\h b -> transactionsRoot h == transactionsVerificationValue (fst b)) headers bodies
         when (not verified) $ error "headers don't match bodies"
         --when (length headers /= length bodies) $ error "not enough bodies returned"
         liftIO $ errorM "p2p-server" $ "len headers is " ++ show (length headers) ++ ", len bodies is " ++ show (length bodies)
         newCount <- lift $ setTitleAndProduceBlocks $ zipWith createBlockFromHeaderAndBody headers bodies
         let remainingHeaders = drop (length bodies) headers
         lift $ putBlockHeaders remainingHeaders
         if null remainingHeaders
           then 
             if newCount > 0
               then yield $ GetBlockHeaders (BlockHash $ headerHash $ last headers) maxReturnedHeaders 0 Forward
               else return ()
           else yield $ GetBlockBodies $ map headerHash remainingHeaders
                
    MsgEvt (GetBlockHeaders start max' 0 Forward) -> do
         blockOffsets <-
           case start of
            BlockNumber n -> lift $ fmap (map blockOffsetOffset) $ getBlockOffsetsForNumber $ fromIntegral n
            BlockHash h -> lift $ getOffsetsForHashes [h]

         blocks <-
           case blockOffsets of
            [] -> return []
            (blockOffset:_) -> do
                vmEvents <- liftIO $ fmap (fromMaybe []) $ fetchVMEventsIO $ fromIntegral blockOffset
                return [b | ChainBlock b <- vmEvents]

         let blocksWithHashes = map (\b -> (blockHash b, b)) blocks
         existingHashes <- lift $ fmap (map blockOffsetHash) $ getBlockOffsetsForHashes $ map fst blocksWithHashes
         let existingBlocks = map snd $ filter ((`elem` existingHashes) . fst) blocksWithHashes
                

         yield $ BlockHeaders $ nub $ map blockToBlockHeader  $ take max' $ filter ((/= MP.StateRoot "") . blockDataStateRoot . blockBlockData) existingBlocks
         return ()

    MsgEvt (GetBlockBodies []) -> yield $ BlockBodies []
    MsgEvt (GetBlockBodies headers@(first:_)) -> do
         offsets <- lift $ getOffsetsForHashes [first]
         case offsets of
           [] -> error $ "########### Warning: peer is asking for a block I don't have: " ++ format first
           (o:_) -> do
             vmEvents <- liftIO $ fmap (fromMaybe (error "Internal error: an offset in SQL points to a value ouside of the block stream.")) $ fetchVMEventsIO $ fromIntegral o
             let blocks = [b | ChainBlock b <- vmEvents]
             let requestedBlocks = filterRequestedBlocks headers blocks
             yield $ BlockBodies $ map blockToBody requestedBlocks
                
    MsgEvt (Disconnect reason) ->
         liftIO $ errorM "p2p-server" $ "peer disconnected with reason: " ++ (show reason)

    NewTX tx -> do
           liftIO $ errorM "p2p-server" $ "got new transaction, maybe should feed it upstream, on row " ++ (show tx)
           let txMsg = Transactions [rawTX2TX tx]
           yield txMsg
           liftIO $ errorM "p2p-server" $ " <handleMsgConduit> >>>>>>>>>>> " ++ peerName ++ "\n" ++ (format txMsg) 
    NewBL b d -> do
           liftIO $ errorM "p2p-server" $ "A new block was inserted in SQL, maybe should feed it upstream" ++
             tab ("\n" ++ format b)
           yield $ NewBlock b d
           liftIO $ errorM "p2p-server" $ " <handleMsgConduit> >>>>>>>>>>>" ++ peerName ++ "\n" ++ (format b) 
--    _ -> liftIO $ errorM "p2p-server" "got something unexpected in handleMsgConduit"

    event -> liftIO $ errorM "p2p-server" $ "unrecognized event: " ++ show event



syncFetch::(MonadIO m, MonadState ContextLite m)=>
           Conduit Event m Message
syncFetch = do
  blockHeaders' <- lift getBlockHeaders
  when (null blockHeaders') $ do
    lastVMEvents <- liftIO $ fetchLastVMEvents fetchLimit
    case lastVMEvents of
     [] -> error "syncFetch overflow"
     x -> do
       let lastBlocks = [b | ChainBlock b <- x]
           lastBlockNumber = blockDataNumber . blockBlockData . last $ lastBlocks
       yield $ GetBlockHeaders (BlockNumber lastBlockNumber) maxReturnedHeaders 0 Forward
         


awaitMsg::MonadIO m=>ConduitM Event Message m (Maybe Message)
awaitMsg = do
  x <- await
  case x of
   Just (MsgEvt msg) -> return $ Just msg
   Nothing -> return Nothing
   _ -> awaitMsg

      
handleMsgConduit::(MonadIO m, MonadResource m, HasSQLDB m, MonadState ContextLite m)=>
                  Point->String->Conduit Event m Message

handleMsgConduit peerId peerName = do

  helloMsg <- awaitMsg
 
  case helloMsg of
   Just Hello{} -> do
         let helloMsg' = Hello {
               version = 4,
               clientId = "Ethereum(G)/v0.6.4//linux/Haskell",
               capability = [ETH (fromIntegral  ethVersion ) ], -- , SHH shhVersion],
               port = 0, -- formerly 30303
               nodeId = peerId
               }
         yield helloMsg'
         liftIO $ errorM "p2p-server" $ ">>>>>>>>>>> " ++ peerName ++ "\n" ++ (format helloMsg')
   Just _ -> error "Peer communicated before handshake was complete"
   Nothing -> error "peer hung up before handshake finished"

  statusMsg <- awaitMsg

  case statusMsg of
   Just Status{} -> do
           (h,d) <- lift getBestBlockHash
           genHash <- lift getGenesisBlockHash
           let statusMsg' = Status{
                              protocolVersion=fromIntegral ethVersion,
                              networkID=flags_networkID,
                              totalDifficulty= fromIntegral $ d,
                              latestHash=h,
                              genesisHash=genHash
                            }
           yield statusMsg'
           liftIO $ errorM "p2p-server" $ ">>>>>>>>>>>" ++ peerName ++ "\n" ++ (format statusMsg')
   Just _ -> error "Peer communicated before handshake was complete"
   Nothing -> error "peer hung up before handshake finished"

  respondMsgConduit peerName

