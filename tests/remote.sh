#!/bin/sh
# The end-to-end check against a deployed server. It makes an invite in the server's database for a team of its own
# ("e2e <time>"), then runs tests/e2e/e2e.tin against the server's URL, including a 55 s wait through its proxy.
#   tests/remote.sh https://your-app.example      asks for the database URL unless TINBOX_DB_URL is set
# The test team and its test users stay in the database.
set -eu
cd "$(dirname "$0")/.."
url=${1:?usage: tests/remote.sh SERVER_URL}
if [ -z "${TINBOX_DB_URL:-}" ]; then
  printf 'Database URL (postgres://...): ' >&2
  stty -echo 2>/dev/null || true
  read -r TINBOX_DB_URL
  stty echo 2>/dev/null || true
  echo >&2
  export TINBOX_DB_URL
fi
mkdir -p bin
./tin build server/main.tin -o bin/tinbox
./tin build tests/e2e/e2e.tin -o bin/e2e
stamp=$(date +%Y%m%d-%H%M%S)
code=$(bin/tinbox admin invite "e2e-$stamp@example.com" --team "e2e $stamp" | awk '/TBI-/ { print $1 }')
if [ -z "$code" ]; then
  echo "remote: no invite was made"
  exit 1
fi
TINBOX_URL=$url TINBOX_INVITE=$code TINBOX_E2E_LONG=${TINBOX_E2E_LONG:-1} bin/e2e
