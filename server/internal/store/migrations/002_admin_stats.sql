-- What the latest Play Integrity verdict said about each install. NULL means
-- the verdict did not carry the field (or the install has not attested since
-- this migration).
ALTER TABLE installs ADD COLUMN app_version_code INTEGER;
ALTER TABLE installs ADD COLUMN device_tier TEXT;
ALTER TABLE installs ADD COLUMN licensing TEXT;
ALTER TABLE installs ADD COLUMN sdk_version INTEGER;

-- One row per install per UTC day with a successful session. Roughly "opened
-- the app that day"; never pruned, for the same reason as usage.
CREATE TABLE install_days (
  id_hash          TEXT NOT NULL,
  day              TEXT NOT NULL,
  app_version_code INTEGER,
  PRIMARY KEY (id_hash, day)
);

-- Daily aggregate counters with no install identity: outcomes, latency
-- buckets, served model, category. Keys are fixed enums or model ids.
CREATE TABLE counters_daily (
  day    TEXT NOT NULL,
  metric TEXT NOT NULL,
  key    TEXT NOT NULL,
  count  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric, key)
);

-- Effective configuration pawletd publishes at startup, so the admin
-- dashboard can show limits without its own copy of the config.
CREATE TABLE server_info (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
