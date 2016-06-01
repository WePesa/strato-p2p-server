{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module API.StratoP2PServerClient (
   p2pServerStatusRoute,
   P2PServerStatus(..)
  ) where

import API.StratoP2PServer
import Control.Monad.Trans.Either

import Servant.Client
 
p2pServerStatusRoute :: BaseUrl -> EitherT ServantError IO P2PServerStatus
p2pServerStatusRoute = client statusAPI
