CREATE TABLE IF NOT EXISTS installs (
  id_hash    TEXT PRIMARY KEY,
  first_seen INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  banned     INTEGER NOT NULL DEFAULT 0,
  ban_reason TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS usage (
  id_hash TEXT NOT NULL,
  day     TEXT NOT NULL,
  calls   INTEGER NOT NULL DEFAULT 0,
  tokens  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id_hash, day)
);
