{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Database.Redis.Connection where

import Control.Exception
import qualified Control.Monad.Catch as Catch
import Control.Monad.IO.Class(liftIO, MonadIO)
import Control.Monad(when)
import Control.Concurrent.MVar(MVar, newMVar)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as Char8
import Data.Functor(void)
import qualified Data.IntMap.Strict as IntMap
import Data.Pool
import Data.Typeable
import qualified Data.Time as Time
import Network.TLS (ClientParams)
import qualified Network.Socket as NS
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T

import qualified Database.Redis.ProtocolPipelining as PP
import Database.Redis.Core(Redis, Hooks, runRedisInternal, runRedisClusteredInternal, defaultHooks)
import Database.Redis.Protocol(Reply(..))
import Database.Redis.Cluster(ShardMap(..), Node, Shard(..))
import qualified Database.Redis.Cluster as Cluster
import qualified Database.Redis.ConnectionContext as CC
--import qualified Database.Redis.Cluster.Pipeline as ClusterPipeline
import Database.Redis.Commands
    ( ping
    , select
    , authOpts
    , defaultAuthOpts
    , AuthOpts(..)
    , clusterSlots
    , command
    , ClusterSlotsResponse(..)
    , ClusterSlotsResponseEntry(..)
    , ClusterSlotsNode(..))

--------------------------------------------------------------------------------
-- Connection
--

-- |A threadsafe pool of network connections to a Redis server. Use the
--  'connect' function to create one.
data Connection
    = NonClusteredConnection T.Text (Pool PP.Connection)
    | ClusteredConnection T.Text (MVar ShardMap) (Pool Cluster.Connection)

-- |Information for connnecting to a Redis server.
--
-- It is recommended to not use the 'ConnInfo' data constructor directly.
-- Instead use 'defaultConnectInfo' and update it with record syntax. For
-- example to connect to a password protected Redis server running on localhost
-- and listening to the default port:
--
-- @
-- myConnectInfo :: ConnectInfo
-- myConnectInfo = defaultConnectInfo {connectAuth = Just \"secret\"}
-- @
--
data ConnectInfo = ConnInfo
    { connectHost           :: NS.HostName
    -- ^ Ignored when 'connectPort' is a 'UnixSocket'
    , connectPort           :: CC.PortID
    , connectAuth           :: Maybe B.ByteString
    -- ^ When the server is protected by a password, set 'connectAuth' to 'Just'
    --   the password. Each connection will then authenticate by the 'auth'
    --   command.
    , connectUsername       :: Maybe B.ByteString
    -- ^ When ACL is used set 'connectUsername' as the user.
    , connectDatabase       :: Integer
    -- ^ Each connection will 'select' the database with the given index.
    , connectMaxConnections :: Int
    -- ^ Maximum number of connections to keep open. The smallest acceptable
    --   value is 1.
    , connectNumStripes     :: Maybe Int
    -- ^ Number of stripes in the connection pool.
    , connectMaxIdleTime    :: Time.NominalDiffTime
    -- ^ Amount of time for which an unused connection is kept open. The
    --   smallest acceptable value is 0.5 seconds. If the @timeout@ value in
    --   your redis.conf file is non-zero, it should be larger than
    --   'connectMaxIdleTime'.
    , connectTimeout        :: Maybe Time.NominalDiffTime
    -- ^ Optional timeout until connection to Redis gets
    --   established. 'ConnectTimeoutException' gets thrown if no socket
    --   get connected in this interval of time.
    , connectTLSParams      :: Maybe ClientParams
    -- ^ Optional TLS parameters. TLS will be enabled if this is provided.
    , connectHooks          :: Hooks
    -- ^ Connection hooks.
    , connectLabel          :: T.Text
    -- ^ Label of the connection pool for instrumentation.
    } deriving Show

data ConnectError = ConnectAuthError Reply
                  | ConnectSelectError Reply
    deriving (Eq, Show, Typeable)

instance Exception ConnectError

-- |Default information for connecting:
--
-- @
--  connectHost           = \"localhost\"
--  connectPort           = PortNumber 6379 -- Redis default port
--  connectAuth           = Nothing         -- No password
--  connectUsername       = Nothing         -- No user
--  connectDatabase       = 0               -- SELECT database 0
--  connectMaxConnections = 50              -- Up to 50 connections
--  connectNumStripes     = Nothing         -- A stripe per cabability
--  connectMaxIdleTime    = 30              -- Keep open for 30 seconds
--  connectTimeout        = Nothing         -- Don't add timeout logic
--  connectTLSParams      = Nothing         -- Do not use TLS
--  connectHooks          = defaultHooks    -- Do nothing
--  connectLabel          = ""              -- no label
-- @
--
defaultConnectInfo :: ConnectInfo
defaultConnectInfo = ConnInfo
    { connectHost           = "localhost"
    , connectPort           = CC.PortNumber 6379
    , connectAuth           = Nothing
    , connectUsername       = Nothing
    , connectDatabase       = 0
    , connectMaxConnections = 50
    , connectNumStripes     = Nothing
    , connectMaxIdleTime    = 30
    , connectTimeout        = Nothing
    , connectTLSParams      = Nothing
    , connectHooks          = defaultHooks
    , connectLabel          = ""
    }

createConnection :: ConnectInfo -> IO PP.Connection
createConnection ConnInfo{..} = do
    let timeoutOptUs =
          round . (1000000 *) <$> connectTimeout
    conn <- PP.connectWithHooks connectHost connectPort timeoutOptUs connectHooks
    conn' <- case connectTLSParams of
               Nothing -> return conn
               Just tlsParams -> PP.enableTLS tlsParams conn
    PP.beginReceiving conn'

    runRedisInternal conn' $ do
        -- AUTH
        case connectAuth of
            Nothing   -> return ()
            Just pass -> do
              resp <- authOpts pass defaultAuthOpts{ authOptsUsername = connectUsername}
              case resp of
                Left r -> liftIO $ throwIO $ ConnectAuthError r
                _      -> return ()
        -- SELECT
        when (connectDatabase /= 0) $ do
          resp <- select connectDatabase
          case resp of
              Left r -> liftIO $ throwIO $ ConnectSelectError r
              _      -> return ()
    return conn'

-- |Constructs a 'Connection' pool to a Redis server designated by the
--  given 'ConnectInfo'. The first connection is not actually established
--  until the first call to the server.
connect :: ConnectInfo -> IO Connection
connect cInfo@ConnInfo{..} = NonClusteredConnection connectLabel <$>
    newPool (setNumStripes connectNumStripes $ defaultPoolConfig (createConnection cInfo) PP.disconnect (realToFrac connectMaxIdleTime) connectMaxConnections)

-- |Constructs a 'Connection' pool to a Redis server designated by the
--  given 'ConnectInfo', then tests if the server is actually there.
--  Throws an exception if the connection to the Redis server can't be
--  established.
checkedConnect :: ConnectInfo -> IO Connection
checkedConnect connInfo = do
    conn <- connect connInfo
    runRedis conn $ void ping
    return conn

-- |Destroy all idle resources in the pool.
disconnect :: Connection -> IO ()
disconnect (NonClusteredConnection _ pool) = destroyAllResources pool
disconnect (ClusteredConnection _ _ pool) = destroyAllResources pool

-- | Memory bracket around 'connect' and 'disconnect'.
withConnect :: (Catch.MonadMask m, MonadIO m) => ConnectInfo -> (Connection -> m c) -> m c
withConnect connInfo = Catch.bracket (liftIO $ connect connInfo) (liftIO . disconnect)

-- | Memory bracket around 'checkedConnect' and 'disconnect'
withCheckedConnect :: ConnectInfo -> (Connection -> IO c) -> IO c
withCheckedConnect connInfo = bracket (checkedConnect connInfo) disconnect

-- |Interact with a Redis datastore specified by the given 'Connection'.
--
--  Each call of 'runRedis' takes a network connection from the 'Connection'
--  pool and runs the given 'Redis' action. Calls to 'runRedis' may thus block
--  while all connections from the pool are in use.
runRedis :: Connection -> Redis a -> IO a
runRedis (NonClusteredConnection _ pool) redis =
  withResource pool $ \conn -> runRedisInternal conn redis
runRedis (ClusteredConnection _ _ pool) redis =
    withResource pool $ \conn -> runRedisClusteredInternal conn (refreshShardMap conn) redis

newtype ClusterConnectError = ClusterConnectError Reply
    deriving (Eq, Show, Typeable)

instance Exception ClusterConnectError

-- |Constructs a 'ShardMap' of connections to clustered nodes. The argument is
-- a 'ConnectInfo' for any node in the cluster
--
-- Some Redis commands are currently not supported in cluster mode
-- - CONFIG, AUTH
-- - SCAN
-- - MOVE, SELECT
-- - PUBLISH, SUBSCRIBE, PSUBSCRIBE, UNSUBSCRIBE, PUNSUBSCRIBE, RESET
connectCluster :: ConnectInfo -> IO Connection
connectCluster bootstrapConnInfo = do
    conn <- createConnection bootstrapConnInfo
    slotsResponse <- runRedisInternal conn clusterSlots
    shardMapVar <- case slotsResponse of
        Left e -> throwIO $ ClusterConnectError e
        Right slots -> do
            shardMap <- shardMapFromClusterSlotsResponse slots
            newMVar shardMap
    commandInfos <- runRedisInternal conn command
    case commandInfos of
        Left e -> throwIO $ ClusterConnectError e
        Right infos -> do
            pool <- newPool (setNumStripes (connectNumStripes bootstrapConnInfo) $ defaultPoolConfig (Cluster.connect infos shardMapVar Nothing $ connectHooks bootstrapConnInfo) Cluster.disconnect (realToFrac $ connectMaxIdleTime bootstrapConnInfo) (connectMaxConnections bootstrapConnInfo))
            return $ ClusteredConnection (connectLabel bootstrapConnInfo) shardMapVar pool

shardMapFromClusterSlotsResponse :: ClusterSlotsResponse -> IO ShardMap
shardMapFromClusterSlotsResponse ClusterSlotsResponse{..} = ShardMap <$> foldr mkShardMap (pure IntMap.empty)  clusterSlotsResponseEntries where
    mkShardMap :: ClusterSlotsResponseEntry -> IO (IntMap.IntMap Shard) -> IO (IntMap.IntMap Shard)
    mkShardMap ClusterSlotsResponseEntry{..} accumulator = do
        accumulated <- accumulator
        let master = nodeFromClusterSlotNode True clusterSlotsResponseEntryMaster
        let replicas = map (nodeFromClusterSlotNode False) clusterSlotsResponseEntryReplicas
        let shard = Shard master replicas
        let slotMap = IntMap.fromList $ map (, shard) [clusterSlotsResponseEntryStartSlot..clusterSlotsResponseEntryEndSlot]
        return $ IntMap.union slotMap accumulated
    nodeFromClusterSlotNode :: Bool -> ClusterSlotsNode -> Node
    nodeFromClusterSlotNode isMaster ClusterSlotsNode{..} =
        let hostname = Char8.unpack clusterSlotsNodeIP
            role = if isMaster then Cluster.Master else Cluster.Slave
        in
            Cluster.Node clusterSlotsNodeID role hostname (toEnum clusterSlotsNodePort)

refreshShardMap :: Cluster.Connection -> IO ShardMap
refreshShardMap (Cluster.Connection nodeConns _ _ _ _) = do
    let (Cluster.NodeConnection ctx _ _) = head $ HM.elems nodeConns
    pipelineConn <- PP.fromCtx ctx
    _ <- PP.beginReceiving pipelineConn
    slotsResponse <- runRedisInternal pipelineConn clusterSlots
    case slotsResponse of
        Left e -> throwIO $ ClusterConnectError e
        Right slots -> shardMapFromClusterSlotsResponse slots
