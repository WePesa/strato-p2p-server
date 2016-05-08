{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

import Conduit
import Control.Monad
import Control.Monad.Logger
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import HFlags
import System.IO

import Blockchain.ServOptions
import Blockchain.TCPServer
import Blockchain.Output

connStr :: BC.ByteString
connStr = "host=localhost dbname=eth user=postgres password=api port=5432"

privateKey :: Integer
privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

lMain :: LoggingT IO ()
lMain = do
  logInfoN $ T.pack $ "connect address: " ++ (flags_address)
  logInfoN $ T.pack $ "connect port:    " ++ (show flags_port)
  logInfoN $ T.pack $ "listen port:     " ++ (show flags_listen)

  let myPriv = privateKey
--      myPublic = calculatePublic theCurve (fromIntegral myPriv)
  
  _ <- runResourceT $ do
          runEthServer connStr myPriv flags_listen
  return ()
  
main :: IO ()
main = do
  _ <- $initHFlags "Strato Peer Server"
  flip runLoggingT printLogMsg lMain
