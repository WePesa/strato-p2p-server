{-# LANGUAGE OverloadedStrings, RecordWildCards, LambdaCase #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE ScopedTypeVariables        #-}

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
import           Control.Concurrent.Async.Lifted 
import           Control.Exception
import qualified Data.Binary as BN


import           Data.Time.Clock.POSIX
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16

import           Blockchain.UDP
import           Blockchain.SHA
import           Blockchain.Data.RLP
import           Blockchain.Data.DataDefs
import           Blockchain.ExtWord
import           Blockchain.ExtendedECDSA
import           Blockchain.CommunicationConduit
import           Blockchain.ContextLite
import qualified Blockchain.AESCTR as AES
import           Blockchain.Handshake
import           Blockchain.DBM

import qualified Data.ByteString.Lazy as BL
import qualified Database.Persist.Postgresql as SQL

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
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification

import           Data.Bits
import qualified Data.ByteString.Char8 as BC
import           Blockchain.UDP
import           System.Environment
import           HFlags

import           Blockchain.PeerUrls
import           Blockchain.TCPServer
import           Blockchain.TCPClient
import           Blockchain.UDPServer
import           Blockchain.P2PUtil
import           Blockchain.TriggerNotify
import           Control.Applicative

connStr :: BC.ByteString
connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

privateKey :: Integer
privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

defineFlag "a:address" ("127.0.0.1" :: String) "Connect to server at address"
defineFlag "p:port" (30303 :: Int) "Connect on port"
defineFlag "l:listen" (30305 :: Int) "Listen on port"
defineFlag "name" ("Indiana Jones" :: String) "Who to greet."

main :: IO ()
main = do
  _ <- $initHFlags "Ethereum p2p"
  
  putStrLn $ "connect address: " ++ (flags_address)
  putStrLn $ "connect port:    " ++ (show flags_port)
  putStrLn $ "listen port:     " ++ (show flags_listen)

  let myPriv = privateKey
      myPublic = calculatePublic theCurve (fromIntegral myPriv)
  
  _ <- runResourceT $ do
          async $ (runEthClient connStr myPriv flags_address flags_port)
          (runEthServer connStr myPriv flags_listen)

  return ()
  
