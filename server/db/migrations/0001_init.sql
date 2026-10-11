-- tinbox's first schema (design/backend.md, "Tables"). Forward only: a later change is a new numbered file.

-- settings holds what the server keeps for itself, such as the nonce secret it makes on first start.
CREATE TABLE settings (
	key text PRIMARY KEY,
	value text NOT NULL
);

CREATE TABLE users (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	email text NOT NULL,
	name text NOT NULL DEFAULT '',
	created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email ON users (lower(email));

-- devices is one row per Mac: its ed25519 public key (base64) signs its requests.
CREATE TABLE devices (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
	name text NOT NULL,
	public_key text NOT NULL UNIQUE,
	created_at timestamptz NOT NULL DEFAULT now(),
	last_seen timestamptz,
	revoked_at timestamptz
);

-- teams is one shared folder each: its root node, its head in the journal and the epoch a restore from backup renews.
CREATE TABLE teams (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	name text NOT NULL,
	root_id bigint NOT NULL DEFAULT 0,
	root_hash text NOT NULL DEFAULT '',
	head_seq bigint NOT NULL DEFAULT 0,
	floor_seq bigint NOT NULL DEFAULT 0,
	epoch text NOT NULL,
	used_bytes bigint NOT NULL DEFAULT 0,
	quota_bytes bigint NOT NULL DEFAULT 0,
	created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE members (
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
	role text NOT NULL CHECK (role IN ('owner', 'member')),
	created_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (team_id, user_id)
);

-- invites keep the SHA-256 of each code, never the code.
CREATE TABLE invites (
	code_hash text PRIMARY KEY,
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	email text NOT NULL,
	role text NOT NULL CHECK (role IN ('owner', 'member')),
	created_by bigint REFERENCES users (id) ON DELETE SET NULL,
	expires_at timestamptz NOT NULL,
	used_at timestamptz
);

-- device_links is a new Mac waiting for one of its user's Macs to approve it.
CREATE TABLE device_links (
	code_hash text PRIMARY KEY,
	public_key text NOT NULL,
	device_name text NOT NULL,
	state text NOT NULL CHECK (state IN ('pending', 'approved', 'used')),
	user_id bigint REFERENCES users (id) ON DELETE CASCADE,
	expires_at timestamptz NOT NULL
);

CREATE SEQUENCE node_ids;

-- nodes is the tree, as parent-pointer rows: rev is the seq of the last content change, place_rev of the last move.
CREATE TABLE nodes (
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	id bigint NOT NULL,
	parent_id bigint,
	name text NOT NULL,
	name_key text NOT NULL,
	kind smallint NOT NULL CHECK (kind IN (1, 2, 3)),
	hash text NOT NULL,
	size bigint NOT NULL DEFAULT 0,
	mtime_ns bigint NOT NULL DEFAULT 0,
	rev bigint NOT NULL,
	place_rev bigint NOT NULL,
	deleted_seq bigint,
	PRIMARY KEY (team_id, id)
);
CREATE UNIQUE INDEX nodes_by_name ON nodes (team_id, parent_id, name_key) WHERE deleted_seq IS NULL;
CREATE INDEX nodes_trash ON nodes (team_id, deleted_seq) WHERE deleted_seq IS NOT NULL;

-- versions is every content a file has had, and version_blocks its blocks in order.
CREATE TABLE versions (
	team_id bigint NOT NULL,
	node_id bigint NOT NULL,
	rev bigint NOT NULL,
	kind smallint NOT NULL,
	hash text NOT NULL,
	size bigint NOT NULL,
	device_id bigint,
	created_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (team_id, node_id, rev),
	FOREIGN KEY (team_id, node_id) REFERENCES nodes (team_id, id) ON DELETE CASCADE
);

CREATE TABLE version_blocks (
	team_id bigint NOT NULL,
	node_id bigint NOT NULL,
	rev bigint NOT NULL,
	idx int NOT NULL,
	hash text NOT NULL,
	PRIMARY KEY (team_id, node_id, rev, idx),
	FOREIGN KEY (team_id, node_id, rev) REFERENCES versions (team_id, node_id, rev) ON DELETE CASCADE
);
CREATE INDEX version_blocks_hash ON version_blocks (team_id, hash);

-- journal is every change, append-only: the node's state after it. A client's op_id makes a retried change a no-op.
CREATE TABLE journal (
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	seq bigint NOT NULL,
	op_id text NOT NULL,
	node_id bigint NOT NULL,
	op text NOT NULL,
	parent_id bigint,
	name text NOT NULL,
	kind smallint NOT NULL,
	hash text NOT NULL,
	size bigint NOT NULL,
	mtime_ns bigint NOT NULL,
	rev bigint NOT NULL,
	place_rev bigint NOT NULL,
	deleted boolean NOT NULL,
	device_id bigint,
	at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (team_id, seq)
);
CREATE INDEX journal_op ON journal (team_id, op_id);
CREATE INDEX journal_node ON journal (team_id, node_id, seq);

-- blocks is what the bucket holds for each team; lost is set when tinbox check finds one missing or damaged.
CREATE TABLE blocks (
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	hash text NOT NULL,
	size int NOT NULL,
	lost boolean NOT NULL DEFAULT false,
	created_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (team_id, hash)
);

CREATE TABLE audit_log (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	team_id bigint,
	user_id bigint,
	device_id bigint,
	action text NOT NULL,
	detail text NOT NULL DEFAULT '',
	at timestamptz NOT NULL DEFAULT now()
);
