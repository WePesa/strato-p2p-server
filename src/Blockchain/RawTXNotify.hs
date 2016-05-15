{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.RawTXNotify (
  createTXTrigger,
  txNotificationSource
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Database.Persist as SQL
import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import           Conduit
import           Control.Monad
import           Control.Monad.Trans.Resource
import System.Log.Logger

import Blockchain.Data.RawTransaction
import Blockchain.DB.SQLDB
import Blockchain.EthConf

createTXTrigger::IO ()
createTXTrigger = do
  conn <- PS.connectPostgreSQL connStr
  res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS tx_notify ON raw_transaction;\n\
\CREATE OR REPLACE FUNCTION tx_notify() RETURNS TRIGGER AS $tx_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('new_transaction', NEW.id::text ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $tx_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER tx_notify AFTER INSERT OR DELETE ON raw_transaction FOR EACH ROW EXECUTE PROCEDURE tx_notify();"

  PS.close conn

  errorM "txNotification" $ "created trigger with result: " ++ (show res2)


--notificationSource::(MonadIO m)=>SQLDB->PS.Connection->Source m RawTransaction
txNotificationSource::(MonadIO m, MonadBaseControl IO m, MonadResource m)=>
                      SQLDB->Source m RawTransaction
txNotificationSource pool = do
  conn <- liftIO $ PS.connectPostgreSQL connStr
  _ <- register $ PS.close conn

  forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    liftIO $ errorM "txNotification" $ "about to listen for raw transaction notifications"
    rowId <- liftIO $ fmap (SQL.toSqlKey . read . BC.unpack . notificationData) $ getNotification conn
    liftIO $ errorM "txNotification" $ "########### raw transaction has been added: rowId=" ++ show rowId
    maybeTx <- lift $ getTransaction pool rowId
    case maybeTx of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just tx -> yield tx

getTransaction::(MonadIO m, MonadBaseControl IO m, MonadResource m)=>
                SQLDB->SQL.Key RawTransaction->m (Maybe RawTransaction)
getTransaction pool row = do
    --pool <- getSQLDB      
    SQL.runSqlPool (SQL.get row) pool
