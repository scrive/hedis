{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
module Database.Redis.Cluster
  ( Connection(..)
  , NodeRole(..)
  , NodeConnection(..)
  , Node(..)
  , ShardMap(..)
  , HashSlot
  , Shard(..)
  , connect
  , disconnect
  , requestPipelined
  , nodes
  , hooks
) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as Char8
import qualified Data.IORef as IOR
import Data.List(nub, sortBy, find)
import Data.Map(fromListWith, assocs)
import Data.Function(on)
import Control.Exception(Exception, throwIO, BlockedIndefinitelyOnMVar(..), catches, Handler(..))
import Control.Concurrent.MVar(MVar, newMVar, readMVar, modifyMVar, modifyMVar_)
import Control.Monad(zipWithM, when, replicateM)
import Database.Redis.Cluster.HashSlot(HashSlot, keyToSlot)
import qualified Database.Redis.ConnectionContext as CC
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict as IntMap
import           Data.Typeable
import qualified Scanner
import System.IO.Unsafe(unsafeInterleaveIO)

import Database.Redis.Protocol(Reply(Error), renderRequest, reply)
import qualified Database.Redis.Cluster.Command as CMD
import Database.Redis.Hooks (Hooks)

-- This module implements a clustered connection whilst maintaining
-- compatibility with the original Hedis codebase. In particular it still
-- performs implicit pipelining using `unsafeInterleaveIO` as the single node
-- codebase does. To achieve this each connection carries around with it a
-- pipeline of commands. Every time `sendRequest` is called the command is
-- added to the pipeline and an IO action is returned which will, upon being
-- evaluated, execute the entire pipeline. If the pipeline is already executed
-- then it just looks up it's response in the executed pipeline.

-- | A connection to a redis cluster, it is compoesed of a map from Node IDs to
-- | 'NodeConnection's, a 'Pipeline', and a 'ShardMap'
data Connection = Connection (HM.HashMap NodeID NodeConnection) (MVar Pipeline) (MVar ShardMap) CMD.InfoMap Hooks

-- | A connection to a single node in the cluster, similar to 'ProtocolPipelining.Connection'
data NodeConnection = NodeConnection CC.ConnectionContext (IOR.IORef (Maybe B.ByteString)) NodeID

instance Eq NodeConnection where
    (NodeConnection _ _ id1) == (NodeConnection _ _ id2) = id1 == id2

instance Ord NodeConnection where
    compare (NodeConnection _ _ id1) (NodeConnection _ _ id2) = compare id1 id2

data PipelineState =
      -- Nothing in the pipeline has been evaluated yet so nothing has been
      -- sent
      Pending [[B.ByteString]]
      -- This pipeline has been executed, the replies are contained within it
    | Executed [Reply]
      -- We're in a MULTI-EXEC transaction. All commands in the transaction
      -- should go to the same node, but we won't know what node that is until
      -- we see a command with a key. We're storing these transactions and will
      -- send them all together when we see an EXEC.
    | TransactionPending [[B.ByteString]]
-- A pipeline has an MVar for the current state, this state is actually always
-- `Pending` because the first thing the implementation does when executing a
-- pipeline is to take the current pipeline state out of the MVar and replace
-- it with a new `Pending` state. The executed state is held on to by the
-- replies within it.

newtype Pipeline = Pipeline (MVar PipelineState)

data NodeRole = Master | Slave deriving (Show, Eq, Ord)

type Host = String
type Port = Int
type NodeID = B.ByteString
data Node = Node NodeID NodeRole Host Port deriving (Show, Eq, Ord)

type MasterNode = Node
type SlaveNode = Node
data Shard = Shard MasterNode [SlaveNode] deriving (Show, Eq, Ord)

newtype ShardMap = ShardMap (IntMap.IntMap Shard) deriving (Show)

newtype MissingNodeException = MissingNodeException [B.ByteString] deriving (Show, Typeable)
instance Exception MissingNodeException

newtype UnsupportedClusterCommandException = UnsupportedClusterCommandException [B.ByteString] deriving (Show, Typeable)
instance Exception UnsupportedClusterCommandException

newtype CrossSlotException = CrossSlotException [[B.ByteString]] deriving (Show, Typeable)
instance Exception CrossSlotException

connect :: [CMD.CommandInfo] -> MVar ShardMap -> Maybe Int -> Hooks -> IO Connection
connect commandInfos shardMapVar timeoutOpt hooks' = do
        shardMap <- readMVar shardMapVar
        stateVar <- newMVar $ Pending []
        pipelineVar <- newMVar $ Pipeline stateVar
        nodeConns <- nodeConnections shardMap
        return $ Connection nodeConns pipelineVar shardMapVar (CMD.newInfoMap commandInfos) hooks' where
    nodeConnections :: ShardMap -> IO (HM.HashMap NodeID NodeConnection)
    nodeConnections shardMap = HM.fromList <$> mapM connectNode (nub $ nodes shardMap)
    connectNode :: Node -> IO (NodeID, NodeConnection)
    connectNode (Node n _ host port) = do
        ctx <- CC.connect host (CC.PortNumber $ toEnum port) timeoutOpt
        ref <- IOR.newIORef Nothing
        return (n, NodeConnection ctx ref n)

disconnect :: Connection -> IO ()
disconnect (Connection nodeConnMap _ _ _ _) = mapM_ disconnectNode (HM.elems nodeConnMap) where
    disconnectNode (NodeConnection nodeCtx _ _) = CC.disconnect nodeCtx

-- Add a request to the current pipeline for this connection. The pipeline will
-- be executed implicitly as soon as any result returned from this function is
-- evaluated.
requestPipelined :: IO ShardMap -> Connection -> [B.ByteString] -> IO Reply
requestPipelined refreshAction conn@(Connection _ pipelineVar shardMapVar _ _) nextRequest = modifyMVar pipelineVar $ \(Pipeline stateVar) -> do
    (newStateVar, repliesIndex) <- hasLocked $ modifyMVar stateVar $ \case
        Pending requests | isMulti nextRequest -> do
            replies <- evaluatePipeline shardMapVar refreshAction conn requests
            s' <- newMVar $ TransactionPending [nextRequest]
            return (Executed replies, (s', 0))
        Pending requests | length requests > 1000 -> do
            replies <- evaluatePipeline shardMapVar refreshAction conn (nextRequest:requests)
            return (Executed replies, (stateVar, length requests))
        Pending requests ->
            return (Pending (nextRequest:requests), (stateVar, length requests))
        TransactionPending requests ->
            if isExec nextRequest then do
              replies <- evaluateTransactionPipeline shardMapVar refreshAction conn (nextRequest:requests)
              return (Executed replies, (stateVar, length requests))
            else
              return (TransactionPending (nextRequest:requests), (stateVar, length requests))
        e@(Executed _) -> do
            s' <- newMVar $
                    if isMulti nextRequest then
                        TransactionPending [nextRequest]
                    else
                        Pending [nextRequest]
            return (e, (s', 0))
    evaluateAction <- unsafeInterleaveIO $ do
        replies <- hasLocked $ modifyMVar newStateVar $ \case
            Executed replies ->
                return (Executed replies, replies)
            Pending requests-> do
                replies <- evaluatePipeline shardMapVar refreshAction conn requests
                return (Executed replies, replies)
            TransactionPending requests-> do
                replies <- evaluateTransactionPipeline shardMapVar refreshAction conn requests
                return (Executed replies, replies)
        return $ replies !! repliesIndex
    return (Pipeline newStateVar, evaluateAction)

isMulti :: [B.ByteString] -> Bool
isMulti ("MULTI" : _) = True
isMulti _ = False

isExec :: [B.ByteString] -> Bool
isExec ("EXEC" : _) = True
isExec _ = False

data PendingRequest = PendingRequest Int [B.ByteString]
data CompletedRequest = CompletedRequest Int [B.ByteString] Reply

rawRequest :: PendingRequest -> [B.ByteString]
rawRequest (PendingRequest _ r) =  r

responseIndex :: CompletedRequest -> Int
responseIndex (CompletedRequest i _ _) = i

rawResponse :: CompletedRequest -> Reply
rawResponse (CompletedRequest _ _ r) = r

-- The approach we take here is similar to that taken by the redis-py-cluster
-- library, which is described at https://redis-py-cluster.readthedocs.io/en/master/pipelines.html
--
-- Essentially we group all the commands by node (based on the current shardmap)
-- and then execute a pipeline for each node (maintaining the order of commands
-- on a per node basis but not between nodes). Once we've done this, if any of
-- the commands have resulted in a MOVED error we refresh the shard map, then
-- we run through all the responses and retry any MOVED or ASK errors. This retry
-- step is not pipelined, there is a request per error. This is probably
-- acceptable in most cases as these errors should only occur in the case of
-- cluster reconfiguration events, which should be rare.
evaluatePipeline :: MVar ShardMap -> IO ShardMap -> Connection -> [[B.ByteString]] -> IO [Reply]
evaluatePipeline shardMapVar refreshShardmapAction conn requests = do
        shardMap <- hasLocked $ readMVar shardMapVar
        requestsByNode <- getRequestsByNode shardMap
        resps <- concat <$> mapM (uncurry executeRequests) requestsByNode
        when (any (moved . rawResponse) resps) refreshShardMapVar
        retriedResps <- mapM (retry 0) resps
        return $ map rawResponse $ sortBy (on compare responseIndex) retriedResps
  where
    getRequestsByNode :: ShardMap -> IO [(NodeConnection, [PendingRequest])]
    getRequestsByNode shardMap = do
        commandsWithNodes <- zipWithM (requestWithNodes shardMap) (reverse [0..(length requests - 1)]) requests
        return $ assocs $ fromListWith (++) (mconcat commandsWithNodes)
    requestWithNodes :: ShardMap -> Int -> [B.ByteString] -> IO [(NodeConnection, [PendingRequest])]
    requestWithNodes shardMap index request = do
        nodeConns <- nodeConnectionForCommand conn shardMap request
        return $ (, [PendingRequest index request]) <$> nodeConns
    executeRequests :: NodeConnection -> [PendingRequest] -> IO [CompletedRequest]
    executeRequests nodeConn nodeRequests = do
        replies <- requestNode nodeConn $ map rawRequest nodeRequests
        return $ zipWith (curry (\(PendingRequest i r, rep) -> CompletedRequest i r rep)) nodeRequests replies
    retry :: Int -> CompletedRequest -> IO CompletedRequest
    retry retryCount (CompletedRequest index request thisReply) = do
        retryReply <- head <$> retryBatch shardMapVar refreshShardmapAction conn retryCount [request] [thisReply]
        return (CompletedRequest index request retryReply)
    refreshShardMapVar :: IO ()
    refreshShardMapVar = hasLocked $ modifyMVar_ shardMapVar (const refreshShardmapAction)

-- Retry a batch of requests if any of the responses is a redirect instruction.
-- If multiple requests are passed in they're assumed to be a MULTI..EXEC
-- transaction and will all be retried.
retryBatch :: MVar ShardMap -> IO ShardMap -> Connection -> Int -> [[B.ByteString]] -> [Reply] -> IO [Reply]
retryBatch shardMapVar refreshShardmapAction conn retryCount requests replies =
    -- The last reply will be the `EXEC` reply containing the redirection, if
    -- there is one.
    case last replies of
        (Error errString) | B.isPrefixOf "MOVED" errString -> do
            let (Connection _ _ _ infoMap _) = conn
            keys <- mconcat <$> mapM (requestKeys infoMap) requests
            hashSlot <- hashSlotForKeys (CrossSlotException requests) keys
            nodeConn <- nodeConnForHashSlot shardMapVar conn (MissingNodeException (head requests)) hashSlot
            requestNode nodeConn requests
        (askingRedirection -> Just (host, port)) -> do
            shardMap <- hasLocked $ readMVar shardMapVar
            let maybeAskNode = nodeConnWithHostAndPort shardMap conn host port
            case maybeAskNode of
                Just askNode -> tail <$> requestNode askNode (["ASKING"] : requests)
                Nothing -> case retryCount of
                    0 -> do
                        _ <- hasLocked $ modifyMVar_ shardMapVar (const refreshShardmapAction)
                        retryBatch shardMapVar refreshShardmapAction conn (retryCount + 1) requests replies
                    _ -> throwIO $ MissingNodeException (head requests)
        _ -> return replies

-- Like `evaluateOnPipeline`, except we expect to be able to run all commands
-- on a single shard. Failing to meet this expectation is an error.
evaluateTransactionPipeline :: MVar ShardMap -> IO ShardMap -> Connection -> [[B.ByteString]] -> IO [Reply]
evaluateTransactionPipeline shardMapVar refreshShardmapAction conn requests' = do
    let requests = reverse requests'
    let (Connection _ _ _ infoMap _) = conn
    keys <- mconcat <$> mapM (requestKeys infoMap) requests
    -- In cluster mode Redis expects commands in transactions to all work on the
    -- same hashslot. We find that hashslot here.
    -- We could be more permissive and allow transactions that touch multiple
    -- hashslots, as long as those hashslots are on the same node. This allows
    -- a new failure case though: if some of the transactions hashslots are
    -- moved to a different node we could end up in a situation where some of
    -- the commands in a transaction are applied and some are not. Better to
    -- fail early.
    hashSlot <- hashSlotForKeys (CrossSlotException requests) keys
    nodeConn <- nodeConnForHashSlot shardMapVar conn (MissingNodeException (head requests)) hashSlot
    resps <- requestNode nodeConn requests
    -- The Redis documentation has the following to say on the effect of
    -- resharding on multi-key operations:
    --
    --     Multi-key operations may become unavailable when a resharding of the
    --     hash slot the keys belong to is in progress.
    --
    --     More specifically, even during a resharding the multi-key operations
    --     targeting keys that all exist and all still hash to the same slot
    --     (either the source or destination node) are still available.
    --
    --     Operations on keys that don't exist or are - during the resharding -
    --     split between the source and destination nodes, will generate a
    --     -TRYAGAIN error. The client can try the operation after some time,
    --     or report back the error.
    --
    --     https://redis.io/topics/cluster-spec#multiple-keys-operations
    --
    -- An important take-away here is that MULTI..EXEC transactions can fail
    -- with a redirect in which case we need to repeat the full transaction on
    -- the node we're redirected too.
    --
    -- A second important takeway is that MULTI..EXEC transactions might
    -- temporarily fail during resharding with a -TRYAGAIN error. We can only
    -- make arbitrary decisions about how long to paus before the retry and how
    -- often to retry, so instead we'll propagate the error to the library user
    -- and let them decide how they would like to handle the error.
    when (any moved resps)
      (hasLocked $ modifyMVar_ shardMapVar (const refreshShardmapAction))
    retriedResps <- retryBatch shardMapVar refreshShardmapAction conn 0 requests resps
    return retriedResps

nodeConnForHashSlot :: Exception e => MVar ShardMap -> Connection -> e -> HashSlot -> IO NodeConnection
nodeConnForHashSlot shardMapVar conn exception hashSlot = do
    let (Connection nodeConns _ _ _ _) = conn
    (ShardMap shardMap) <- hasLocked $ readMVar shardMapVar
    node <-
        case IntMap.lookup (fromEnum hashSlot) shardMap of
            Nothing -> throwIO exception
            Just (Shard master _) -> return master
    case HM.lookup (nodeId node) nodeConns of
        Nothing -> throwIO exception
        Just nodeConn' -> return nodeConn'

hashSlotForKeys :: Exception e => e -> [B.ByteString] -> IO HashSlot
hashSlotForKeys exception keys =
    case nub (keyToSlot <$> keys) of
        -- If none of the commands contain a key we can send them to any
        -- node. Let's pick the first one.
        [] -> return 0
        [hashSlot] -> return hashSlot
        _ -> throwIO $ exception

requestKeys :: CMD.InfoMap -> [B.ByteString] -> IO [B.ByteString]
requestKeys infoMap request =
    case CMD.keysForRequest infoMap request of
        Nothing -> throwIO $ UnsupportedClusterCommandException request
        Just k -> return k

askingRedirection :: Reply -> Maybe (Host, Port)
askingRedirection (Error errString) = case Char8.words errString of
    ["ASK", _, hostport] -> case Char8.split ':' hostport of
       [host, portString] -> case Char8.readInt portString of
         Just (port,"") -> Just (Char8.unpack host, port)
         _ -> Nothing
       _ -> Nothing
    _ -> Nothing
askingRedirection _ = Nothing

moved :: Reply -> Bool
moved (Error errString) = case Char8.words errString of
    "MOVED":_ -> True
    _ -> False
moved _ = False


nodeConnWithHostAndPort :: ShardMap -> Connection -> Host -> Port -> Maybe NodeConnection
nodeConnWithHostAndPort shardMap (Connection nodeConns _ _ _ _) host port = do
    node <- nodeWithHostAndPort shardMap host port
    HM.lookup (nodeId node) nodeConns

nodeConnectionForCommand :: Connection -> ShardMap -> [B.ByteString] -> IO [NodeConnection]
nodeConnectionForCommand conn@(Connection nodeConns _ _ infoMap _) (ShardMap shardMap) request =
    case request of
        ("FLUSHALL" : _) -> allNodes
        ("FLUSHDB" : _) -> allNodes
        ("QUIT" : _) -> allNodes
        ("UNWATCH" : _) -> allNodes
        _ -> do
            keys <- requestKeys infoMap request
            hashSlot <- hashSlotForKeys (CrossSlotException [request]) keys
            node <- case IntMap.lookup (fromEnum hashSlot) shardMap of
                Nothing -> throwIO $ MissingNodeException request
                Just (Shard master _) -> return master
            maybe (throwIO $ MissingNodeException request) (return . return) (HM.lookup (nodeId node) nodeConns)
    where
        allNodes =
            case allMasterNodes conn (ShardMap shardMap) of
                Nothing -> throwIO $ MissingNodeException request
                Just allNodes' -> return allNodes'

allMasterNodes :: Connection -> ShardMap -> Maybe [NodeConnection]
allMasterNodes (Connection nodeConns _ _ _ _) (ShardMap shardMap) =
    mapM (flip HM.lookup nodeConns . nodeId) masterNodes
  where
    masterNodes = (\(Shard master _) -> master) <$> nub (IntMap.elems shardMap)

requestNode :: NodeConnection -> [[B.ByteString]] -> IO [Reply]
requestNode (NodeConnection ctx lastRecvRef _) requests = do
    mapM_ (sendNode . renderRequest) requests
    _ <- CC.flush ctx
    replicateM (length requests) recvNode

    where

    sendNode :: B.ByteString -> IO ()
    sendNode = CC.send ctx
    recvNode :: IO Reply
    recvNode = do
        maybeLastRecv <- IOR.readIORef lastRecvRef
        scanResult <- case maybeLastRecv of
            Just lastRecv -> Scanner.scanWith (CC.recv ctx) reply lastRecv
            Nothing -> Scanner.scanWith (CC.recv ctx) reply B.empty

        case scanResult of
          Scanner.Fail{}       -> CC.errConnClosed
          Scanner.More{}    -> error "Hedis: parseWith returned Partial"
          Scanner.Done rest' r -> do
            IOR.writeIORef lastRecvRef (Just rest')
            return r

nodes :: ShardMap -> [Node]
nodes (ShardMap shardMap) = concatMap snd $ IntMap.toList $ fmap shardNodes shardMap where
    shardNodes :: Shard -> [Node]
    shardNodes (Shard master slaves) = master:slaves


nodeWithHostAndPort :: ShardMap -> Host -> Port -> Maybe Node
nodeWithHostAndPort shardMap host port = find (\(Node _ _ nodeHost nodePort) -> port == nodePort && host == nodeHost) (nodes shardMap)

nodeId :: Node -> NodeID
nodeId (Node theId _ _ _) = theId

hasLocked :: IO a -> IO a
hasLocked action =
  action `catches`
  [ Handler $ \exc@BlockedIndefinitelyOnMVar -> throwIO exc
  ]

hooks :: Connection -> Hooks
hooks (Connection _ _ _ _ h) = h
