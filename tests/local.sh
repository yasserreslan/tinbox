#!/bin/sh
# The end-to-end check against a throwaway Postgres (Docker) and MinIO, once with each block store: the local
# directory (downloads through the server) and S3 (presigned downloads, as with R2).
# quay.io and dl.min.io no longer hand MinIO out anonymously, so it is built from the source version the tin
# repository's CI pins (needs Go), unless a MinIO image is already on this machine.
set -eu
cd "$(dirname "$0")/.."
pg=tinbox-test-pg
s3=tinbox-test-minio
pgport=${TINBOX_TEST_PG_PORT:-55433}
s3port=${TINBOX_TEST_S3_PORT:-59001}
minio_version=v0.0.0-20260212201848-7aac2a2c5b7c
minio_bin=${TINBOX_MINIO_BIN:-${XDG_CACHE_HOME:-$HOME/.cache}/tinbox/minio-bin}
s3pid=""
s3data=$(mktemp -d)
cleanup() {
  docker rm -f $pg $s3 >/dev/null 2>&1 || true
  if [ -n "$s3pid" ]; then kill "$s3pid" 2>/dev/null || true; fi
  rm -rf "$s3data"
}
docker rm -f $pg $s3 >/dev/null 2>&1 || true
trap cleanup EXIT INT TERM
docker run -d --name $pg -e POSTGRES_USER=tinbox -e POSTGRES_PASSWORD=tinbox -e POSTGRES_DB=tinbox -p "$pgport:5432" postgres:16-alpine >/dev/null
if [ ! -x "$minio_bin/minio" ] && docker image inspect quay.io/minio/minio:latest >/dev/null 2>&1; then
  docker run -d --name $s3 -e MINIO_ROOT_USER=minio -e MINIO_ROOT_PASSWORD=minio-secret -p "$s3port:9000" quay.io/minio/minio:latest server /data >/dev/null
else
  if [ ! -x "$minio_bin/minio" ]; then
    echo "local: building MinIO $minio_version into $minio_bin"
    GOBIN="$minio_bin" go install "github.com/minio/minio@$minio_version"
  fi
  MINIO_ROOT_USER=minio MINIO_ROOT_PASSWORD=minio-secret "$minio_bin/minio" server "$s3data/data" --address "127.0.0.1:$s3port" --quiet > "$s3data/minio.log" 2>&1 &
  s3pid=$!
fi
i=0
until docker exec $pg psql -q -U tinbox -d tinbox -c 'SELECT 1' >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 150 ] || { echo "local: Postgres did not start"; exit 1; }; sleep 0.2
done
i=0
until curl -fs "http://127.0.0.1:$s3port/minio/health/live" >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 150 ] || { echo "local: MinIO did not start"; exit 1; }; sleep 0.2
done
export TINBOX_DB_URL="postgres://tinbox:tinbox@127.0.0.1:$pgport/tinbox?sslmode=disable"
blocks=$(mktemp -d)
echo "== end to end: directory store"
TINBOX_STORE=dir TINBOX_STORE_DIR=$blocks tests/e2e.sh
docker exec $pg psql -q -U tinbox -d tinbox -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' >/dev/null 2>&1
echo "== end to end: S3 store (MinIO), presigned downloads"
TINBOX_STORE=s3 TINBOX_S3_ENDPOINT="http://127.0.0.1:$s3port" TINBOX_S3_REGION=us-east-1 TINBOX_S3_BUCKET=tinbox \
  TINBOX_S3_ACCESS_KEY=minio TINBOX_S3_SECRET_KEY=minio-secret tests/e2e.sh
rm -rf "$blocks"
