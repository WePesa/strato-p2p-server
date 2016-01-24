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

import Blockchain.SHA
import qualified Blockchain.AESCTR as AES
import Blockchain.Data.RLP
import Blockchain.Data.Wire
import Blockchain.ContextLite
import Blockchain.BlockSynchronizerSql
import Blockchain.Data.BlockDB
import Blockchain.DB.DetailsDB hiding (getBestBlockHash)
import Blockchain.Data.RawTransaction
import Blockchain.Format

import Blockchain.ServOptions

import Conduit
import qualified Data.Conduit.Binary as CBN

ethVersion :: Int
ethVersion = 61

frontierGenesisHash :: SHA
frontierGenesisHash =
  -- (SHA 0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3)
  SHA 0xc6c980ae0132279535f4d085b9ba2d508ef5d4b19459045f54dac46d797cf3bb

data RowNotification = TransactionNotification RawTransaction | BlockNotification Block Integer
data MessageOrNotification = EthMessage Message | Notif RowNotification

respondMsgConduit :: Message 
                  -> Producer (ResourceT (EthCryptMLite ContextMLite)) B.ByteString
respondMsgConduit m = do
   liftIO $ putStrLn $ "<<<<<<<\n" ++ (format m)
   
   case m of
       Hello{} -> do
         cxt <- lift $ lift $ get
  
         if ((isClient cxt)) then do -- put not back in
           let helloMsg =  Hello {
                             version = 4,
                             clientId = "Ethereum(G)/v0.6.4//linux/Haskell",
                             capability = [ETH (fromIntegral  ethVersion ) ], -- , SHH shhVersion],
                             port = 0, -- formerly 30303
                             nodeId = peerId cxt
                           }
           sendMsgConduit $ helloMsg
           liftIO $ putStrLn $ ">>>>>>>>>>>\n" ++ (format helloMsg)
         else do  
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

       GetPeers -> do
         sendMsgConduit $ Peers []
         sendMsgConduit GetPeers      

       BlockHashes _ -> liftIO $ putStrLn "got new blockhashes"

       GetBlockHashes h maxBlocks -> do
         hashes <- lift $ lift $ getBlockHashes h maxBlocks
         sendMsgConduit $ BlockHashes hashes 

       GetBlocks shaList -> do
         blks <- lift $ lift $ handleBlockRequest shaList
         sendMsgConduit $ Blocks blks

       Blocks _ -> liftIO $ putStrLn "got new blocks"

       NewBlockPacket _ _ -> liftIO $ putStrLn "got a new block packet"

       Status{} -> do
             (h,d)<- lift $ lift $ getBestBlockHash
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

       Transactions _ ->
         sendMsgConduit (Transactions [])

       Disconnect reason ->
         liftIO $ putStrLn $ "peer disconnected with reason: " ++ (show reason)

       GetTransactions _ -> liftIO $ putStrLn "peer asked for transaction"
       _ -> liftIO $ putStrLn $ "unrecognized message"
      
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
    (Notif (BlockNotification block difficulty)) -> do
         liftIO $ putStrLn $ "got new block, maybe should feed it upstream, on row " ++ (show block)
         let blockMsg = NewBlockPacket block difficulty
         sendMsgConduit $ blockMsg
         liftIO $ putStrLn $ " <handleMsgConduit> >>>>>>>>>>>\n" ++ (format blockMsg) 
    _ -> liftIO $ putStrLn "got something unexpected in handleMsgConduit"

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


recvMsgConduit :: Conduit B.ByteString (ResourceT (EthCryptMLite ContextMLite)) MessageOrNotification
recvMsgConduit = do

  headCipher <- CBN.take 16
  headMAC <- CBN.take 16
  expectedHeadMAC <- lift $ lift $ updateIngressMac $ (BL.toStrict headCipher)
  
  when (expectedHeadMAC /= (BL.toStrict headMAC)) $ error ("oops, head mac isn't what I expected, headCipher: " ++ (show headCipher))

  header <- lift $ lift $ decrypt (BL.toStrict headCipher)

  let frameSize = 
        (fromIntegral (header `B.index` 0) `shiftL` 16) +
        (fromIntegral (header `B.index` 1) `shiftL` 8) +
        fromIntegral (header `B.index` 2)
      frameBufferSize = (16 - (frameSize `mod` 16)) `mod` 16

  frameCipher <- CBN.take (frameSize + frameBufferSize)
  frameMAC <- CBN.take 16


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
bXor x y = error $
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

