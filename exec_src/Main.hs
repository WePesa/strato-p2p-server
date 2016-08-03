{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

import Control.Monad.Logger
import Control.Concurrent
import HFlags

import Blockchain.Output
import Blockchain.ServOptions
import Executable.EthereumDiscovery
import Executable.StratoP2PServer

main :: IO ()
main = do
  args <- $initHFlags "Strato Peer Server"

  if flags_runUDPServer 
    then do
      putStrLn "Starting UDP server"
      _ <- forkIO $ flip runLoggingT printLogMsg $ ethereumDiscovery args
      return ()
    else putStrLn "UDP server disabled"

  flip runLoggingT printLogMsg stratoP2PServer
