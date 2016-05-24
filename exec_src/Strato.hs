{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

import Control.Monad.Logger
import Control.Concurrent
import HFlags

import Blockchain.IOptions ()
import Blockchain.Mining.Options ()
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
      _ <- forkIO $ flip runLoggingT (printToFile "logs/etherum-discovery") $ ethereumDiscovery flags_listen args
      return ()
    else putStrLn "UDP server disabled"

  _ <- forkIO $ flip runLoggingT (printToFile "logs/strato-quary") $ stratoQuary
  _ <- forkIO $ flip runLoggingT (printToFile "logs/strato-adit") $ stratoAdit
  _ <- forkIO $ flip runLoggingT (printToFile "logs/etherum-vm") $ ethereumVM
  _ <- forkIO $ flip runLoggingT (printToFile "logs/strato-index") $ stratoIndex
  _ <- forkIO $ flip runLoggingT (printToFile "logs/strato-p2p-client") $ stratoP2PClient args
  flip runLoggingT (printToFile "logs/strato-p2p-server") stratoP2PServer
