#!/usr/bin/env bash
# Build, test, cabal check and sdist every package in this tree, inside its flake's dev shell.
set -uo pipefail
unset GHCRTS
echo "box: $(hostname), $(nproc) cores"
rm -rf sdist sdist-build
[ -d .git ] || { git init -q; git add -A; git -c user.name=ci -c user.email=ci@localhost commit -qm tree; }
nix develop --accept-flake-config -c bash -s <<'INNER'
set -uo pipefail
rc=0
step() { echo "=== $*"; "$@"; r=$?; echo "RESULT [$*] exit=$r"; [ $r = 0 ] || rc=1; return $r; }
ghc --version; cabal --version
# A fresh Hackage index: a truncated one ("truncated tar archive") fails every solve.
h="${XDG_CACHE_HOME:-$HOME/.cache}/cabal/packages/hackage.haskell.org"; rm -f "$h"/01-index* "$h"/*.json
step cabal update -v0
step cabal build all --enable-tests -j
step cabal test all --test-show-details=direct
for d in $(dirname $(git ls-files '*.cabal')); do
  case $d in *-example) continue ;; esac
  (cd "$d" && echo "=== cabal check in $d" && cabal check; echo "RESULT [cabal check $d] exit=$?")
done
# Directories, not names: a one-package repo's name also names its library.
pkgs=$(for f in $(git ls-files '*.cabal'); do d=$(dirname "$f"); echo "./$d"; done)
step cabal sdist $pkgs -o sdist
ls -l sdist
# Build and test from the sdists alone, to catch files missing from them.
rm -rf sdist-build && mkdir sdist-build && for t in sdist/*.tar.gz; do tar -xzf "$t" -C sdist-build; done
case " $(ls sdist-build) " in *cascading-cache-example*) rm -rf sdist-build/cascading-cache-example-* ;; esac
(cd sdist-build && printf 'packages: */*.cabal\ntests: true\n' > cabal.project && step cabal build all --enable-tests -j && step cabal test all) || rc=1
# Does tmp-postgres, the established library, still build here? (Informational.)
mkdir -p /tmp/tmp-postgres-check-$$ && (cd /tmp/tmp-postgres-check-$$ && cabal install --lib tmp-postgres --package-env ./env -j; echo "RESULT [tmp-postgres build, informational] exit=$?")
echo "FINAL rc=$rc"
exit $rc
INNER
