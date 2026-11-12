{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.Async (forConcurrently)
import Control.Exception (ErrorCall (..), SomeException, bracket, throwIO, try)
import Control.Monad (void)
import Data.ByteString.Char8 qualified as BS
import Data.List (nub)
import Database.PostgreSQL.Simple (Connection, Only (..), close, connectPostgreSQL, execute_, query_)
import Database.PostgreSQL.TemplateDb
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

setup :: Connection -> IO ()
setup conn = do
  void $ execute_ conn "CREATE TABLE item (id serial PRIMARY KEY, name text NOT NULL)"
  void $ execute_ conn "INSERT INTO item (name) VALUES ('seed')"

withConn :: TestDb -> (Connection -> IO a) -> IO a
withConn db = bracket (connectPostgreSQL (testDbConnectionString db)) close

count :: Connection -> IO Int
count conn = do
  [Only n] <- query_ conn "SELECT count(*)::int FROM item"
  pure n

main :: IO ()
main =
  withCluster defaultConfig{configSetup = setup} $ \cluster ->
    defaultMain $
      testGroup
        "postgres-template-db"
        [ testCase "a clone starts with the template's schema and rows" $
            withTestDb cluster $ \db -> withConn db $ \conn -> count conn >>= (@?= 1)
        , testCase "clones do not share writes" $
            withTestDb cluster $ \a -> withTestDb cluster $ \b -> do
              withConn a $ \conn -> void $ execute_ conn "INSERT INTO item (name) VALUES ('a')"
              withConn a count >>= (@?= 2)
              withConn b count >>= (@?= 1)
        , testCase "clones and drops run concurrently" $ do
            names <- forConcurrently [1 .. 24 :: Int] $ \_ ->
              withTestDb cluster $ \db -> do
                withConn db count >>= (@?= 1)
                pure (testDbName db)
            length (nub names) @?= 24
        , testCase "a dropped database is gone" $ do
            db <- createTestDb cluster
            dropTestDb db
            r <- try @SomeException (connectPostgreSQL (testDbConnectionString db))
            case r of
              Left _ -> pure ()
              Right conn -> close conn >> assertFailure "connected to a dropped database"
        , testCase "the template refuses connections" $ do
            db <- createTestDb cluster
            let (_, query) = BS.breakSubstring "?" (testDbConnectionString db)
                templateConn = "postgresql:///test_template" <> query
            r <- try @SomeException (connectPostgreSQL templateConn)
            dropTestDb db
            case r of
              Left _ -> pure ()
              Right conn -> close conn >> assertFailure "connected to the template"
        , testCase "a setup that fails reports its own error" $ do
            r <- try @ErrorCall $
              withCluster defaultConfig{configSetup = const (throwIO (ErrorCall "boom")), configDbPrefix = "broken"} $
                \broken -> withTestDb broken (const (pure ()))
            case r of
              Left (ErrorCall msg) -> msg @?= "boom"
              Right () -> assertFailure "expected the setup's error"
        , testCase "the server runs in UTC" $
            withTestDb cluster $ \db -> withConn db $ \conn -> do
              [Only tz] <- query_ conn "SHOW timezone"
              assertBool ("timezone is " <> tz) (tz == ("UTC" :: String))
        ]
