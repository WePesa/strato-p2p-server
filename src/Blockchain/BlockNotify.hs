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
import           Data.List.Split
import           Control.Monad

import Blockchain.Data.BlockDB
import Blockchain.Data.DataDefs
import Blockchain.DB.SQLDB

createBlockTrigger :: PS.Connection -> IO ()
createBlockTrigger conn = do
     res2 <- PS.execute_ conn "DROP TRIGGER IF EXISTS p2p_block_notify ON block;\n\
\CREATE OR REPLACE FUNCTION p2p_block_notify() RETURNS TRIGGER AS $p2p_block_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('p2p_new_block', NEW.id::Char ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $p2p_block_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER p2p_block_notify AFTER INSERT OR DELETE ON block FOR EACH ROW EXECUTE PROCEDURE p2p_block_notify();"

     putStrLn $ "created trigger with result: " ++ (show res2)


--notificationSource::(MonadIO m)=>SQLDB->PS.Connection->Source m Block
blockNotificationSource::SQLDB->PS.Connection->Source IO (Block, Integer)
blockNotificationSource pool conn = forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN p2p_new_block;"
    liftIO $ putStrLn $ "about to listen for new block notifications"
    rowId <- liftIO $ fmap (SQL.toSqlKey . read . BC.unpack . notificationData) $ getNotification conn
    liftIO $ putStrLn $ "######## new block has arrived"
    maybeTx <- lift $ getBlockFromKey pool rowId
    case maybeTx of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just (tx, difficulty) -> yield (tx, difficulty)

getBlockFromKey::SQLDB->SQL.Key Block->IO (Maybe (Block, Integer))
getBlockFromKey pool row = do
    --pool <- getSQLDB      
    maybeBlock <- SQL.runSqlPool (SQL.get row) pool
    case maybeBlock of
     Nothing -> return Nothing
     Just b -> do
       bdList <-
         flip SQL.runSqlPool pool $ do
           SQL.selectList [BlockDataRefHash SQL.==. blockHash b] []
       case bdList of
        [bd] -> return $ Just (b, blockDataRefTotalDifficulty $ SQL.entityVal bd)
        _ -> error "block missing blockData in call to getBlockFromKey"
