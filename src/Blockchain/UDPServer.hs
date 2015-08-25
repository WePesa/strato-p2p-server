
module Blockchain.UDPServer (
      connectMe,
      udpHandshakeServer,
      portS
     ) where

import qualified Network.Socket as S
import qualified Network.Socket.ByteString as NB
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Control.Monad
import           Control.Concurrent.Async 
import           Control.Exception
import qualified Data.Binary as BN


import           Data.Time.Clock.POSIX
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16

import           Blockchain.UDP
import           Blockchain.SHA
import           Blockchain.Data.RLP
import           Blockchain.ExtWord
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.DBM

import qualified Data.ByteString.Lazy as BL

import           Data.Maybe
import           Control.Monad.State
import           Prelude 
import           Data.Word
import qualified Network.Haskoin.Internals as H
import qualified Crypto.Hash.SHA3 as SHA3

import           Blockchain.P2PUtil



portS :: String
portS = "30305"

connectMe :: IO S.Socket
connectMe = do
  (serveraddr:_) <- S.getAddrInfo
                      (Just (S.defaultHints {S.addrFlags = [S.AI_PASSIVE]}))
                      Nothing (Just portS)
  sock <- S.socket (S.addrFamily serveraddr) S.Datagram S.defaultProtocol
  S.bindSocket sock (S.addrAddress serveraddr) >> return sock

udpHandshakeServer :: H.PrvKey -> TContext -> S.Socket  -> IO ()
udpHandshakeServer prv cxt conn = do
   (msg,addr) <- NB.recvFrom conn 1280

   putStrLn $ "from addr: " ++ show addr
   let ip = sockAddrToIP addr


   putStrLn $ "connection from ip: " ++ ip
   
   let r = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 32 $ msg
       s = bytesToWord256 $ B.unpack $ B.take 32 $ B.drop 64 msg
       v = head . B.unpack $ B.take 1 $ B.drop 96 msg

       theType = head . B.unpack $ B.take 1$ B.drop 97 msg
       theRest = B.unpack $ B.drop 98 msg
       (rlp, _) = rlpSplit theRest

       signature = ExtendedSignature (H.Signature (fromIntegral r) (fromIntegral s)) yIsOdd
                         
       SHA messageHash = hash $ B.pack $ [theType] ++ B.unpack (rlpSerialize rlp)
       otherPubkey = fromMaybe (error "malformed signature in udpHandshakeServer") $ getPubKeyFromSignature signature messageHash  
       yIsOdd = v == 1

   putStrLn $ "other pubkey: " ++ (show $ B16.encode $ B.pack $ pointToBytes $ hPubKeyToPubKey $ otherPubkey)
   putStrLn $ "other pubkey as point: " ++ (show $ hPubKeyToPubKey $ otherPubkey)
   
   time <-  round `fmap` getPOSIXTime

   let (theType, theRLP) = ndPacketToRLP $
                                (Pong (Endpoint "127.0.0.1" 30303 30303) 4 (time+50):: NodeDiscoveryPacket)
                                
       theData = B.unpack $ rlpSerialize theRLP
       SHA theMsgHash = hash $ B.pack $ (theType:theData)

   ExtendedSignature signature yIsOdd <- liftIO $ H.withSource H.devURandom $ ecdsaSign  prv theMsgHash

   let v = if yIsOdd then 1 else 0 
       r = H.sigR signature
       s = H.sigS signature
       theSignature = word256ToBytes (fromIntegral r) ++ word256ToBytes (fromIntegral s) ++ [v]
       theHash = B.unpack $ SHA3.hash 256 $ B.pack $ theSignature ++ [theType] ++ theData

   cxt' <- readTVarIO cxt
   let prevPeers = peers cxt'
       
   atomically $ writeTVar cxt (cxt'{peers=(Map.insert ip (hPubKeyToPubKey otherPubkey) prevPeers)} )

   putStrLn $ "about to send PONG"
   _ <- NB.sendTo conn ( B.pack $ theHash ++ theSignature ++ [theType] ++ theData) addr
   
   udpHandshakeServer prv cxt conn
   return () 
