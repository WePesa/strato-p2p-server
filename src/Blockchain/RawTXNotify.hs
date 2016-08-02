{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.RawTXNotify (
  createTXTrigger,
  txNotificationSource
  ) where

import Conduit
import Control.Monad
import Control.Monad.Logger
import Control.Monad.Trans.Resource
import qualified Data.ByteString.Char8 as BC
import Data.String
import qualified Data.Text as T
import qualified Database.Persist as SQL
import qualified Database.Persist.Postgresql as SQL
--import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import Database.PostgreSQL.Simple.Notification

import Blockchain.Data.RawTransaction
import Blockchain.DB.SQLDB
import Blockchain.EthConf

createTXTrigger::(MonadIO m, MonadLogger m)=>
                 String->m ()
createTXTrigger name = do
  conn <- liftIO $ PS.connectPostgreSQL connStr
  res2 <- liftIO $ PS.execute_ conn $ fromString $ "DROP TRIGGER IF EXISTS " ++ name ++ " ON raw_transaction;\n\
\CREATE OR REPLACE FUNCTION " ++ name ++ "() RETURNS TRIGGER AS $" ++ name ++ "$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('new_transaction', NEW.id::text ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $" ++ name ++ "$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER " ++ name ++ " AFTER INSERT OR DELETE ON raw_transaction FOR EACH ROW EXECUTE PROCEDURE " ++ name ++ "();"

  liftIO $ PS.close conn

  logInfoN $ T.pack $ "created trigger with result: " ++ (show res2)


txNotificationSource::(MonadIO m, MonadBaseControl IO m, MonadResource m, MonadLogger m)=>
                      String->Source m RawTransaction
txNotificationSource name = do
  conn <- liftIO $ PS.connectPostgreSQL connStr
  _ <- register $ PS.close conn

  pool <- liftIO $ runNoLoggingT $ SQL.createPostgresqlPool connStr' 20
  lift $ createTXTrigger name

  forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    logInfoN "about to listen for raw transaction notifications"
    rowId <- liftIO $ fmap (SQL.toSqlKey . read . BC.unpack . notificationData) $ getNotification conn
    logInfoN $ T.pack $ "########### raw transaction has been added: rowId=" ++ show rowId
    maybeTx <- lift $ getTransaction pool rowId
    case maybeTx of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just tx -> yield tx

getTransaction::(MonadIO m, MonadBaseControl IO m, MonadResource m)=>
                SQLDB->SQL.Key RawTransaction->m (Maybe RawTransaction)
getTransaction pool row = do
    --pool <- getSQLDB      
    SQL.runSqlPool (SQL.get row) pool
