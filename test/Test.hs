{-# LANGUAGE OverloadedStrings, RecordWildCards #-}
module Main (main) where

import Prelude hiding (catch)
import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Monad.Trans
import Data.Monoid (mappend)
import Data.Time
import Data.Time.Clock.POSIX
import qualified Test.HUnit as Test
import Test.HUnit (runTestTT, (~:))

import Database.Redis


------------------------------------------------------------------------------
-- Main and helpers
--
main :: IO ()
main = do
    c <- connect defaultConnectInfo
    runTestTT $ Test.TestList $ map ($c) tests
    return ()

type Test = Connection -> Test.Test

testCase :: String -> Redis () -> Test
testCase name r conn = name ~:
    Test.TestCase $ runRedis conn $ flushdb >>=? Ok >> r
    
(>>=?) :: (Eq a, Show a) => Redis (Either Reply a) -> a -> Redis ()
redis >>=? expected = do
    a <- redis
    liftIO $ case a of
        Left reply   -> Test.assertFailure $ "Redis error: " ++ show reply
        Right actual -> expected Test.@=? actual

assert :: Bool -> Redis ()
assert = liftIO . Test.assert

------------------------------------------------------------------------------
-- Tests
--
tests :: [Test]
tests = concat
    [ testsMisc, testsKeys, testsStrings, testsHashes, testsLists, testsZSets
    , [testPubSub], [testTransaction], testsConnection, testsServer, [testQuit]
    ]

------------------------------------------------------------------------------
-- Miscellaneous
--
testsMisc :: [Test]
testsMisc = [testConstantSpacePipelining, testForceErrorReply, testPipelining]

testConstantSpacePipelining :: Test
testConstantSpacePipelining = testCase "constant-space pipelining" $ do
    -- This testcase should not exceed the maximum heap size, as set in
    -- the run-test.sh script.
    replicateM_ 100000 ping
    -- If the program didn't crash, pipelining takes constant memory.
    assert True

testForceErrorReply :: Test
testForceErrorReply = testCase "force error reply" $ do
    set "key" "value"
    -- key is not a hash -> wrong kind of value
    reply <- hkeys "key"
    assert $ case reply of
        Left (Error _) -> True
        _              -> False

testPipelining :: Test
testPipelining = testCase "pipelining" $ do
    let n = 10
    tPipe <- time $ do
        pongs <- replicateM n ping
        assert $ pongs == replicate n (Right Pong)
    
    tNoPipe <- time $ replicateM_ n (ping >>=? Pong)
    -- pipelining should at least be twice as fast.    
    assert $ tNoPipe / tPipe > 2

time :: Redis () -> Redis NominalDiffTime
time redis = do
    start <- liftIO $ getCurrentTime
    redis
    liftIO $ fmap (`diffUTCTime` start) getCurrentTime

------------------------------------------------------------------------------
-- Keys
--
testsKeys :: [Test]
testsKeys =
    [ testDel, testExists, testExpire, testExpireAt, testKeys, testMove
    , testPersist, testRandomkey, testRename, testRenamenx, testSort
    , testTtl, testGetType, testObject
    ]

testDel :: Test
testDel = testCase "del" $ do
    set "key" "value" >>=? Ok
    get "key"         >>=? Just "value"
    del ["key"]       >>=? 1
    get "key"         >>=? Nothing

testExists :: Test
testExists = testCase "exists" $ do
    exists "key"      >>=? False
    set "key" "value" >>=? Ok
    exists "key"      >>=? True

testExpire :: Test
testExpire = testCase "expire" $ do
    set "key" "value"  >>=? Ok
    expire "key" 1     >>=? True
    expire "notAKey" 1 >>=? False
    ttl "key"          >>=? 1
    
testExpireAt :: Test
testExpireAt = testCase "expireat" $ do
    set "key" "value"         >>=? Ok
    seconds <- floor . utcTimeToPOSIXSeconds <$> liftIO getCurrentTime
    let expiry = seconds + 1
    expireat "key" expiry     >>=? True
    expireat "notAKey" expiry >>=? False
    ttl "key"                 >>=? 1

testKeys :: Test
testKeys = testCase "keys" $ do
    keys "key*"      >>=? []
    set "key1" "value" >>=? Ok
    set "key2" "value" >>=? Ok
    Right ks <- keys "key*"
    assert $ length ks == 2
    assert $ elem "key1" ks
    assert $ elem "key2" ks

testMove :: Test
testMove = testCase "move" $ do
    set "key" "value" >>=? Ok
    move "key" 13     >>=? True
    get "key"         >>=? Nothing
    select 13         >>=? Ok
    get "key"         >>=? Just "value"

testPersist :: Test
testPersist = testCase "persist" $ do
    set "key" "value" >>=? Ok
    expire "key" 1    >>=? True
    ttl "key"         >>=? 1
    persist "key"     >>=? True
    ttl "key"         >>=? (-1)

testRandomkey :: Test
testRandomkey = testCase "randomkey" $ do
    set "k1" "value" >>=? Ok
    set "k2" "value" >>=? Ok
    Right (Just k) <- randomkey
    assert $ k `elem` ["k1", "k2"]

testRename :: Test
testRename = testCase "rename" $ do
    set "k1" "value" >>=? Ok
    rename "k1" "k2" >>=? Ok
    get "k1"         >>=? Nothing
    get "k2"         >>=? Just ("value" )

testRenamenx :: Test
testRenamenx = testCase "renamenx" $ do
    set "k1" "value"   >>=? Ok
    set "k2" "value"   >>=? Ok
    renamenx "k1" "k2" >>=? False
    renamenx "k1" "k3" >>=? True

testSort :: Test
testSort = testCase "sort" $ do
    lpush "ids"     ["1","2","3"]                >>=? 3
    sort "ids" defaultSortOpts                   >>=? ["1","2","3"]
    sortStore "ids" "anotherKey" defaultSortOpts >>=? 3
    mset [("weight_1","1")
         ,("weight_2","2")
         ,("weight_3","3")
         ,("object_1","foo")
         ,("object_2","bar")
         ,("object_3","baz")
         ]
    let opts = defaultSortOpts { sortOrder = Desc, sortAlpha = True
                               , sortLimit = (1,2)
                               , sortBy    = Just "weight_*"
                               , sortGet   = ["#", "object_*"] }
    sort "ids" opts >>=? ["2", "bar", "1", "foo"]
    
    
testTtl :: Test
testTtl = testCase "ttl" $ do
    set "key" "value" >>=? Ok
    ttl "notAKey"     >>=? (-1)
    ttl "key"         >>=? (-1)
    expire "key" 42   >>=? True
    ttl "key"         >>=? 42

testGetType :: Test
testGetType = testCase "getType" $ do
    getType "key"     >>=? None
    forM_ ts $ \(setKey, typ) -> do
        setKey
        getType "key" >>=? typ
        del ["key"]   >>=? 1
  where
    ts = [ (set "key" "value"                         >>=? Ok,   String)
         , (hset "key" "field" "value"                >>=? True, Hash)
         , (lpush "key" ["value"]                     >>=? 1,    List)
         , (sadd "key" ["member"]                     >>=? 1,    Set)
         , (zadd "key" [(42,"member"),(12.3,"value")] >>=? 2,    ZSet)
         ]

testObject :: Test
testObject = testCase "object" $ do
    set "key" "value"    >>=? Ok
    objectRefcount "key" >>=? 1
    Right _ <- objectEncoding "key"
    objectIdletime "key" >>=? 0

------------------------------------------------------------------------------
-- Strings
--
testsStrings :: [Test]
testsStrings =
    [ testAppend, testDecr, testDecrby, testGetbit, testGetrange, testGetset
    , testIncr, testIncrby, testMget, testMset, testMsetnx, testSetbit
    , testSetex, testSetnx, testSetrange, testStrlen, testSetAndGet
    ]

testAppend :: Test
testAppend = testCase "append" $ do
    set "key" "hello"    >>=? Ok
    append "key" "world" >>=? 10
    get "key"            >>=? Just "helloworld"

testDecr :: Test
testDecr = testCase "decr" $ do
    set "key" "42" >>=? Ok
    decr "key"     >>=? 41

testDecrby :: Test
testDecrby = testCase "decrby" $ do
    set "key" "42"  >>=? Ok
    decrby "key" 2  >>=? 40

testGetbit :: Test
testGetbit = testCase "getbit" $ getbit "key" 42 >>=? 0

testGetrange :: Test
testGetrange = testCase "getrange" $ do
    set "key" "value"     >>=? Ok
    getrange "key" 1 (-2) >>=? "alu"

testGetset :: Test
testGetset = testCase "getset" $ do
    getset "key" "v1" >>=? Nothing
    getset "key" "v2" >>=? Just "v1"

testIncr :: Test
testIncr = testCase "incr" $ do
    set "key" "42" >>=? Ok
    incr "key"     >>=? 43

testIncrby :: Test
testIncrby = testCase "incrby" $ do
    set "key" "40" >>=? Ok
    incrby "key" 2 >>=? 42

testMget :: Test
testMget = testCase "mget" $ do
    set "k1" "v1"               >>=? Ok
    set "k2" "v2"               >>=? Ok
    mget ["k1","k2","notAKey" ] >>=? [Just "v1", Just "v2", Nothing]

testMset :: Test
testMset = testCase "mset" $ do
    mset [("k1","v1"), ("k2","v2")] >>=? Ok
    get "k1"                        >>=? Just "v1"
    get "k2"                        >>=? Just "v2"

testMsetnx :: Test
testMsetnx = testCase "msetnx" $ do
    msetnx [("k1","v1"), ("k2","v2")] >>=? True
    msetnx [("k1","v1"), ("k2","v2")] >>=? False

testSetbit :: Test
testSetbit = testCase "setbit" $ do
    setbit "key" 42 "1" >>=? 0
    setbit "key" 42 "0" >>=? 1
    
testSetex :: Test
testSetex = testCase "setex" $ do
    setex "key" 1 "value" >>=? Ok
    ttl "key"             >>=? 1

testSetnx :: Test
testSetnx = testCase "setnx" $ do
    setnx "key" "v1" >>=? True
    setnx "key" "v2" >>=? False

testSetrange :: Test
testSetrange = testCase "setrange" $ do
    set "key" "value"      >>=? Ok
    setrange "key" 1 "ers" >>=? 5
    get "key"              >>=? Just "verse"

testStrlen :: Test
testStrlen = testCase "strlen" $ do
    set "key" "value" >>=? Ok
    strlen "key"      >>=? 5

testSetAndGet :: Test
testSetAndGet = testCase "set/get" $ do
    get "key"         >>=? Nothing
    set "key" "value" >>=? Ok
    get "key"         >>=? Just "value"


------------------------------------------------------------------------------
-- Hashes
--
testsHashes :: [Test]
testsHashes =
    [ testHdel, testHexists,testHget, testHgetall, testHincrby, testHkeys
    , testHlen, testHmget, testHmset, testHset, testHsetnx, testHvals
    ]

testHdel :: Test
testHdel = testCase "hdel" $ do
    hdel "key" ["field"]       >>=? False
    hset "key" "field" "value" >>=? True
    hdel "key" ["field"]       >>=? True

testHexists :: Test
testHexists = testCase "hexists" $ do
    hexists "key" "field"      >>=? False
    hset "key" "field" "value" >>=? True
    hexists "key" "field"      >>=? True

testHget :: Test
testHget = testCase "hget" $ do
    hget "key" "field"         >>=? Nothing
    hset "key" "field" "value" >>=? True
    hget "key" "field"         >>=? Just "value"

testHgetall :: Test
testHgetall = testCase "hgetall" $ do
    hgetall "key"                         >>=? []
    hmset "key" [("f1","v1"),("f2","v2")] >>=? Ok
    hgetall "key"                         >>=? [("f1","v1"), ("f2","v2")]
    
testHincrby :: Test
testHincrby = testCase "hincrby" $ do
    hset "key" "field" "40" >>=? True
    hincrby "key" "field" 2 >>=? 42

testHkeys :: Test
testHkeys = testCase "hkeys" $ do
    hset "key" "field" "value" >>=? True
    hkeys "key"                >>=? ["field"]

testHlen :: Test
testHlen = testCase "hlen" $ do
    hlen "key"                 >>=? 0
    hset "key" "field" "value" >>=? True
    hlen "key"                 >>=? 1

testHmget :: Test
testHmget = testCase "hmget" $ do
    hmset "key" [("f1","v1"), ("f2","v2")] >>=? Ok
    hmget "key" ["f1", "f2", "nofield" ]   >>=? [Just "v1", Just "v2", Nothing]

testHmset :: Test
testHmset = testCase "hmset" $ do
    hmset "key" [("f1","v1"), ("f2","v2")] >>=? Ok

testHset :: Test
testHset = testCase "hset" $ do
    hset "key" "field" "value" >>=? True
    hset "key" "field" "value" >>=? False

testHsetnx :: Test
testHsetnx = testCase "hsetnx" $ do
    hsetnx "key" "field" "value" >>=? True
    hsetnx "key" "field" "value" >>=? False

testHvals :: Test
testHvals = testCase "hvals" $ do
    hset "key" "field" "value" >>=? True
    hvals "key"                >>=? ["value"]


------------------------------------------------------------------------------
-- Lists
--
testsLists :: [Test]
testsLists =
    [testBlpop, testBrpoplpush, testLpop, testLinsert, testLpushx, testLset]

testBlpop :: Test
testBlpop = testCase "blpop/brpop" $ do
    lpush "key" ["v3","v2","v1"] >>=? 3
    blpop ["notAKey","key"] 1    >>=? Just ("key","v1")
    brpop ["notAKey","key"] 1    >>=? Just ("key","v3")
    -- run into timeout
    blpop ["notAKey"] 1          >>=? Nothing

testBrpoplpush :: Test
testBrpoplpush = testCase "brpoplpush/rpoplpush" $ do
    rpush "k1" ["v1","v2"]      >>=? 2
    brpoplpush "k1" "k2" 1      >>=? Just "v2"
    rpoplpush "k1" "k2"         >>=? Just "v1"
    rpoplpush "notAKey" "k2"    >>=? Nothing
    llen "k2"                   >>=? 2
    llen "k1"                   >>=? 0
    -- run into timeout
    brpoplpush "notAKey" "k2" 1 >>=? Nothing

testLpop :: Test
testLpop = testCase "lpop/rpop" $ do
    lpush "key" ["v3","v2","v1"] >>=? 3
    lpop "key"                   >>=? Just "v1"
    llen "key"                   >>=? 2
    rpop "key"                   >>=? Just "v3"

testLinsert :: Test
testLinsert = testCase "linsert" $ do
    rpush "key" ["v2"]                 >>=? 1
    linsertBefore "key" "v2" "v1"      >>=? 2
    linsertBefore "key" "notAVal" "v3" >>=? (-1)
    linsertAfter "key" "v2" "v3"       >>=? 3    
    linsertAfter "key" "notAVal" "v3"  >>=? (-1)
    lindex "key" 0                     >>=? Just "v1"
    lindex "key" 2                     >>=? Just "v3"

testLpushx :: Test
testLpushx = testCase "lpushx/rpushx" $ do
    lpushx "notAKey" "v1" >>=? 0
    lpush "key" ["v2"]    >>=? 1
    lpushx "key" "v1"     >>=? 2
    rpushx "key" "v3"     >>=? 3

testLset :: Test
testLset = testCase "lset/lrem/ltrim" $ do
    lpush "key" ["v3","v2","v2","v1","v1"] >>=? 5
    lset "key" 1 "v2"                      >>=? Ok
    lrem "key" 2 "v2"                      >>=? 2
    llen "key"                             >>=? 3
    ltrim "key" 0 1                        >>=? Ok
    lrange "key" 0 1                       >>=? ["v1", "v2"]

------------------------------------------------------------------------------
-- Sets
--

------------------------------------------------------------------------------
-- Sorted Sets
--
testsZSets :: [Test]
testsZSets = [testZAdd, testZRank, testZRemRange, testZRange, testZStore]

testZAdd :: Test
testZAdd = testCase "zadd/zrem/zcard/zscore/zincrby" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")] >>=? 3
    zscore "key" "v3"                        >>=? Just 40
    zincrby "key" 2 "v3"                     >>=? 42
    zrem "key" ["v3","notAKey"]              >>=? 1
    zcard "key"                              >>=? 2

testZRank :: Test
testZRank = testCase "zrank/zrevrank/zcount" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")] >>=? 3
    zrank "notAKey" "v1"                     >>=? Nothing
    zrank "key" "v1"                         >>=? Just 0
    zrevrank "key" "v1"                      >>=? Just 2
    zcount "key" 10 100                      >>=? 1

testZRemRange :: Test
testZRemRange = testCase "zremrangebyscore/zremrangebyrank" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")] >>=? 3
    zremrangebyrank "key" 0 1                >>=? 2
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")] >>=? 2
    zremrangebyscore "key" 10 100            >>=? 1

testZRange :: Test
testZRange = testCase "zrange/zrevrange/zrangebyscore/zrevrangebyscore" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(3,"v3")]           >>=? 3
    zrange "key" 0 1                                  >>=? ["v1","v2"]
    zrevrange "key" 0 1                               >>=? ["v3","v2"]
    zrangeWithscores "key" 0 1                        >>=? [("v1",1),("v2",2)]
    zrevrangeWithscores "key" 0 1                     >>=? [("v3",3),("v2",2)]
    zrangebyscore "key" 0.5 1.5                       >>=? ["v1"]
    zrangebyscoreWithscores "key" 0.5 1.5             >>=? [("v1",1)]
    zrangebyscoreLimit "key" 0.5 2.5 0 1              >>=? ["v1"]
    zrangebyscoreWithscoresLimit "key" 0.5 2.5 0 1    >>=? [("v1",1)]
    zrevrangebyscore "key" 1.5 0.5                    >>=? ["v1"]
    zrevrangebyscoreWithscores "key" 1.5 0.5          >>=? [("v1",1)]
    zrevrangebyscoreLimit "key" 2.5 0.5 0 1           >>=? ["v2"]
    zrevrangebyscoreWithscoresLimit "key" 2.5 0.5 0 1 >>=? [("v2",2)]

