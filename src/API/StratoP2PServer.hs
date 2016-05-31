{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module API.StratoP2PServer (
   stratoP2PServerAPIMain
  ) where

import API.Route.Status
import API.Handler.Status

import Servant
import Network.Wai
import Network.Wai.Handler.Warp

app :: Application
app = serve statusAPI statusGet
 
statusAPI :: Proxy StatusAPI
statusAPI = Proxy

stratoP2PServerAPIMain :: IO ()
stratoP2PServerAPIMain = run 8085 app
