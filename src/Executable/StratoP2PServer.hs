{-# LANGUAGE OverloadedStrings #-}

module Executable.StratoP2PServer (
  stratoP2PServer
  ) where

import Control.Concurrent
import Control.Monad.Logger
import Control.Monad.Trans.Resource
import Control.Monad.IO.Class
import qualified Data.Text as T

import Blockchain.EthConf
import Blockchain.ServOptions
import Blockchain.TCPServer

import API.StratoP2PServer

privateKey :: Integer
privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

stratoP2PServer:: LoggingT IO ()
stratoP2PServer = do
  logInfoN "Starting P2P (Server) HTTP Server"

  _ <- liftIO . forkIO $ stratoP2PServerAPIMain

  logInfoN $ T.pack $ "connect address: " ++ (flags_address)
  logInfoN $ T.pack $ "connect port:    " ++ (show flags_port)
  logInfoN $ T.pack $ "listen port:     " ++ (show flags_listen)

  let myPriv = privateKey
--      myPublic = calculatePublic theCurve (fromIntegral myPriv)
  
  _ <- runResourceT $ do
          runEthServer connStr' myPriv flags_listen
  return ()
