{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

import           Conduit
import           Control.Monad

import           Prelude 

import qualified Data.ByteString.Char8 as BC
import           HFlags

import           Blockchain.TCPServer
import           Blockchain.EthConf
import           Blockchain.ServOptions
    
import System.IO

privateKey :: Integer
privateKey =  0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

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
          runEthServer connStr myPriv flags_listen
  return ()
  
