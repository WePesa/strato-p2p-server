{-# LANGUAGE OverloadedStrings, FlexibleContexts, TypeFamilies #-}

module Blockchain.BlockNotify (
  createBlockTrigger,
  blockNotificationSource
  ) where

import Conduit
import Control.Monad
import Control.Monad.Logger
import Control.Monad.Trans.Resource
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.Text as T
import qualified Database.Persist as SQL
import qualified Database.Persist.Sql as SQL
import qualified Database.PostgreSQL.Simple as PS
import Database.PostgreSQL.Simple.Notification

import Blockchain.Data.BlockDB
import Blockchain.Data.DataDefs
import Blockchain.Data.NewBlk
import Blockchain.DB.SQLDB
import Blockchain.ExtWord
import Blockchain.SHA

createBlockTrigger::(MonadIO m, MonadLogger m)=>
                    m ()
createBlockTrigger = do
  conn <- liftIO $ PS.connect PS.defaultConnectInfo {   --TODO add to config
    PS.connectPassword = "api",
    PS.connectDatabase = "eth"
    }

  res2 <- liftIO $ PS.execute_ conn "DROP TRIGGER IF EXISTS p2p_block_notify ON new_blk;\n\
\CREATE OR REPLACE FUNCTION p2p_block_notify() RETURNS TRIGGER AS $p2p_block_notify$ \n\ 
    \ BEGIN \n\
    \     PERFORM pg_notify('p2p_new_block', NEW.hash::text ); \n\
    \     RETURN NULL; \n\
    \ END; \n\
\ $p2p_block_notify$ LANGUAGE plpgsql; \n\
\ CREATE TRIGGER p2p_block_notify AFTER INSERT OR UPDATE ON new_blk FOR EACH ROW EXECUTE PROCEDURE p2p_block_notify();"

  liftIO $ PS.close conn

  logInfoN $ T.pack $ "created trigger with result: " ++ show res2

byteStringToSHA::B.ByteString->SHA
byteStringToSHA s =
  case B16.decode s of
   (s', "") -> SHA $ bytesToWord256 $ B.unpack s'
   _ -> error "byteString in wrong format"

blockNotificationSource::(MonadIO m, MonadBaseControl IO m, MonadResource m, MonadLogger m)=>
                         SQLDB->Source m (Block, Integer)
--notificationSource::(MonadBaseControl IO m)=>SQLDB->PS.Connection->Source m Block
--blockNotificationSource::SQLDB->Source (ResourceT IO) (Block, Integer)
blockNotificationSource pool = do
  conn <- liftIO $ PS.connect PS.defaultConnectInfo {   -- bandaid, should eventually be added to monad class
    PS.connectPassword = "api",
    PS.connectDatabase = "eth"
    }
            
  _ <- register $ PS.close conn

  forever $ do
    _ <- liftIO $ PS.execute_ conn "LISTEN p2p_new_block;"
    logInfoN "about to listen for new block notifications"
    rowId <- liftIO $ fmap (byteStringToSHA . notificationData) $ getNotification conn
    logInfoN $ T.pack $ "######## new block has arrived: rowid=" ++ show rowId
    maybeBlock <- lift $ getBlockFromKey pool rowId
    case maybeBlock of
     Nothing -> error "wow, item was removed in notificationSource before I could get it....  This didn't seem like a likely occurence when I was programming, you should probably deal with this possibility now"
     Just (b, difficulty) -> yield (newBlkToBlock b, difficulty)

getBlockFromKey::(MonadIO m, MonadBaseControl IO m)=>SQLDB->SHA->m (Maybe (NewBlk, Integer))
getBlockFromKey pool hash' = do
    --pool <- getSQLDB      
    maybeNewBlk <- SQL.runSqlPool (SQL.getBy $ TheHash hash') pool
    case maybeNewBlk of
     Nothing -> return Nothing
     Just b -> do
       return $ Just (SQL.entityVal b, 0)
{-       maybeBlock <-
         flip SQL.runSqlPool pool $ do
           SQL.get (blockDataRefBlockId bd)
       case maybeBlock of
        Just b -> return $ Just (b, blockDataRefTotalDifficulty bd, blockDataRefHash bd)
        Nothing -> error "block missing blockData in call to getBlockFromKey" -}
