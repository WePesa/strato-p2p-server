{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module API.Route.Status where

import API.Model.Status
import Servant

type StatusAPI =  "strato-p2p-server" :> "v1.1" :> "status" :> Get '[JSON] Status
