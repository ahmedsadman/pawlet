-- Daily counts of how the app's on-device model handled live messages, one
-- row per install per UTC day per app version. The app sends whole-day totals,
-- so a resend replaces the row. Rows older than the retention window are
-- folded into model_stats_rollup by pawletd's rollup job.
CREATE TABLE model_stats_daily (
  id_hash          TEXT NOT NULL,
  day              TEXT NOT NULL,
  app_version_code INTEGER NOT NULL,
  accepted         INTEGER NOT NULL DEFAULT 0,
  declined         INTEGER NOT NULL DEFAULT 0,
  unavailable      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id_hash, day, app_version_code)
);

-- model_stats_daily rows past the retention window, summed across installs.
-- install_count is how many install-day rows were folded in, so per-install
-- averages survive the fold.
CREATE TABLE model_stats_rollup (
  day              TEXT NOT NULL,
  app_version_code INTEGER NOT NULL,
  accepted         INTEGER NOT NULL DEFAULT 0,
  declined         INTEGER NOT NULL DEFAULT 0,
  unavailable      INTEGER NOT NULL DEFAULT 0,
  install_count    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, app_version_code)
);

-- Messages (accepted + declined + unavailable) from this install's folded
-- model_stats_daily rows, so its lifetime total survives the fold.
ALTER TABLE installs ADD COLUMN messages_archived INTEGER NOT NULL DEFAULT 0;
