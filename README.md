# postgres-template-db

Throwaway PostgreSQL databases for test suites, one per test, cloned from a
migrated template.

Running `initdb` and your migrations for every test costs seconds each. This
library starts one throwaway cluster, runs your setup once into a template
database, and gives each test its own clone made with
`CREATE DATABASE … TEMPLATE`, which takes tens of milliseconds. Each test still
gets its own database; only the server process and the migrated schema are
shared. Clones and drops may run concurrently.

```haskell
import Database.PostgreSQL.Simple
import Database.PostgreSQL.TemplateDb
import Test.Tasty
import Test.Tasty.HUnit

migrate :: Connection -> IO ()
migrate conn = () <$ execute_ conn "CREATE TABLE item (id serial PRIMARY KEY, name text)"

main :: IO ()
main =
  withCluster defaultConfig{configSetup = migrate} $ \cluster ->
    defaultMain $
      testCase "starts empty" $
        withTestDb cluster $ \db -> do
          conn <- connectPostgreSQL (testDbConnectionString db)
          [Only n] <- query_ conn "SELECT count(*)::int FROM item"
          close conn
          n @?= (0 :: Int)
```

The cluster starts on the first `createTestDb` or `withTestDb`, and
`withCluster` stops it and deletes its files at the end. It needs `initdb` and
`pg_ctl` on the `PATH`.

## What the cluster is set up for

- **Safe clones.** Autovacuum is off and the template refuses connections, so
  no session can be connected to the template when a clone starts. A connected
  session makes `CREATE DATABASE … TEMPLATE` fail with "source database is
  being accessed by other users".
- **Speed.** `fsync`, `synchronous_commit` and `full_page_writes` are off,
  Postgres's documented non-durable settings for data nobody needs after a
  crash.
- **UTC.** The server runs in UTC, so `NOW()` agrees with `getCurrentTime`
  about the date. Override `timezone` in `configServerSettings` to test
  zone-dependent SQL.
- **Short socket paths.** The Unix socket goes under `/tmp`
  (`configSocketParent`), because a temporary directory on macOS can push the
  socket path past Postgres's 103-byte limit.
- **UTF8**, whatever the caller's locale.
- **A failed setup cleans up.** If the setup throws, the cluster is stopped and
  deleted, and the setup's exception is rethrown.

## Why not tmp-postgres?

[tmp-postgres](https://hackage.haskell.org/package/tmp-postgres) starts a
server per test, from an `initdb` cache or a copied data directory. This
package keeps one server and clones a database per test instead, which is
cheaper when tests run concurrently. tmp-postgres has had no Hackage release
since 2019 and no merge since 2023, and its issue tracker reports it held out
of Stackage and failing in nixpkgs. A fix for starting it with recent
PostgreSQL versions
([#291](https://github.com/jfischoff/tmp-postgres/pull/291)) is waiting for
review.

## Licence

BSD-3-Clause. Written at UpTrust.
