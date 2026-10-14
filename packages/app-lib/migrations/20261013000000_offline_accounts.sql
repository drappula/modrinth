-- Adds first-class offline accounts to minecraft_users.
--
-- Offline rows use account_type = 'offline' with sentinel network credentials
-- (empty tokens, expiry 0); all consumers branch on account_type and never
-- read tokens for offline rows. NOT NULL on the token columns is kept
-- deliberately so the skin-selector triggers on this table are preserved.

ALTER TABLE minecraft_users
    ADD COLUMN account_type TEXT NOT NULL DEFAULT 'microsoft';