testZStore :: Test
testZStore = testCase "zunionstore/zinterstore" $ do
    zadd "k1" [(1, "v1"), (2, "v2")]
    zadd "k2" [(2, "v2"), (3, "v3")]
    zinterstore "newkey" ["k1","k2"] Sum                >>=? 1
    zinterstoreWeights "newkey" [("k1",1),("k2",2)] Max >>=? 1
    zunionstore "newkey" ["k1","k2"] Sum                >>=? 3
    zunionstoreWeights "newkey" [("k1",1),("k2",2)] Min >>=? 3


------------------------------------------------------------------------------
-- Pub/Sub
--
testPubSub :: Test
testPubSub conn = testCase "pubSub" go conn
  where
    go = do
        -- producer
        liftIO $ forkIO $ do
            runRedis conn $ do
                let t = 10^(5 :: Int)
                liftIO $ threadDelay t
                publish "chan1" "hello" >>=? 1
                liftIO $ threadDelay t
                publish "chan2" "world" >>=? 1
            return ()

        -- consumer
        pubSub (subscribe ["chan1"]) $ \msg -> do
            -- ready for a message
            case msg of
                Message{..} -> return
                    (unsubscribe [msgChannel] `mappend` psubscribe ["chan*"])
                PMessage{..} -> return (punsubscribe [msgPattern])


