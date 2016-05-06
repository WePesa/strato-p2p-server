{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Blockchain.CommunicationConduit (
  handleMsgConduit
  ) where

import Conduit
import Control.Monad.State
import Crypto.Types.PubKey.ECC

import Blockchain.Data.Wire
import Blockchain.Context
import Blockchain.BlockSynchronizerSql
import Blockchain.DB.DetailsDB hiding (getBestBlockHash)
import Blockchain.DB.SQLDB
import Blockchain.Event
import Blockchain.ServOptions

ethVersion :: Int
ethVersion = 61

awaitMsg::MonadIO m=>ConduitM Event Message m (Maybe Message)
awaitMsg = do
  x <- await
  case x of
   Just (MsgEvt msg) -> return $ Just msg
   Nothing -> return Nothing
   _ -> awaitMsg
      
handleMsgConduit::(MonadIO m, MonadResource m, HasSQLDB m, MonadState Context m)=>
                  Point->Conduit Event m Message
handleMsgConduit peerId = do

  helloMsg <- awaitMsg
 
  case helloMsg of
   Just Hello{} -> do
         let helloMsg' = Hello {
               version = 4,
               clientId = "Ethereum(G)/v0.6.4//linux/Haskell",
               capability = [ETH (fromIntegral  ethVersion ) ], -- , SHH shhVersion],
               port = 0, -- formerly 30303
               nodeId = peerId
               }
         yield helloMsg'
   Just _ -> error "Peer communicated before handshake was complete"
   Nothing -> error "peer hung up before handshake finished"

  statusMsg <- awaitMsg

  case statusMsg of
   Just Status{} -> do
           (h,d) <- lift getBestBlockHash
           genHash <- lift getGenesisBlockHash
           let statusMsg' = Status{
                              protocolVersion=fromIntegral ethVersion,
                              networkID=flags_networkID,
                              totalDifficulty= fromIntegral $ d,
                              latestHash=h,
                              genesisHash=genHash
                            }
           yield statusMsg'
   Just _ -> error "Peer communicated before handshake was complete"
   Nothing -> error "peer hung up before handshake finished"

  handleEvents

