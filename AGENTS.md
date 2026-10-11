# Agent instructions

tinbox is written in Tin. Build only through `./tin` (it runs the release in `TIN_VERSION`); never use another Tin
on the PATH, and never edit `TIN_VERSION` by hand: `scripts/tin-update.sh` moves it after everything passes, and
the bump is committed on its own.

- The server is production on Linux (arm64 and x86-64); it builds and its unit tests run on macOS. The Mac app is a
  product here, unlike in the tin repository, where macOS is for development only.
- The protocol, hashes, tables and rules are in design/backend.md. Change the document in the same commit as the
  code that changes a rule. `proto/` is shared with clients: a change to a hash or the signing text breaks every
  Mac, so it needs a new version string (`tinbox dir v2`, `tinbox v2`).
- Migrations are forward only: never edit a released file in `server/db/migrations/`; add the next number.
- Before a commit: `scripts/test.sh`, and `tests/local.sh` when Docker is available. Never weaken a check to pass.
- Calls that bind values to SQL use `query` literals; never build SQL from request text.
- A gap or a bug in Tin itself is reported as an issue on yasserreslan/tin, with a small repro, and worked around
  here until a release fixes it.