------------------------------------------------------------------------------
-- Transaction
--
testTransaction :: Test
testTransaction = testCase "transaction" $ do
    watch ["k1", "k2"] >>=? Ok
    unwatch            >>=? Ok
    set "foo" "foo"
    set "bar" "bar"
    foobar <- multiExec $ do
        foo <- get "foo"
        bar <- get "bar"
        return $ (,) <$> foo <*> bar
    assert $ foobar == TxSuccess (Just "foo", Just "bar")

    
------------------------------------------------------------------------------
-- Connection
--
testsConnection :: [Test]
testsConnection = [ testEcho, testPing, testSelect ]

testEcho :: Test
testEcho = testCase "echo" $
    echo ("value" ) >>=? "value"

testPing :: Test
testPing = testCase "ping" $ ping >>=? Pong

testQuit :: Test
testQuit = testCase "quit" $ quit >>=? Ok

testSelect :: Test
testSelect = testCase "select" $ do
    select 13 >>=? Ok
    select 0 >>=? Ok


------------------------------------------------------------------------------
-- Server
--
testsServer :: [Test]
testsServer =
    [testBgrewriteaof, testFlushall, testInfo, testConfig, testSlowlog
    ,testDebugObject]

testBgrewriteaof :: Test
testBgrewriteaof = testCase "bgrewriteaof/bgsave/save" $ do
    save >>=? Ok
    -- TODO return types not as documented
    -- bgsave       >>=? BgSaveStarted
    -- bgrewriteaof >>=? BgAOFRewriteStarted

testConfig :: Test
testConfig = testCase "config/auth" $ do
    configSet "requirepass" "pass" >>=? Ok
    auth "pass"                    >>=? Ok
    configSet "requirepass" ""     >>=? Ok
    
testFlushall :: Test
testFlushall = testCase "flushall/flushdb" $ do
    flushall >>=? Ok
    flushdb  >>=? Ok

testInfo :: Test
testInfo = testCase "info/lastsave/dbsize" $ do
    Right _ <- info
    Right _ <- lastsave
    dbsize          >>=? 0
    configResetstat >>=? Ok

testSlowlog :: Test
testSlowlog = testCase "slowlog" $ do
    slowlogGet 5 >>=? []
    slowlogLen   >>=? 0
    slowlogReset >>=? Ok

testDebugObject :: Test
testDebugObject = testCase "debugObject/debugSegfault" $ do
    set "key" "value" >>=? Ok
    Right _ <- debugObject "key"
    -- Right Ok <- debugSegfault
    return ()
