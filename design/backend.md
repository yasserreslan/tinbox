# tinbox backend

tinbox keeps one shared folder per team in sync across every member's Macs, like iCloud Drive. Anyone on a team can
change any file at any time. This document is the server's reference: its decisions, data, protocol and failure
handling. The code follows it; a change to a rule here is made here first, in the same commit.

## 1. Decisions

1. **One team, one folder.** A team's folder is one tree, with one journal and one lock. Members read and change
   every file; owners also invite, remove members and rewind the folder.
2. **Its own repository, on a pinned Tin release.** `TIN_VERSION` names one release and every build uses exactly it
   (section 9).
3. **File bytes in object storage, everything that changes in Postgres.** The bucket (Cloudflare R2 in production)
   holds immutable blocks named by their hash. The tree, journal, versions, accounts and the lock are rows changed
   in transactions.
4. **Blocks belong to a team.** A block lives at `teams/<team id>/blocks/<sha256>`. Keys shared across teams would
   let one team learn whether another holds a file, so equal content in two teams is stored twice.
5. **Macs sign their requests; nobody has a password.** Each Mac has its own ed25519 key, so a lost Mac is revoked on
   its own.
6. **Uploads go through the server; downloads go straight to the bucket.** The server hashes every uploaded block
   before it counts, so a broken client cannot store bytes under the wrong name. Downloads use presigned URLs
   (R2 charges nothing for egress), and the Mac checks each block's hash.
7. **The server never trusts a client's picture of the tree.** Every change is a compare-and-swap against what the
   client last saw, every folder carries a Merkle hash a client can check, and nothing is really deleted for
   `history.days` (30).
8. **The server runs on Linux.** It builds and its unit tests run on macOS for development.

## 2. Layout

```text
TIN_VERSION             the pinned Tin release
tin                     runs that release, installing it first if needed
proto/                  the hash layout, the signing text and the JSON shapes, shared with clients
server/main.tin         the tinbox command
server/config/          configuration: file, environment, file: secrets, DATABASE_URL, PORT
server/db/              migrations (embedded) and the migrator
server/auth/            signatures and nonces; users, devices, teams, invites, device links
server/store/           the block store: S3-compatible bucket or local directory
server/tree/            nodes, Merkle hashes, commits, journal, history, blocks, purge, sweep, check
server/api/             the HTTP routes
tests/e2e/              an end-to-end client that signs requests as a Mac does
tests/e2e.sh            runs it against a server it starts; tests/local.sh with Postgres and MinIO in Docker
scripts/test.sh         unit tests and builds; scripts/tin-update.sh moves the Tin pin
deploy/                 how to run it (Aiven Runtime, a plain server)
```

## 3. Configuration

An optional file of `key = value` lines (`--config FILE` or `$TINBOX_CONFIG`), then the environment: `TINBOX_` and
the key in upper case with dots as underscores (`s3.secret_key` is `TINBOX_S3_SECRET_KEY`). A value `file:PATH` is
read from that file. `DATABASE_URL` fills `db.url` when nothing else sets it, and `PORT` fills `listen`.

| key | default | meaning |
|---|---|---|
| `listen` | `:8080` | address to serve on |
| `public_url` | | the server's URL, for block URLs when downloads go through the server |
| `tls.cert`, `tls.key` | | serve TLS 1.3 with these PEM files (otherwise plain HTTP behind a proxy) |
| `db.url` | | `postgres://user:password@host:port/name?sslmode=require` |
| `db.addr`, `db.user`, `db.password`, `db.name`, `db.sslmode` | `127.0.0.1:5432`, `tinbox`, , `tinbox`, | the same, one by one |
| `db.max_total` | `10` | connections for the whole process |
| `store` | `s3` | `s3`, or `dir` (local disk, for development) |
| `store.dir` | `./data/blocks` | the directory store's root |
| `s3.endpoint` | | `https://ACCOUNT_ID.r2.cloudflarestorage.com` |
| `s3.region` | `auto` | R2's region is `auto` |
| `s3.bucket` | `tinbox` | made at start when missing and the keys may make it |
| `s3.access_key`, `s3.secret_key` | | the bucket's keys |
| `s3.path_style` | `true` | address the bucket in the path |
| `downloads` | `presigned` for s3, else `server` | where clients download blocks |
| `secrets.nonce` | | the nonce secret; when empty the server makes one and keeps it in the database |
| `history.days` | `30` | how long versions, trash and the journal are kept |
| `migrate` | `true` | `tinbox run` applies migrations first |
| `jobs` | `true` | run the background jobs in this process |
| `log.level` | `info` | `debug`, `info`, `warn` or `error` |

`tinbox migrate` and `tinbox admin` need only the database settings.

## 4. Commands

```text
tinbox run                                     serve; migrates first; the jobs run on core 0
tinbox migrate                                 apply pending migrations
tinbox admin invite EMAIL --team NAME [--role owner|member]
                                               a one-use invite; the team is made when none has that name
tinbox admin new-epoch                         after restoring Postgres from a backup (section 8)
tinbox check [--deep]                          blocks against the store, folder hashes against their children
tinbox sweep                                   the purge and the sweep, once
tinbox version
```

