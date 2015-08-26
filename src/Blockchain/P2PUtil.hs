
module Blockchain.P2PUtil (
  theCurve,
  hPubKeyToPubKey,
  ecdsaSign,
  intToBytes,
  sockAddrToIP
  ) where

import           Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Network
import qualified Data.Conduit.Binary as CBN
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as NB
import           Network.Haskoin.Crypto 

import           Data.Conduit.TMChan
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Control.Monad
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
--import           System.Entropy

import           Crypto.PubKey.ECC.DH
import           Crypto.Types.PubKey.ECC
import           Crypto.Random
import qualified Crypto.Hash.SHA3 as SHA3

import           Crypto.Cipher.AES

import           Data.Bits
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import qualified Data.ByteString.Char8 as BC
import           Data.List.Split
                                     
theCurve :: Curve
theCurve = getCurveByName SEC_p256k1

hPubKeyToPubKey::H.PubKey->Point
hPubKeyToPubKey (H.PubKeyU _) = error "PubKeyU not supported in hPubKeyToPUbKey yet"
hPubKeyToPubKey (H.PubKey hPoint) = Point (fromIntegral x) (fromIntegral y)
  where
     x = fromMaybe (error "getX failed in prvKey2Address") $ H.getX hPoint
     y = fromMaybe (error "getY failed in prvKey2Address") $ H.getY hPoint

ecdsaSign::H.PrvKey->Word256->H.SecretT IO ExtendedSignature
ecdsaSign prvKey' theHash = do
    extSignMsg theHash prvKey'    

intToBytes::Integer->[Word8]
intToBytes x = map (fromIntegral . (x `shiftR`)) [256-8, 256-16..0]

sockAddrToIP :: S.SockAddr -> String
sockAddrToIP (S.SockAddrInet6 _ _ host _) = show host
sockAddrToIP (S.SockAddrUnix str) = str
sockAddrToIP addr' = takeWhile (\t -> t /= ':') (show addr')


  
