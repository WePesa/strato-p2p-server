{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

import Control.Monad.Logger
import Control.Concurrent
import HFlags

-- import Blockchain.IOptions
-- import Blockchain.Mining.Options
import Blockchain.Output
import Blockchain.Options ()
import Blockchain.Quarry.Flags ()
import Blockchain.ServOptions
import Blockchain.VMOptions ()

import Executable.EthereumDiscovery
import Executable.EthereumVM
import Executable.StratoAdit
import Executable.StratoIndex
import Executable.StratoP2PClient
import Executable.StratoP2PServer
import Executable.StratoQuary




main :: IO ()
main = do
  args <- $initHFlags "Strato Peer Server"

  if flags_runUDPServer 
    then do
      putStrLn "Starting UDP server"
      _ <- forkIO $ flip runLoggingT printLogMsg $ ethereumDiscovery flags_listen args
      return ()
    else putStrLn "UDP server disabled"

  _ <- forkIO $ flip runLoggingT printLogMsg $ stratoQuary
  _ <- forkIO $ flip runLoggingT printLogMsg $ stratoAdit
  _ <- forkIO $ flip runLoggingT printLogMsg $ ethereumVM
  _ <- forkIO $ flip runLoggingT printLogMsg $ stratoIndex
  _ <- forkIO $ flip runLoggingT printLogMsg $ stratoP2PClient args
  flip runLoggingT printLogMsg stratoP2PServer
