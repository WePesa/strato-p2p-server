{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.BlockNotify (
  createBlockTrigger,
  blockNotificationSource
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Database.Persist as SQL
import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import           Database.PostgreSQL.Simple.Notification
import           Conduit
import           Control.Monad

import Blockchain.Data.BlockDB
import Blockchain.Data.DataDefs
import Blockchain.DB.SQLDB
import Blockchain.SHA

createBlockTrigger :: PS.Connection -> IO ()
createBlockTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS p2p_block_notify ON block_data_ref;\n\
\CREATE OR REPLACE FUNCTION p2p_block_notify() RETURNS TRIGGER AS $p2p_block_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('p2p_new_block', NEW.id::text ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $p2p_block_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER p2p_block_notify AFTER INSERT OR UPDATE ON block_data_ref FOR EACH ROW EXECUTE PROCEDURE p2p_block_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


--notificationSource::(MonadIO m)=>SQLDB->PS.Connection->Source m Block
blockNotificationSource::SQLDB->PS.Connection->Source IO (Block, Integer)
blockNotificationSource pool conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN p2p_new_block;"
    liftIO $ putStrLn $ "about to listen for new block notifications"
    rowId <- liftIO $ fmap (SQL.toSqlKey . read . BC.unpack . notificationData) $ getNotification conn
    liftIO $ putStrLn $ "######## new block has arrived: rowid=" ++ show rowId
    maybeBlock <- lift $ getBlockFromKey pool rowId
    case maybeBlock of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just (b, difficulty, hash') -> do
       when (hash' /= SHA 1) $ yield (b, difficulty)

getBlockFromKey::SQLDB->SQL.Key BlockDataRef->IO (Maybe (Block, Integer, SHA))
getBlockFromKey pool row = do
    --pool <- getSQLDB      
    maybeBlockDataRef <- SQL.runSqlPool (SQL.get row) pool
    case maybeBlockDataRef of
     Nothing -> return Nothing
     Just bd -> do
       maybeBlock <-
         flip SQL.runSqlPool pool $ do
           SQL.get (blockDataRefBlockId bd)
       case maybeBlock of
        Just b -> return $ Just (b, blockDataRefTotalDifficulty bd, blockDataRefHash bd)
        Nothing -> error "block missing blockData in call to getBlockFromKey"
