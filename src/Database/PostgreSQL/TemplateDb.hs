{-# LANGUAGE LambdaCase #-}

{- | Throwaway PostgreSQL databases for tests, cloned from a template.

A test suite usually wants a fresh, fully migrated database per test. Running
@initdb@ and the migrations for every test costs seconds each. This module
starts one throwaway cluster per 'Cluster', runs your setup (migrations,
fixtures) once into a template database, and gives each test its own clone made
with @CREATE DATABASE … TEMPLATE@, which takes tens of milliseconds.

Tests stay isolated: each one gets its own database. Only the server process and
the migrated schema are shared. Clones and drops may run concurrently.

@
main :: IO ()
main =
  withCluster defaultConfig{configSetup = runMigrations} $ \\cluster ->
    defaultMain (tests cluster)

aTest :: Cluster -> IO ()
aTest cluster =
  withTestDb cluster $ \\db ->
    bracket (connectPostgreSQL (testDbConnectionString db)) close $ \\conn ->
      ...
@

The cluster needs @initdb@ and @pg_ctl@ on the @PATH@.
-}
module Database.PostgreSQL.TemplateDb (
  -- * Configuration
  Config (..),
  defaultConfig,
  defaultServerSettings,

  -- * Clusters
  Cluster,
  newCluster,
  stopCluster,
  withCluster,

  -- * Test databases
  TestDb,
  testDbName,
  testDbConnectionString,
  createTestDb,
  dropTestDb,
  withTestDb,
) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (SomeException, bracket, onException, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.String (fromString)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL, execute_)
import System.Directory qualified as Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Process qualified as Process

-- | How to start the cluster and build its template.
data Config = Config
  { configSetup :: Connection -> IO ()
  -- ^ Runs once, connected to the template database: migrations, fixtures.
  , configDbPrefix :: String
  -- ^ Names the template (@\<prefix\>_template@) and the clones (@\<prefix\>_1@, ...).
  , configMaxConnections :: Int
  -- ^ The server's @max_connections@. Raise it for many concurrent tests.
  , configServerSettings :: [(String, String)]
  {- ^ Extra @-c name=value@ server settings, after the defaults, so they win.
  The defaults are 'defaultServerSettings'.
  -}
  , configSocketParent :: FilePath
  {- ^ Where the socket directory goes. Postgres caps a Unix socket path at 103
  bytes, and a temporary directory on macOS is long enough to break it, so the
  default is @/tmp@. The data directory goes under the system temporary
  directory, which has no such limit.
  -}
  }

-- | No setup, prefix @test@, 200 connections, no extra settings, sockets under @/tmp@.
defaultConfig :: Config
defaultConfig =
  Config
    { configSetup = const (pure ())
    , configDbPrefix = "test"
    , configMaxConnections = 200
    , configServerSettings = []
    , configSocketParent = "/tmp"
    }

{- | The settings every cluster starts with.

* @autovacuum=off@ is what makes the template safe to clone from. An autovacuum
  worker ignores @datallowconn@, and a worker connected to the template at
  clone time makes @CREATE DATABASE … TEMPLATE@ fail with "source database is
  being accessed by other users".
* @fsync@, @synchronous_commit@ and @full_page_writes@ off are Postgres's
  documented non-durable settings, for a cluster nobody needs after a crash.
  Without them every clone, drop and commit waits on the disk, and concurrent
  tests queue behind each other's waits.
* @timezone=UTC@, so @NOW()@ agrees with 'Data.Time.Clock.getCurrentTime' about
  the date whatever the host's zone. Override it to test zone-dependent SQL.
* @client_min_messages=ERROR@ keeps notices out of test output.
-}
defaultServerSettings :: [(String, String)]
defaultServerSettings =
  [ ("client_min_messages", "ERROR")
  , ("autovacuum", "off")
  , ("timezone", "UTC")
  , ("fsync", "off")
  , ("synchronous_commit", "off")
  , ("full_page_writes", "off")
  ]

data Running = Running
  { runningSocketDir :: FilePath
  , runningTmpDir :: FilePath
  }

{- | A cluster, started lazily by the first 'createTestDb' and stopped by
'stopCluster'.
-}
data Cluster = Cluster
  { clusterConfig :: Config
  , clusterState :: MVar (Maybe Running)
  , clusterCounter :: IORef Int
  }

-- | A database cloned from the template.
data TestDb = TestDb
  { testDbName :: String
  -- ^ The database's name.
  , testDbSocketDir :: FilePath
  }

-- | A libpq connection string for the database, for 'connectPostgreSQL' or a pool.
testDbConnectionString :: TestDb -> ByteString
testDbConnectionString db = connString (testDbSocketDir db) (testDbName db)

{- | A cluster that starts on first use. Nothing runs until the first
'createTestDb'.
-}
newCluster :: Config -> IO Cluster
newCluster cfg = Cluster cfg <$> newMVar Nothing <*> newIORef 0

{- | Stops the server and deletes its directories. A no-op if it never started.
A later 'createTestDb' starts a new one.
-}
stopCluster :: Cluster -> IO ()
stopCluster cluster =
  modifyMVar_ (clusterState cluster) $ \case
    Nothing -> pure Nothing
    Just running -> removeRunning running >> pure Nothing

-- | 'newCluster', then 'stopCluster' at the end.
withCluster :: Config -> (Cluster -> IO a) -> IO a
withCluster cfg = bracket (newCluster cfg) stopCluster

-- | Clones a fresh database from the template, starting the cluster if needed.
createTestDb :: Cluster -> IO TestDb
createTestDb cluster = do
  running <- ensureRunning cluster
  n <- atomicModifyIORef' (clusterCounter cluster) (\i -> (i + 1, i + 1))
  let prefix = configDbPrefix (clusterConfig cluster)
      name = prefix <> "_" <> show n
      socketDir = runningSocketDir running
  withAdminConn socketDir $ \conn ->
    void . execute_ conn . fromString $
      "CREATE DATABASE " <> quoteIdent name <> " TEMPLATE " <> quoteIdent (templateName prefix)
  pure TestDb{testDbName = name, testDbSocketDir = socketDir}

-- | Drops a database from 'createTestDb'. @FORCE@ closes any connection left open.
dropTestDb :: TestDb -> IO ()
dropTestDb db =
  withAdminConn (testDbSocketDir db) $ \conn ->
    void . execute_ conn . fromString $
      "DROP DATABASE IF EXISTS " <> quoteIdent (testDbName db) <> " WITH (FORCE)"

-- | 'createTestDb', then 'dropTestDb' at the end.
withTestDb :: Cluster -> (TestDb -> IO a) -> IO a
withTestDb cluster = bracket (createTestDb cluster) dropTestDb

{- | A template that fails to build takes its cluster down with it. Left
running, the cluster would be orphaned and keep its shared memory segment, and
macOS allows few of those. A failure of that cleanup is dropped, so the caller
sees why the template failed.
-}
ensureRunning :: Cluster -> IO Running
ensureRunning cluster =
  modifyMVar (clusterState cluster) $ \case
    Just running -> pure (Just running, running)
    Nothing -> do
      running <- start (clusterConfig cluster)
      buildTemplate (clusterConfig cluster) running
        `onException` try @SomeException (removeRunning running)
      pure (Just running, running)

start :: Config -> IO Running
start cfg = do
  tmpParent <- getCanonicalTemporaryDirectory
  tmp <- createTempDirectory tmpParent "postgres-template-db"
  socketDir <- createTempDirectory (configSocketParent cfg) "pgt"
  let dataDir = tmp </> "data"
      settings =
        defaultServerSettings
          <> [("max_connections", show (configMaxConnections cfg))]
          <> configServerSettings cfg
      options =
        "-h '' -k " <> socketDir <> concatMap (\(k, v) -> " -c " <> k <> "=" <> v) settings
  -- UTF8 whatever the caller's locale: with none set, initdb picks SQL_ASCII.
  quietly "initdb" ["-D", dataDir, "--encoding=UTF8", "--auth=trust", "--no-sync", "--no-instructions"]
  quietly "pg_ctl" ["-D", dataDir, "-l", tmp </> "server.log", "-o", options, "-w", "start"]
    `onException` try @SomeException (removeDirs tmp socketDir)
  pure Running{runningSocketDir = socketDir, runningTmpDir = tmp}

buildTemplate :: Config -> Running -> IO ()
buildTemplate cfg running = do
  let socketDir = runningSocketDir running
      template = templateName (configDbPrefix cfg)
  withAdminConn socketDir $ \conn ->
    void . execute_ conn . fromString $ "CREATE DATABASE " <> quoteIdent template
  bracket (connectPostgreSQL (connString socketDir template)) close (configSetup cfg)
  -- With autovacuum off (see 'defaultServerSettings'), this keeps every other
  -- session off the template, so no clone can race one. A database that
  -- refuses connections can still be a template, as template0 is.
  withAdminConn socketDir $ \conn ->
    void . execute_ conn . fromString $
      "ALTER DATABASE " <> quoteIdent template <> " WITH ALLOW_CONNECTIONS false"

removeRunning :: Running -> IO ()
removeRunning running = do
  let socketDir = runningSocketDir running
      tmp = runningTmpDir running
  quietly
    "pg_ctl"
    ["-D", tmp </> "data", "-o", "-h '' -k " <> socketDir, "-w", "stop", "-m", "immediate"]
  removeDirs tmp socketDir

{- | Runs a command and keeps its output out of the test run's, unless it fails:
then the output is in the exception.
-}
quietly :: FilePath -> [String] -> IO ()
quietly cmd args = do
  (code, out, err) <- Process.readProcessWithExitCode cmd args ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure n ->
      ioError . userError $
        unwords (cmd : args) <> " failed with exit code " <> show n <> ":\n" <> out <> err

removeDirs :: FilePath -> FilePath -> IO ()
removeDirs tmp socketDir = do
  Directory.removeDirectoryRecursive tmp
  Directory.removeDirectoryRecursive socketDir

templateName :: String -> String
templateName prefix = prefix <> "_template"

connString :: FilePath -> String -> ByteString
connString socketDir name = fromString $ "postgresql:///" <> name <> "?host=" <> socketDir

withAdminConn :: FilePath -> (Connection -> IO a) -> IO a
withAdminConn socketDir = bracket (connectPostgreSQL (connString socketDir "postgres")) close

quoteIdent :: String -> String
quoteIdent ident = "\"" <> concatMap (\c -> if c == '"' then "\"\"" else [c]) ident <> "\""
