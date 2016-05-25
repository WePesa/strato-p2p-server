{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

import Control.Monad.IO.Class
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


run::FilePath->LoggingT IO ()->IO ()
run logPath f = forkIO (runNoFork logPath f) >> return ()

runNoFork::FilePath->LoggingT IO ()->IO ()
runNoFork logPath f = runLoggingT f $ printToFile logPath

main :: IO ()
main = do
  args <- $initHFlags "Strato Peer Server"

  if flags_runUDPServer 
    then do
      putStrLn "Starting UDP server"
      _ <- forkIO $ flip runLoggingT (printToFile "logs/etherum-discovery") $ ethereumDiscovery flags_listen args
      return ()
    else putStrLn "UDP server disabled"

  run "logs/strato-quarry" stratoQuary
  run "logs/strato-adit" stratoAdit
  run "logs/etherum-vm" ethereumVM
  run "logs/strato-index" stratoIndex
  run "logs/strato-p2p-client" $ stratoP2PClient args
  runNoFork "logs/strato-p2p-server" stratoP2PServer
