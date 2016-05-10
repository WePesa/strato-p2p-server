{-# LANGUAGE TemplateHaskell #-}

import Control.Monad.Logger
import HFlags

import Blockchain.Output
import Blockchain.ServOptions
import Executable.StratoP2PServer

main :: IO ()
main = do
  _ <- $initHFlags "Strato Peer Server"
  flip runLoggingT printLogMsg stratoP2PServer
