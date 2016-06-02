
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module API.Model.Status where

import Data.Aeson.TH

data P2PServerStatus = P2PServerStatus {
    p2pServerMessage :: String,
    p2pServerTimestamp :: String   -- replace with UTCTime
} deriving (Eq, Show)

$(deriveJSON defaultOptions ''P2PServerStatus)
