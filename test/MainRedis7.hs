module Main (main) where

import Data.Maybe
import System.Environment
import qualified Test.Framework as Test
import Database.Redis
import Tests

main :: IO ()
main = do
    host <- fromMaybe "localhost" <$> lookupEnv "REDIS_HOST"
    port <- maybe 6379 read <$> lookupEnv "REDIS_PORT"
    conn <- connect defaultConnectInfo { connectHost = host, connectPort = PortNumber port }
    runRedis conn ping
    Test.defaultMain (tests conn)

tests :: Connection -> [Test.Test]
tests conn = map ($ conn) $ [testXCreateGroup7, testXpending7, testXAutoClaim7, testQuit]
