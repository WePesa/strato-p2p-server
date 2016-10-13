{-# LANGUAGE OverloadedStrings #-}

module Executable.StratoP2PServer (
  stratoP2PServer
  ) where

import Control.Monad.Logger
import Control.Monad.Trans.Resource
import qualified Data.Text as T

import Blockchain.EthConf
import Blockchain.ServOptions
import Blockchain.TCPServer

stratoP2PServer:: LoggingT IO ()
stratoP2PServer = do
  logInfoN $ T.pack $ "connect address: " ++ (flags_address)
  logInfoN $ T.pack $ "listen port:     " ++ (show flags_listen)

  let PrivKey myPriv = privKey ethConf

  _ <- runResourceT $ do
          runEthServer connStr' myPriv flags_listen
  return ()
