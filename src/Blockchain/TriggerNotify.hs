{-# LANGUAGE OverloadedStrings #-}

module Blockchain.TriggerNotify (
  createTrigger,
  notificationSource
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import           Conduit
import           Data.List.Split
import           Control.Monad

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

notificationSource::PS.Connection->Source IO Int
notificationSource conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN new_transaction;"
    liftIO $ putStrLn $ "about to listen for notification"
    rowId <- liftIO $ fmap (read . BC.unpack . notificationData) $ getNotification conn
    yield rowId

{-
getTransactionFromNotif :: Int -> (EthCryptMLite ContextMLite ) [RawTransaction]
getTransactionFromNotif row = do
    pool <- lift $ getSQLDB      
    SQL.runSqlPool (get row) pool
-}
