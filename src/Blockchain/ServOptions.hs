{-# LANGUAGE OverloadedStrings, RecordWildCards, LambdaCase #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Blockchain.ServOptions where

import           HFlags

defineFlag "a:address" ("127.0.0.1" :: String) "Connect to server at address"
defineFlag "p:port" (30303 :: Int) "Connect on port"
defineFlag "l:listen" (30303 :: Int) "Listen on port"
defineFlag "runUDPServer" True "Turn the UDP server on/off"
defineFlag "networkID" (1::Int) "Turn the UDP server on/off"
defineFlag "name" ("Indiana Jones" :: String) "Who to greet."

