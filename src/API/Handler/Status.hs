{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE TypeOperators   #-}

module API.Handler.Status where

import Servant
    
import API.Model.Status
import API.Route.Status

statusGet :: Server StatusAPI
statusGet = return $ Status "All good!" "now"

