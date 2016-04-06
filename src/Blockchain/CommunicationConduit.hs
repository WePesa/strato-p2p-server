{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Blockchain.CommunicationConduit (
  handleMsgConduit,
  sendMsgConduit,
  recvMsgConduit,
  MessageOrNotification(..),
  RowNotification(..),
  bXor
  ) where

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.State

import Crypto.Cipher.AES
import qualified Crypto.Hash.SHA3 as SHA3

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe

import qualified Data.Set as S

import qualified Blockchain.AESCTR as AES
import Blockchain.Data.BlockHeader
import Blockchain.Data.RLP
import Blockchain.Data.Wire
import Blockchain.ContextLite
import Blockchain.BlockSynchronizerSql
import Blockchain.Data.BlockDB
import Blockchain.Data.BlockOffset
import Blockchain.Data.DataDefs
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.DetailsDB hiding (getBestBlockHash)
import Blockchain.DB.SQLDB
import Blockchain.Error
import Blockchain.Format

import Blockchain.ServOptions

import Blockchain.Util

import Conduit
import qualified Data.Conduit.Binary as CB

ethVersion :: Int
ethVersion = 61

{-
frontierGenesisHash :: SHA
frontierGenesisHash =
  -- (SHA 0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3)
  SHA 0xc6c980ae0132279535f4d085b9ba2d508ef5d4b19459045f54dac46d797cf3bb
-}

data RowNotification = TransactionNotification RawTransaction | BlockNotification Block Integer
data MessageOrNotification = EthMessage Message | Notif RowNotification

setTitleAndProduceBlocks::HasSQLDB m=>[Block]->m Int
setTitleAndProduceBlocks blocks = do
  lastBlockHashes <- liftIO $ fmap (map blockHash) $ fetchLastBlocks 100
  let newBlocks = filter (not . (`elem` lastBlockHashes) . blockHash) blocks
  when (not $ null newBlocks) $ do
    liftIO $ putStrLn $ "Block #" ++ show (maximum $ map (blockDataNumber . blockBlockData) newBlocks)
    --liftIO $ C.setTitle $ "Block #" ++ show (maximum $ map (blockDataNumber . blockBlockData) newBlocks)
    _ <- produceBlocks newBlocks

    return ()

  return $ length newBlocks



maxReturnedHeaders::Int
maxReturnedHeaders=1000
  
respondMsgConduit :: Message 
                  -> Producer (ResourceT (EthCryptMLite ContextMLite)) B.ByteString
respondMsgConduit m = do
   liftIO $ putStrLn $ "<<<<<<<\n" ++ (format m)
   
   case m of
       Hello{} -> do
         cxt <- lift $ lift $ get
         let helloMsg =  Hello {
               version = 4,
               clientId = "Ethereum(G)/v0.6.4//linux/Haskell",
               capability = [ETH (fromIntegral  ethVersion ) ], -- , SHH shhVersion],
               port = 0, -- formerly 30303
               nodeId = peerId cxt
               }
         sendMsgConduit $ helloMsg
         liftIO $ putStrLn $ ">>>>>>>>>>>\n" ++ (format helloMsg)
       Status{} -> do
           (h,d) <- lift $ lift $ getBestBlockHash
           genHash <- lift . lift . lift $ getGenesisBlockHash
           let statusMsg = Status{
                              protocolVersion=fromIntegral ethVersion,
                              networkID=flags_networkID,
                              totalDifficulty= fromIntegral $ d,
                              latestHash=h,
                              genesisHash=genHash
                            }
           sendMsgConduit $ statusMsg
           liftIO $ putStrLn $ ">>>>>>>>>>>\n" ++ (format statusMsg)
       Ping -> do
         sendMsgConduit Pong
         liftIO $ putStrLn $ ">>>>>>>>>>>\n" ++ (format Pong)

       NewBlock block' _ -> do
         lastBlockHashes <- liftIO $ fmap (map blockHash) $ fetchLastBlocks 100
         if blockDataParentHash (blockBlockData block') `elem` lastBlockHashes
           then do
             _ <- lift $ lift $ lift $ setTitleAndProduceBlocks [block']
             return ()
           else do
             liftIO $ putStrLn "#### New block is missing its parent, I am resyncing"
             syncFetch

       BlockHeaders headers -> do
         alreadyRequestedHeaders <- lift $ lift $ lift getBlockHeaders
         if (null alreadyRequestedHeaders) then do
           lastBlocks <- liftIO $ fetchLastBlocks 1000
           --liftIO $ putStrLn $ unlines $ map format lastBlocks
           --liftIO $ putStrLn $ unlines $ map format headers
           let lastBlockHashes = map blockHash lastBlocks
           let allHashes = lastBlockHashes ++ map headerHash headers
               neededParentHashes = map parentHash $ filter ((/= 0) . number) headers
           when (not $ null $ S.fromList neededParentHashes S.\\ S.fromList allHashes) $ 
                error "incoming blocks don't seem to have existing parents"
           let neededHeaders = filter (not . (`elem` (map blockHash lastBlocks)) . headerHash) headers
           lift $ lift $ lift $ putBlockHeaders neededHeaders
           liftIO $ putStrLn $ "putBlockHeaders called with length " ++ show (length neededHeaders)
           sendMsgConduit $ GetBlockBodies $ map headerHash neededHeaders
           else return ()
           
       NewBlockHashes _ -> syncFetch
         
       BlockBodies [] -> return ()
       BlockBodies bodies -> do
         headers <- lift $ lift $ lift getBlockHeaders
         --when (length headers /= length bodies) $ error "not enough bodies returned"
         liftIO $ putStrLn $ "len headers is " ++ show (length headers) ++ ", len bodies is " ++ show (length bodies)
         newCount <- lift $ lift $ lift $ setTitleAndProduceBlocks $ zipWith createBlockFromHeaderAndBody headers bodies
         let remainingHeaders = drop (length bodies) headers
         lift $ lift $ lift $ putBlockHeaders remainingHeaders
         if null remainingHeaders
           then 
             if newCount > 0
               then sendMsgConduit $ GetBlockHeaders (BlockHash $ headerHash $ last headers) maxReturnedHeaders 0 Forward
               else return ()
           else sendMsgConduit $ GetBlockBodies $ map headerHash remainingHeaders
                
       Transactions _ ->
         sendMsgConduit (Transactions [])

       GetBlockHeaders start max' 0 Forward -> do
         blockOffsets <-
           case start of
            BlockNumber n -> lift $ lift $ lift $ fmap (map blockOffsetOffset) $ getBlockOffsetsForNumber $ fromIntegral n
            BlockHash h -> lift $ lift $ lift $ getBlockOffsetsForHashes [h]
         
         blocks <-
           case blockOffsets of
            [] -> return []
            (blockOffset:_) -> liftIO $ fmap (fromMaybe []) $ fetchBlocksIO $ fromIntegral blockOffset
                
         sendMsgConduit $ BlockHeaders $ map blockToBlockHeader  $ take max' $ filter ((/= MP.SHAPtr "") . blockDataStateRoot . blockBlockData) blocks
         return ()

       GetBlockBodies hashes -> do
         offsets <- lift $ lift $ lift $ getBlockOffsetsForHashes hashes
         when (length offsets /= length hashes) $ error $ "########### Warning: peer is asking for blocks I don't have: " ++ unlines (map format hashes)
         maybeBlocks <- 
           case (isContiguous offsets, offsets) of
             (True, []) -> return []
             (True, x:_) ->liftIO $ fmap (map Just . take (length offsets) . fromMaybe []) $ fetchBlocksIO $ fromIntegral x
             _ -> do
               liftIO $ putStrLn "############ Warning: Very ineffecient block body query"
               liftIO $ forM offsets $ fetchBlocksOneIO . fromIntegral
         let blocks = catMaybes maybeBlocks
         if (length maybeBlocks == length blocks) 
           then sendMsgConduit $ BlockBodies $ map blockToBody blocks
           else liftIO $ putStrLn "Peer is asking for block bodies I don't have, I will just ignore the request"
                
       Disconnect reason ->
         liftIO $ putStrLn $ "peer disconnected with reason: " ++ (show reason)

       msg -> liftIO $ putStrLn $ "unrecognized message: " ++ show msg



syncFetch::Producer (ResourceT (EthCryptMLite ContextMLite)) B.ByteString
syncFetch = do
  blockHeaders' <- lift $ lift $ lift getBlockHeaders
  when (null blockHeaders') $ do
    lastBlockNumber <- liftIO $ fmap (blockDataNumber . blockBlockData . last) $ fetchLastBlocks 100
    sendMsgConduit $ GetBlockHeaders (BlockNumber lastBlockNumber) maxReturnedHeaders 0 Forward
         


      
handleMsgConduit :: ConduitM MessageOrNotification B.ByteString
                            (ResourceT (EthCryptMLite ContextMLite))
                            ()

handleMsgConduit = awaitForever $ \mn -> do
  case mn of
    (EthMessage m) -> respondMsgConduit m
    (Notif (TransactionNotification tx)) -> do
         liftIO $ putStrLn $ "got new transaction, maybe should feed it upstream, on row " ++ (show tx)
         let txMsg = Transactions [rawTX2TX tx]
         sendMsgConduit $ txMsg
         liftIO $ putStrLn $ " <handleMsgConduit> >>>>>>>>>>>\n" ++ (format txMsg) 
    (Notif (BlockNotification b d)) -> do
         liftIO $ putStrLn $ "got new block, maybe should feed it upstream, on row " ++ (show b)
         let blockMsg = NewBlock b d
         sendMsgConduit $ blockMsg
         liftIO $ putStrLn $ " <handleMsgConduit> >>>>>>>>>>>\n" ++ (format blockMsg) 
--    _ -> liftIO $ putStrLn "got something unexpected in handleMsgConduit"

sendMsgConduit :: MonadIO m 
               => Message 
               -> Producer (ResourceT (EthCryptMLite m)) B.ByteString
sendMsgConduit msg = do
  
  let (pType, pData) = wireMessage2Obj msg
  let bytes =  B.cons pType $ rlpSerialize pData
  let frameSize = B.length bytes
      frameBuffSize = (16 - frameSize `mod` 16) `mod` 16
      header = B.pack [fromIntegral $ frameSize `shiftR` 16,
                         fromIntegral $ frameSize `shiftR` 8,
                                    fromIntegral $ frameSize,
                                                        0xc2,
                                                        0x80,
                                                        0x80,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

  headCipher <- lift $ lift $ encrypt header
  headMAC <- lift $ lift $ updateEgressMac headCipher
  frameCipher <- lift $ lift $ encrypt (bytes `B.append` B.replicate frameBuffSize 0)
  frameMAC <- lift $ lift $ updateEgressMac =<< rawUpdateEgressMac frameCipher

  yield . B.concat $ [headCipher,headMAC,frameCipher,frameMAC]

cbSafeTake::Monad m=>Int->ConduitM B.ByteString o m (Maybe BL.ByteString)
cbSafeTake i = do
    ret <- CB.take i
    if BL.length ret /= fromIntegral i
       then return Nothing
       else return $ Just ret
            

recvMsgConduit :: Conduit B.ByteString (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification
recvMsgConduit = do

  headCipher <- fmap (fromMaybe $ error "Peer hung up") $ cbSafeTake 16
  headMAC <- fmap (fromMaybe $ error "Peer hung up") $ cbSafeTake 16
  expectedHeadMAC <- lift $ lift $ updateIngressMac $ (BL.toStrict headCipher)
  
  when (expectedHeadMAC /= (BL.toStrict headMAC)) $ error ("oops, head mac isn't what I expected, headCipher: " ++ (show headCipher))

  header <- lift $ lift $ decrypt (BL.toStrict headCipher)

  let frameSize = 
        (fromIntegral (header `B.index` 0) `shiftL` 16) +
        (fromIntegral (header `B.index` 1) `shiftL` 8) +
        fromIntegral (header `B.index` 2)
      frameBufferSize = (16 - (frameSize `mod` 16)) `mod` 16

  frameCipher <- fmap (fromMaybe $ error "Peer hung up") $ cbSafeTake (frameSize + frameBufferSize)
  frameMAC <- fmap (fromMaybe $ error "Peer hung up") $ cbSafeTake 16


  expectedFrameMAC <- lift $ lift $ updateIngressMac =<< rawUpdateIngressMac (BL.toStrict frameCipher)

  when (expectedFrameMAC /= (BL.toStrict frameMAC)) $ error "oops, frame mac isn't what I expected"
  fullFrame <- lift $ lift $ decrypt (BL.toStrict frameCipher)

  let frameData = B.take frameSize fullFrame
      packetType = fromInteger $ rlpDecode $ rlpDeserialize $ B.take 1 frameData
      packetData = rlpDeserialize $ B.drop 1 frameData

  yield . EthMessage  $ obj2WireMessage packetType packetData
  recvMsgConduit
      
bXor :: B.ByteString
     -> B.ByteString
     -> B.ByteString
bXor x y | B.length x == B.length y = B.pack $ B.zipWith xor x y 
bXor x y = error' $
           "bXor called with two ByteStrings of different length: length string1 = " ++
           show (B.length x) ++ ", length string2 = " ++ show (B.length y)

encrypt :: MonadIO m
        => B.ByteString
        -> EthCryptMLite m B.ByteString
encrypt input = do
  cState <- get
  let aesState = encryptState cState
  let (aesState', output) = AES.encrypt aesState input
  put cState{encryptState=aesState'}
  return output

decrypt :: MonadIO m
        => B.ByteString 
        -> EthCryptMLite m B.ByteString
decrypt input = do
  cState <- get
  let aesState = decryptState cState
  let (aesState', output) = AES.decrypt aesState input
  put cState{decryptState=aesState'}
  return output


rawUpdateEgressMac :: MonadIO m
                   => B.ByteString
                   -> EthCryptMLite m B.ByteString
rawUpdateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  let mac' = SHA3.update mac value
  put cState{egressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateEgressMac :: MonadIO m 
                => B.ByteString
                -> EthCryptMLite m B.ByteString
updateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  rawUpdateEgressMac $
    value `bXor` (encryptECB (initAES $ egressKey cState) (B.take 16 $ SHA3.finalize mac))

{-   -- commented for Wall --
getEgressMac :: MonadIO m
             => EthCryptMLite m B.ByteString
getEgressMac = do
  cState <- get
  let mac = egressMAC cState
  return $ B.take 16 $ SHA3.finalize mac

getIngressMac :: MonadIO m 
              => EthCryptMLite m B.ByteString
getIngressMac = do
  cState <- get
  let mac = ingressMAC cState
  return $ B.take 16 $ SHA3.finalize mac
-}

rawUpdateIngressMac :: MonadIO m
                    => B.ByteString
                    -> EthCryptMLite m B.ByteString
rawUpdateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  let mac' = SHA3.update mac value
  put cState{ingressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateIngressMac :: MonadIO m
                 => B.ByteString
                 -> EthCryptMLite m B.ByteString
updateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  rawUpdateIngressMac $
    value `bXor` (encryptECB (initAES $ ingressKey cState) (B.take 16 $ SHA3.finalize mac))