## 5. Data

The schema is `server/db/migrations/0001_init.sql`. In short:

- `users`, `devices` (ed25519 public key in base64), `teams`, `members` (`owner` or `member`), `invites` and
  `device_links` (only the SHA-256 of each code is stored), `audit_log`, and `settings` (the nonce secret).
- `nodes` is the tree as parent-pointer rows. A node has a server-assigned id, `rev` (the seq of its last content
  change), `place_rev` (the seq of its last move or rename) and `deleted_seq` (set while it is in the trash).
  Names are unique per folder ignoring case, because macOS volumes ignore case by default.
- `versions` and `version_blocks` keep every content a file had, with its blocks in order.
- `journal` is append-only: one row per change holding the node's state after it, with the client's `op_id`.
- `blocks` is what the bucket holds for each team; `lost` marks one `tinbox check` found missing or damaged.
- `teams` holds `head_seq` (the last journal row), `floor_seq` (journal rows at or below it may be purged),
  `root_hash`, `epoch`, and `used_bytes` against `quota_bytes` (0: no quota).

## 6. Protocol

JSON over HTTP(S). Errors are a status and `{"error": {"code": ..., "message": ...}, "nonce": ...}` with code
`BadRequest` (400), `Unauthorized` or `NonceExpired` (401, with a fresh nonce), `Forbidden` (403), `NotFound` (404,
also for a team the caller is not in), `Conflict` (409), `TooLarge` (413), `BadBlock` (422), `QuotaExceeded` (507),
`Timeout` (504) or `Internal` (500).

### Signing

```text
Tinbox-Signature: <device id> <nonce> <base64 of the 64-byte ed25519 signature>
signed text = "tinbox v1 " + method + " " + target + "\n" + nonce + "\n" + hex(SHA-256(body)) + "\n"
```

`target` is the path and, when there is one, `?` and the query. A nonce comes from `GET /v1/nonce` or any 401
answer; it is the server's time, 16 random bytes and an HMAC, good for 60 seconds, so a Mac's clock never matters.
A key not registered yet signs as device `new` and presents its public key in the body.

### Hashes

```text
block      = 4 MiB of the file; the last one may be shorter
block hash = SHA-256(block), lowercase hex
file hash  = SHA-256(raw block hash 1 ‖ … ‖ raw block hash n)      an empty file has no blocks
dir hash   = SHA-256("tinbox dir v1\n" ‖ for each live child in byte order of name: name ‖ 0x00 ‖ kind ‖ raw child hash)
kind       = 1 folder, 2 file, 3 executable file
```

The server computes a file's hash and size from its blocks; it never takes the client's. `proto/proto.tin` is the
reference implementation.

### Requests

| request | who | does |
|---|---|---|
| `GET /healthz`, `GET /readyz` | anyone | liveness; readiness checks the schema |
| `GET /v1/nonce` | anyone | a nonce |
| `POST /v1/invites/accept` `{code, name, device_name, public_key}` | new key | joins the team, makes the account if needed, registers the Mac |
| `POST /v1/links` `{device_name, public_key}` | new key | a code (`ABCD-EFGH`, 10 minutes) to approve on a signed-in Mac |
| `POST /v1/links/approve` `{code}` | your Mac | approves it for your account |
| `POST /v1/links/claim` `{code, public_key}` | new key | turns the approved code into a device |
| `GET /v1/me` | any Mac | you, your Macs and your teams |
| `DELETE /v1/devices/{id}` | your Mac | revokes one of your Macs |
| `POST /v1/teams` `{name}` | any Mac | a new team, with you as owner |
| `GET /v1/teams/{t}/members` | member | the members |
| `DELETE /v1/teams/{t}/members/{user}` | owner | removes a member (never the last owner) |
| `POST /v1/teams/{t}/invites` `{email, role}` | owner | a one-use code, 7 days |
| `GET /v1/teams/{t}/head` | member | `{seq, epoch, root, root_hash, floor}` |
| `GET /v1/teams/{t}/delta?cursor=N[&limit=L]` | member | journal rows after N (at most 1000), or `reset` |
| `GET /v1/teams/{t}/wait?cursor=N` | member | the head, as soon as it is not N, or after 55 s |
| `GET /v1/teams/{t}/snapshot?after=ID[&limit=L]` | member | live nodes in id order (at most 5000), with the seq they start from |
| `GET /v1/teams/{t}/nodes/{id}` | member | one node, with its blocks when it is a file |
| `GET /v1/teams/{t}/nodes/{id}/children` | member | a folder's live children, for the Merkle walk |
| `GET /v1/teams/{t}/nodes/{id}/versions` | member | a file's versions |
| `POST /v1/teams/{t}/nodes/{id}/restore` `{rev}` | member | back from the trash, and for a file `rev` > 0 that version's content |
| `GET /v1/teams/{t}/trash` | member | what was deleted, newest first |
| `POST /v1/teams/{t}/rewind` `{seq}` | owner | the whole folder as it was at seq, as new changes |
| `POST /v1/teams/{t}/blocks/missing` `{hashes}` | member | which the team lacks (lost blocks count) |
| `PUT /v1/teams/{t}/blocks/{sha256}` raw bytes | member | one block of at most 4 MiB, hashed before it is stored |
| `POST /v1/teams/{t}/blocks/urls` `{hashes}` | member | a download URL per block, valid 15 minutes |
| `GET /v1/teams/{t}/blocks/{sha256}` | member | a block through the server |
| `POST /v1/teams/{t}/commit` `{ops, confirmed}` | member | a batch of changes (section 7) |

