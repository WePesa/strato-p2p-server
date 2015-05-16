{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Blockchain.CommunicationConduit (
  handleMsgConduit,
  sendMsgConduit,
  recvMsgConduit,
  bXor
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
import Blockchain.BlockSynchronizerSql

import Conduit
import Data.Conduit
import qualified Data.Conduit.Binary as CBN

import Data.Conduit.Serialization.Binary
import Data.Bits

import qualified Database.Esqueleto as E


ethVersion :: Int
ethVersion = 60
 
handleMsgConduit :: Conduit Message (EthCryptMLite ContextMLite) B.ByteString
handleMsgConduit = awaitForever $ \m -> do
   liftIO $ putStrLn $ "received message: " ++ (show m)
   
   case m of
       Hello{} -> do
         cxt <- lift $ get
         liftIO $ putStrLn $ "replying to hello"
         sendMsgConduit Hello {
                             version = 4,
                             clientId = "Ethereum(G)/v0.6.4//linux/Haskell",
                             capability = [ETH (fromIntegral  ethVersion ) ], -- , SHH shhVersion],
                             port = 30303,
                             nodeId = peerId cxt
                           }
       Ping -> do
         _ <- lift $ lift $  addPingCountLite
         liftIO $ putStrLn $ "replying to ping"
         sendMsgConduit Pong
       GetPeers -> do
         liftIO $ putStrLn $ "peer asked for peers"
         sendMsgConduit $ Peers []
         sendMsgConduit GetPeers      
       BlockHashes blockHashes -> liftIO $ putStrLn "got new blockhashes"
       GetBlockHashes h maxBlocks -> do
         liftIO $ putStrLn $ "peer requested: " ++ (show maxBlocks) ++  " block hashes, starting with: " ++ (show h)
         hashes <- lift $ getBlockHashes h maxBlocks
         sendMsgConduit $ BlockHashes hashes 
       GetBlocks shaList -> do
         liftIO $ putStrLn $ "peer requested blocks"
         blks <- lift $ handleBlockRequest shaList
         sendMsgConduit $ Blocks blks
       Blocks blocks -> liftIO $ putStrLn "got new blocks"
       NewBlockPacket block baseDifficulty -> liftIO $ putStrLn "got a new block packet"
       Status{latestHash=lh, genesisHash=gh} -> do
             (h,d)<- lift $ getBestBlockHash
             liftIO $ putStrLn $ "replying to status, best blockHash: " ++ (show h)
             sendMsgConduit Status{
                              protocolVersion=fromIntegral ethVersion,
                              networkID="",
                              totalDifficulty= fromIntegral $ d,
                              latestHash=h,
                              genesisHash=(SHA 0xfd4af92a79c7fc2fd8bf0d342f2e832e1d4f485c85b9152d2039e03bc604fdca)   
                            }
       Transactions lst ->
         sendMsgConduit (Transactions [])
       GetTransactions -> liftIO $ putStrLn "peer asked for transaction"
       _ -> liftIO $ putStrLn $ "unrecognized message"     


sendMsgConduit :: MonadIO m => Message -> Producer (EthCryptMLite m) B.ByteString
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

  headCipher <- lift $ encrypt header
  headMAC <- lift $ updateEgressMac headCipher
  frameCipher <- lift $ encrypt (bytes `B.append` B.replicate frameBuffSize 0)
  frameMAC <- lift $ updateEgressMac =<< rawUpdateEgressMac frameCipher


  yield . B.concat $ [headCipher,headMAC,frameCipher,frameMAC]
  

recvMsgConduit :: MonadIO m => Conduit B.ByteString (EthCryptMLite m) Message
recvMsgConduit = do
  headCipher <- CBN.take 16
  headMAC <- CBN.take 16

  liftIO $ putStrLn $ "headCipher: " ++ (show $ B.unpack $ BL.toStrict headCipher)
  liftIO $ putStrLn $ "headMAC:    " ++ (show $ B.unpack $ BL.toStrict headMAC)
  
  expectedHeadMAC <- lift $ updateIngressMac $ (BL.toStrict headCipher)

  liftIO $ putStrLn $ "expected: " ++ (show $ B.unpack expectedHeadMAC)
  
  when (expectedHeadMAC /= (BL.toStrict headMAC)) $ error "oops, head mac isn't what I expected"

  header <- lift $ decrypt (BL.toStrict headCipher)

  liftIO $ putStrLn $ "header: " ++ (show $ B.unpack header)
  
  let frameSize = 
        (fromIntegral (header `B.index` 0) `shiftL` 16) +
        (fromIntegral (header `B.index` 1) `shiftL` 8) +
        fromIntegral (header `B.index` 2)
      frameBufferSize = (16 - (frameSize `mod` 16)) `mod` 16

  frameCipher <- CBN.take (frameSize + frameBufferSize)
  frameMAC <- CBN.take 16


  expectedFrameMAC <- lift $ updateIngressMac =<< rawUpdateIngressMac (BL.toStrict frameCipher)

  when (expectedFrameMAC /= (BL.toStrict frameMAC)) $ error "oops, frame mac isn't what I expected"
  fullFrame <- lift $ decrypt (BL.toStrict frameCipher)

  liftIO $ putStrLn $ "fullFrame: " ++ (show fullFrame)
  
  let frameData = B.take frameSize fullFrame
      packetType = fromInteger $ rlpDecode $ rlpDeserialize $ B.take 1 frameData
      packetData = rlpDeserialize $ B.drop 1 frameData

  yield  $ obj2WireMessage packetType packetData
  recvMsgConduit
      
bXor::B.ByteString->B.ByteString->B.ByteString
bXor x y | B.length x == B.length y = B.pack $ B.zipWith xor x y 
bXor x y = error $
           "bXor called with two ByteStrings of different length: length string1 = " ++
           show (B.length x) ++ ", length string2 = " ++ show (B.length y)

encrypt::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
encrypt input = do
  cState <- get
  let aesState = encryptState cState
  let (aesState', output) = AES.encrypt aesState input
  put cState{encryptState=aesState'}
  return output

decrypt::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
decrypt input = do
  cState <- get
  let aesState = decryptState cState
  let (aesState', output) = AES.decrypt aesState input
  put cState{decryptState=aesState'}
  return output

getEgressMac::MonadIO m=>EthCryptMLite m B.ByteString
getEgressMac = do
  cState <- get
  let mac = egressMAC cState
  return $ B.take 16 $ SHA3.finalize mac

rawUpdateEgressMac::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
rawUpdateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  let mac' = SHA3.update mac value
  put cState{egressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateEgressMac::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
updateEgressMac value = do
  cState <- get
  let mac = egressMAC cState
  rawUpdateEgressMac $
    value `bXor` (encryptECB (initAES $ egressKey cState) (B.take 16 $ SHA3.finalize mac))

getIngressMac::MonadIO m=>EthCryptMLite m B.ByteString
getIngressMac = do
  cState <- get
  let mac = ingressMAC cState
  return $ B.take 16 $ SHA3.finalize mac

rawUpdateIngressMac::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
rawUpdateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  let mac' = SHA3.update mac value
  put cState{ingressMAC=mac'}
  return $ B.take 16 $ SHA3.finalize mac'

updateIngressMac::MonadIO m=>B.ByteString->EthCryptMLite m B.ByteString
updateIngressMac value = do
  cState <- get
  let mac = ingressMAC cState
  rawUpdateIngressMac $
    value `bXor` (encryptECB (initAES $ ingressKey cState) (B.take 16 $ SHA3.finalize mac))

