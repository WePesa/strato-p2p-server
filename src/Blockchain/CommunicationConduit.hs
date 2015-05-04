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

import Blockchain.RLPx
import Blockchain.ContextLite

import Conduit
import Data.Conduit
import qualified Data.Conduit.Binary as CBN

import Data.Conduit.Serialization.Binary
import Data.Bits

data EthCryptStateLite =
  EthCryptStateLite {
    encryptState::AES.AESCTRState,
    decryptState::AES.AESCTRState,
    egressMAC::SHA3.Ctx,
    ingressMAC::SHA3.Ctx,
    egressKey::B.ByteString,
    ingressKey::B.ByteString
    }

type EthCryptMLite a = StateT EthCryptStateLite a


ethVersion :: Int
ethVersion = 60
 
handleMsgConduit :: Conduit Message (EthCryptMLite ContextMLite) B.ByteString
handleMsgConduit = awaitForever $ \m ->
   case m of
       Hello{} -> do
             sendMsgConduit Status{
                              protocolVersion=fromIntegral ethVersion,
                              networkID="",
                              totalDifficulty=0,
                              latestHash=(SHA 0),   -- fix these
                              genesisHash=(SHA 0)   -- 
                            }
       Ping -> do
         _ <- lift $ lift $  addPingCountLite
         sendMsgConduit Pong
       GetPeers -> do 
         sendMsgConduit $ Peers []
         sendMsgConduit GetPeers      
       BlockHashes blockHashes -> undefined
       GetBlocks blocks -> do
         sendMsgConduit $ Blocks []
       Blocks blocks -> undefined
       NewBlockPacket block baseDifficulty -> undefined
       Status{latestHash=lh, genesisHash=gh} -> undefined
       GetTransactions -> undefined
       _ -> undefined     


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
  

recvMsgConduitBS :: MonadIO m => Conduit B.ByteString (EthCryptMLite m) B.ByteString
recvMsgConduitBS = do
  headCipher <- CBN.take 16
  headMAC <- CBN.take 16
  
  expectedHeadMAC <- lift $ updateIngressMac $ (BL.toStrict headCipher)
  when (expectedHeadMAC /= (BL.toStrict headMAC)) $ error "oops, head mac isn't what I expected"

  header <- lift $ decrypt (BL.toStrict headCipher)

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
  
  yield $ B.take frameSize fullFrame


recvMsgConduit :: MonadIO m => Conduit B.ByteString (EthCryptMLite m) Message
recvMsgConduit = do
  frameDataMaybe <- await

  case frameDataMaybe of
    (Just frameData) -> do
        let packetType = fromInteger $ rlpDecode $ rlpDeserialize $ B.take 1 frameData
            packetData = rlpDeserialize $ B.drop 1 frameData

        yield  $ obj2WireMessage packetType packetData

    Nothing -> recvMsgConduit
      
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

{-
runEthCryptMLite::MonadIO m=>PrivateNumber->PublicPoint->EthCryptMLite m a->m a
runEthCryptMLite myPriv otherPubKey actions = do
 ------------------------------

  let m_originated=True
      add::B.ByteString->B.ByteString->B.ByteString
      add acc val | B.length acc ==32 && B.length val == 32 = SHA3.hash 256 $ val `B.append` acc
      add _ _ = error "add called with ByteString of length not 32"

      otherNonce=B.pack $ word256ToBytes $ ackNonce ackMsg

      SharedKey shared' = getShared theCurve myPriv (ackEphemeralPubKey ackMsg)
      shared = B.pack $ intToBytes shared'

      frameDecKey = myNonce `add` otherNonce `add` shared `add` shared
      macEncKey = frameDecKey `add` shared

      ingressCipher = if m_originated then handshakeInitBytes else handshakeReplyBytes
      egressCipher = if m_originated then handshakeReplyBytes else handshakeInitBytes


  let cState =
        EthCryptState {
          encryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
          decryptState = AES.AESCTRState (initAES frameDecKey) (aesIV_ $ B.replicate 16 0) 0,
          egressMAC=SHA3.update (SHA3.init 256) $
                    (macEncKey `bXor` otherNonce) `B.append` egressCipher,
          egressKey=macEncKey,
          ingressMAC=SHA3.update (SHA3.init 256) $ 
                     (macEncKey `bXor` myNonce) `B.append` ingressCipher,
          ingressKey=macEncKey
          }

  (ret, _) <- flip runStateT cState actions

  return ret
-}
