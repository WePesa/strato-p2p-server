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
import           Control.Monad
import           Control.Concurrent.Async.Lifted 

import           Prelude 

import qualified Data.ByteString.Char8 as BC
import           HFlags

import           Blockchain.TCPServer
import           Blockchain.TCPClient

import System.IO

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
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering

  _ <- $initHFlags "Ethereum p2p"
  
  putStrLn $ "connect address: " ++ (flags_address)
  putStrLn $ "connect port:    " ++ (show flags_port)
  putStrLn $ "listen port:     " ++ (show flags_listen)

  let myPriv = privateKey
--      myPublic = calculatePublic theCurve (fromIntegral myPriv)
  
  _ <- runResourceT $ do
          _ <- async $ (runEthClient connStr myPriv flags_address flags_port)
          (runEthServer connStr myPriv flags_listen) 
  return ()
  