A new Mac reads the head seq S, pages through `snapshot`, then applies `delta` from S: changes made while it paged
arrive in the delta, and applying them again is harmless. After that it applies `delta` and waits on `wait`.

## 7. Commits

```json
{"ops": [
  {"op_id": "5b1e…", "op": "mkdir",  "parent": 1, "name": "Photos"},
  {"op_id": "9c02…", "op": "create", "parent_op": "5b1e…", "name": "beach.jpg", "kind": 2, "blocks": ["9f3a…"], "mtime_ns": 1791700000000000000},
  {"op_id": "e7a4…", "op": "modify", "node": 57, "base_rev": 112, "blocks": ["c81b…"]},
  {"op_id": "0d6f…", "op": "move",   "node": 57, "base_place_rev": 98, "parent": 12, "name": "notes-old.md"},
  {"op_id": "a3c9…", "op": "delete", "node": 57, "base_rev": 112},
  {"op_id": "71fe…", "op": "delete", "node": 12, "base_hash": "c41d…"}
], "confirmed": false}
```

Under the team's advisory lock, in one transaction, each change in order:

1. If its `op_id` is already in the journal, it answers with that result (`replayed`), so a retry changes nothing.
2. It checks the base: `base_rev` for content, `base_place_rev` for a move, and for a folder delete the folder's
   Merkle hash, so a delete fails when anything inside changed since the client looked.
3. It checks blocks (every one must be in the team), the name (valid, free in the folder ignoring case) and, for a
   folder's move, that the target is not inside it.
4. It applies the change, adds a version for content, and appends a journal row with the next seq. Deleting a
   folder writes a row for everything inside it too.

Then every folder touched and its ancestors get their hash recomputed, deepest first, and the team's head and root
hash are written. One result per change: `ok`, `conflict` (with `current`, the node now), `missing_blocks` (with
`missing`), `name_taken`, `not_found`, `invalid` or `confirm_required`.

**The delete guard.** A batch deleting more than 500 files, or more than a quarter of the folder once it deletes
more than 50, answers `confirm_required` for its deletes unless it carries `"confirmed": true`.

| situation | result |
|---|---|
| two Macs edit a file | the first wins; the second gets `conflict` and keeps its version as a conflicted copy |
| one deletes a file, another edits it | edits win: the delete gets `conflict` |
| one deletes a folder, another adds inside it | the folder's hash changed: the delete gets `conflict` |
| one moves a file, another edits it | both apply (`place_rev` and `rev` are separate) |
| two Macs create the same name | the second gets `name_taken` |

## 8. When things break

| what breaks | what happens |
|---|---|
| a commit's answer is lost | the Mac sends the same batch; each `op_id` answers its first result |
| a crash after uploading blocks, before the commit | the blocks have rows but no version: the sweep removes them after a day |
| a Mac's local state is lost | it rescans, takes a snapshot, compares by hash and merges without deleting |
| a buggy client deletes or overwrites | versions and the trash bring it back; an owner can rewind the folder |
| an upload's bytes do not match its hash | `BadBlock`, nothing stored |
| a block is missing or damaged in the bucket | `tinbox check` marks it lost; the next Mac that has it is asked for it again |
| Postgres is restored from a backup | `tinbox admin new-epoch`: Macs see a new epoch, stop trusting their merge base and merge without deleting |

**Background jobs** (core 0, an hour apart, starting a minute after the server): every hour the sweep removes up
to 500 blocks per team that no version uses and that are older than a day (each object, then its row, under the
team lock). Once a day the purge runs first: journal rows older than `history.days` go (keeping each node's last
row, so any seq from the new floor on can still be rewound to), then versions nothing uses and the trash. Then the
check runs (reading every block once a week).

## 9. Tin

`./tin` runs the release in `TIN_VERSION`, installing it with that release's checksum-verified `install.sh` into
`~/.cache/tinbox/tin` when missing, so it never touches another Tin. Releases ship `packages/`, so `anvil`,
`postgres`, `s3` and `seal` come from the pinned release. `scripts/tin-update.sh [VERSION]` moves the pin only when
everything builds and passes; commit the bump on its own.

Gaps this code works around: Postgres `LISTEN/NOTIFY` is missing from Tin's client, so `wait` polls the head every
500 ms; `s3.Presign` signs no headers, so uploads go through the server; there is no Unicode normalization in the
standard library, so clients send names in NFC.
