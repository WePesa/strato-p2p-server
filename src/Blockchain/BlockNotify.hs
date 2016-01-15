{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.BlockNotify (
  createTrigger,
  blockNotificationSource
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Database.Persist as SQL
import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import           Conduit
import           Data.List.Split
import           Control.Monad

import Blockchain.Data.BlockDB
import Blockchain.DB.SQLDB

createTrigger :: PS.Connection -> IO ()
createTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS p2p_block_notify ON block;\n\
\CREATE OR REPLACE FUNCTION tx_notify() RETURNS TRIGGER AS $p2p_block_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('p2p_new_block', NEW.id ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $p2p_block_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER p2p_block_notify AFTER INSERT OR DELETE ON block FOR EACH ROW EXECUTE PROCEDURE tx_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


--notificationSource::(MonadIO m)=>SQLDB->PS.Connection->Source m Block
blockNotificationSource::SQLDB->PS.Connection->Source IO Block
blockNotificationSource pool conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN p2p_new_block;"
    liftIO $ putStrLn $ "about to listen for notification"
    rowId <- liftIO $ (fmap (read . BC.unpack . notificationData) $ getNotification conn::IO (SQL.Key Block))
    maybeTx <- lift $ getBlockFromKey pool rowId
    case maybeTx of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just tx -> yield tx

getBlockFromKey::SQLDB->SQL.Key Block->IO (Maybe Block)
getBlockFromKey pool row = do
    --pool <- getSQLDB      
    SQL.runSqlPool (SQL.get row) pool
