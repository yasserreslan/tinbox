-- Uploads in parts (design/backend.md, section 6): a block sent as parts of at most 1 MiB, for clients that limit
-- their upload speed. The parts live in the store under uploads/<team>/<hash>/<part>; this row is for the sweep.
CREATE TABLE uploads (
	team_id bigint NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
	hash text NOT NULL,
	started_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (team_id, hash)
);
