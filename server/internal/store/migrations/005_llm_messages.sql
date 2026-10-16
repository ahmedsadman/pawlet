-- usage.calls now counts distinct messages sent to the LLM: a retry of a
-- message already counted adds nothing. attempts keeps the old meaning, every
-- admitted classify request, because each one is a real upstream call and the
-- quota charges for it. Before this migration the two were the same number,
-- so attempts starts as a copy of calls.
--
-- An older pawletd rolled back by image tag writes calls per attempt again and
-- hydrates its quota from calls, so for that day its quota is a little
-- lenient. Its INSERTs leave attempts at the default 0.
ALTER TABLE usage ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
UPDATE usage SET attempts = calls;

-- Message keys already counted in usage.calls, per install. The key is an
-- opaque value the app derives per message (no content). day is the UTC day
-- the message was first admitted, which is the day its call is credited to.
-- Rows older than the retention window are pruned by pawletd.
CREATE TABLE llm_messages (
  id_hash     TEXT NOT NULL,
  message_key TEXT NOT NULL,
  day         TEXT NOT NULL,
  PRIMARY KEY (id_hash, message_key)
);
CREATE INDEX llm_messages_day ON llm_messages (day);
