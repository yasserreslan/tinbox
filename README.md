# tinbox

One shared folder per team, synced to every member's Macs, like iCloud Drive. This repository holds the server
(Linux) and, next, the Mac app. Everything is written in [Tin](https://github.com/yasserreslan/tin) and built with the
release pinned in `TIN_VERSION`.

- The design and the protocol: [design/backend.md](design/backend.md)
- Running it on Aiven Runtime or a server: [deploy/RUNTIME.md](deploy/RUNTIME.md)

## Build and test

```sh
./tin build server/main.tin -o bin/tinbox    # the first run installs the pinned Tin into ~/.cache/tinbox/tin
scripts/test.sh                              # unit tests, and builds for this machine and Linux
tests/local.sh                               # end to end against Postgres and MinIO in Docker
```

## Run it locally

```sh
docker run -d --name tinbox-pg -e POSTGRES_USER=tinbox -e POSTGRES_PASSWORD=tinbox -p 5432:5432 postgres:16-alpine
export TINBOX_DB_URL='postgres://tinbox:tinbox@127.0.0.1:5432/tinbox?sslmode=disable' TINBOX_STORE=dir
bin/tinbox admin invite you@example.com --team Home   # prints a one-use code
bin/tinbox run                                        # migrates, then serves on :8080
```

## Moving to a newer Tin

```sh
scripts/tin-update.sh            # the latest release, or name one: scripts/tin-update.sh 0.4.262
```

It builds and tests everything with the new release and changes `TIN_VERSION` only if all of it passes. Nothing
updates the pin on its own. Commit the bump by itself.
