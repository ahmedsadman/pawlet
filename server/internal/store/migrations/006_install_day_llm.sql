-- An install's LLM group: on (Pawlet proxy, LLM switch on); off (on-device
-- model only); byok (own OpenRouter key); none (no LLM, sideloaded or ineligible).
-- Old app versions omit the field, which stores NULL and reads as empty, so an
-- empty value in a later heartbeat must never clear a stored one. A non-empty
-- value overwrites whatever was there. Before an install reports its LLM group
-- the field stays NULL, so a never-reported group also reads as empty.
--
-- An older pawletd rolled back by image tag writes NULL when the field is omitted.
ALTER TABLE install_days ADD COLUMN llm TEXT;
