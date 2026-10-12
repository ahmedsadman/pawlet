-- Heartbeats: the app reports, per UTC day, whether it was opened and whether
-- it ran at all, independently of proxy sessions.
--
-- The defaults are 1 on purpose. Every row that exists before this migration
-- came from a session minted in the foreground (the app could not mint in the
-- background), so it was opened, alive and attested, and ADD COLUMN fills
-- that in. An older pawletd rolled back by image tag still only writes rows
-- from foreground sessions, so its fresh INSERTs stay correct; its upserts
-- don't touch the new flags, preserving heartbeat values. Every writer in
-- this binary passes all flags explicitly. Under a rolled-back pawletd, a
-- session on a heartbeat-first install leaves attested=0 until the next
-- session after rolling forward, and a session on an existing heartbeat day
-- leaves that day's session flag at 0 (harmless: the app marks the day opened).
ALTER TABLE install_days ADD COLUMN opened  INTEGER NOT NULL DEFAULT 1;
ALTER TABLE install_days ADD COLUMN alive   INTEGER NOT NULL DEFAULT 1;
ALTER TABLE install_days ADD COLUMN session INTEGER NOT NULL DEFAULT 1;

-- 1 once the install has passed Play Integrity. Installs first seen through a
-- heartbeat (bring-your-own-key, sideloaded) are inserted with 0.
ALTER TABLE installs ADD COLUMN attested INTEGER NOT NULL DEFAULT 1;
