CREATE TABLE IF NOT EXISTS installs (
  id_hash    TEXT PRIMARY KEY,
  first_seen INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  banned     INTEGER NOT NULL DEFAULT 0,
  ban_reason TEXT NOT NULL DEFAULT ''
);

-- One row per install per UTC day, never pruned. At this service's scale
-- (hundreds of installs) that is a few thousand rows a year, so a retention
-- sweep would be more moving parts than the growth justifies.
CREATE TABLE IF NOT EXISTS usage (
  id_hash TEXT NOT NULL,
  day     TEXT NOT NULL,
  calls   INTEGER NOT NULL DEFAULT 0,
  tokens  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id_hash, day)
);
