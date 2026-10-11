# Running tinbox on Aiven Runtime

Aiven Runtime builds this repository's `Dockerfile` and runs it next to the Aiven Postgres service. The server
migrates its database when it starts, so a new database needs no setup.

## What it needs

| setting | value |
|---|---|
| `DATABASE_URL` | the Postgres service's URI. Connecting the service to the app sets it; on a plan without integrations, add it as a secret variable yourself |
| `TINBOX_S3_ENDPOINT` | `https://ACCOUNT_ID.r2.cloudflarestorage.com` |
| `TINBOX_S3_BUCKET` | `tinbox` (made at start when missing, if the token may make buckets) |
| `TINBOX_S3_ACCESS_KEY` | the R2 token's access key id |
| `TINBOX_S3_SECRET_KEY` | the R2 token's secret access key (a secret variable) |
| `TINBOX_DB_MAX_TOTAL` | `15` on Aiven's free plan, which allows 20 connections |
| `TINBOX_PUBLIC_URL` | the app's https URL (optional; used only when downloads go through the server) |

The image listens on 8080 (`PORT` overrides it). Health check: `GET /healthz`; readiness: `GET /readyz`.

To try it before R2 is set up, `TINBOX_STORE=dir` keeps blocks on the container's disk. They are lost on every
redeploy, so use it only to test.

## Steps

1. **R2.** In the Cloudflare dashboard, R2: make a bucket named `tinbox` (or let tinbox make it), then *Manage API
   tokens*, a token with *Object Read & Write* on that bucket. Keep the access key id, the secret and the S3 endpoint.
2. **Runtime app.** In the Aiven console, in the project that holds the `tinbox` Postgres service: Runtime, new app,
   from GitHub. Authorize Aiven's GitHub app for `yasserreslan/tinbox`, pick branch `main`, Dockerfile `./Dockerfile`,
   build path `.`, and one port: name `http`, port `8080`, protocol HTTP.
3. **Database.** Connect the `tinbox` Postgres service to the app, so `DATABASE_URL` is set. If the plan refuses the
   integration, copy the service's URI into a secret variable named `DATABASE_URL`.
4. **Variables.** Add the R2 settings above, and `TINBOX_DB_MAX_TOTAL=15` on the free plan.
5. **Deploy.** The log says `tinbox starting` once it serves; `migrated applied=1` the first time.
6. **Your first invite.** Runtime has no shell, so make it from your Mac with the same database:

   ```sh
   ./tin build server/main.tin -o bin/tinbox
   TINBOX_DB_URL='postgres://…' bin/tinbox admin invite you@example.com --team Home
   ```

   `tinbox admin` needs only the database. Enter the code in the Mac app with the app's URL.

Runtime redeploys only when you ask: after a push, redeploy from the console.

## Elsewhere

The same image runs on any container host or a Linux server:

```sh
docker build -t tinbox .
docker run -p 8080:8080 -e DATABASE_URL='postgres://…' -e TINBOX_S3_ENDPOINT=… -e TINBOX_S3_ACCESS_KEY=… -e TINBOX_S3_SECRET_KEY=… tinbox
```

Or build the binary for the server (`./tin build --target linux-amd64 server/main.tin -o tinbox`, or `linux-arm64`)
and run `tinbox run` under systemd with a config file (`deploy/tinbox.conf.example`). Set `tls.cert` and `tls.key`
when no proxy terminates TLS in front of it.
