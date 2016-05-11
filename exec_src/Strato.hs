{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

import Control.Monad.Logger
import Control.Concurrent
import HFlags

import Blockchain.Output
import Blockchain.Options ()
--import Blockchain.Quarry.Flags ()
import Blockchain.ServOptions
import Executable.EthereumDiscovery
import Executable.StratoAdit
import Executable.StratoP2PClient
import Executable.StratoP2PServer
import Executable.StratoQuary




main :: IO ()
main = do
  args <- $initHFlags "Strato Peer Server"

  if flags_runUDPServer 
    then do
      putStrLn "Starting UDP server"
      forkIO $ flip runLoggingT printLogMsg $ ethereumDiscovery args
      return ()
    else putStrLn "UDP server disabled"

  forkIO $ flip runLoggingT printLogMsg $ stratoQuary
  forkIO $ flip runLoggingT printLogMsg $ stratoAdit
  forkIO $ flip runLoggingT printLogMsg $ stratoP2PClient args
  flip runLoggingT printLogMsg stratoP2PServer
