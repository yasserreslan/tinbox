#!/bin/sh
# End-to-end check: builds the server and the test client with the pinned Tin, starts the server against the
# database and store the TINBOX_* variables name, makes an invite and runs tests/e2e/e2e.tin against it.
#   TINBOX_DB_URL=postgres://tinbox:tinbox@127.0.0.1:5432/tinbox?sslmode=disable TINBOX_STORE=dir tests/e2e.sh
# tests/local.sh starts a Postgres and a MinIO in Docker and runs this against both stores.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
port=${TINBOX_E2E_PORT:-18080}
mkdir -p bin
./tin build server/main.tin -o bin/tinbox
./tin build tests/e2e/e2e.tin -o bin/e2e
export TINBOX_LISTEN=127.0.0.1:$port
export TINBOX_PUBLIC_URL=http://127.0.0.1:$port
log=$(mktemp)
bin/tinbox migrate
code=$(bin/tinbox admin invite "e2e-$$@example.com" --team "e2e $$" | awk '/TBI-/ { print $1 }')
bin/tinbox run > "$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true' EXIT INT TERM
i=0
until curl -fs "http://127.0.0.1:$port/healthz" > /dev/null 2>&1; do
  i=$((i + 1))
  if [ $i -gt 100 ]; then echo "e2e: the server did not start"; cat "$log"; exit 1; fi
  sleep 0.1
done
status=0
TINBOX_URL=http://127.0.0.1:$port TINBOX_INVITE=$code bin/e2e || status=$?
if [ $status -ne 0 ]; then echo "--- server log"; tail -50 "$log"; fi
bin/tinbox check || status=1
exit $status
