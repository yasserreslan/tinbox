#!/bin/sh
# Builds everything with the pinned Tin and runs the unit tests: the server for this machine and for Linux arm64 and
# x86-64, and the end-to-end client. tests/local.sh runs the end-to-end check on top (it needs Docker).
set -eu
cd "$(dirname "$0")/.."
for p in proto server/config server/db server/store server/auth server/tree server/api; do
  echo "== $p"
  ./tin test "./$p"
done
mkdir -p bin/linux-arm64 bin/linux-amd64
echo "== build"
./tin build server/main.tin -o bin/tinbox
./tin build tests/e2e/e2e.tin -o bin/e2e
./tin build --target linux-arm64 server/main.tin -o bin/linux-arm64/tinbox
./tin build --target linux-amd64 server/main.tin -o bin/linux-amd64/tinbox
bin/tinbox version
