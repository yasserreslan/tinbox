#!/bin/sh
# The end-to-end check against a throwaway Postgres and MinIO in Docker, once with each block store: the local
# directory (downloads through the server) and S3 (presigned downloads, as with R2).
set -eu
cd "$(dirname "$0")/.."
pg=tinbox-test-pg
s3=tinbox-test-minio
pgport=${TINBOX_TEST_PG_PORT:-55433}
s3port=${TINBOX_TEST_S3_PORT:-59001}
docker rm -f $pg $s3 >/dev/null 2>&1 || true
docker run -d --name $pg -e POSTGRES_USER=tinbox -e POSTGRES_PASSWORD=tinbox -e POSTGRES_DB=tinbox -p "$pgport:5432" postgres:16-alpine >/dev/null
docker run -d --name $s3 -e MINIO_ROOT_USER=minio -e MINIO_ROOT_PASSWORD=minio-secret -p "$s3port:9000" quay.io/minio/minio:latest server /data >/dev/null
trap 'docker rm -f $pg $s3 >/dev/null 2>&1 || true' EXIT INT TERM
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
