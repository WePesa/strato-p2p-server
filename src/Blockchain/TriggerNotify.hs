{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.TriggerNotify (
  createTrigger,
  notificationSource
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Database.Persist as SQL
import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import           Conduit
import           Data.List.Split
import           Control.Monad

import Blockchain.Data.RawTransaction
import Blockchain.DB.SQLDB

createTrigger :: PS.Connection -> IO ()
createTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS tx_notify ON raw_transaction;\n\
\CREATE OR REPLACE FUNCTION tx_notify() RETURNS TRIGGER AS $tx_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('new_transaction', NEW.id ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $tx_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER tx_notify AFTER INSERT OR DELETE ON raw_transaction FOR EACH ROW EXECUTE PROCEDURE tx_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


--notificationSource::(MonadIO m)=>SQLDB->PS.Connection->Source m RawTransaction
notificationSource::SQLDB->PS.Connection->Source IO RawTransaction
notificationSource pool conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    liftIO $ putStrLn $ "about to listen for notification"
    rowId <- liftIO $ (fmap (read . BC.unpack . notificationData) $ getNotification conn::IO (SQL.Key RawTransaction))
    maybeTx <- lift $ getTransaction pool rowId
    case maybeTx of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just tx -> yield tx

getTransaction::SQLDB->SQL.Key RawTransaction->IO (Maybe RawTransaction)
getTransaction pool row = do
    --pool <- getSQLDB      
    SQL.runSqlPool (SQL.get row) pool
