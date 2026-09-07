-- Reverse of 01_drop_operator_pw_hash.up.sql — re-adds the nullable column only.
-- Historical hashes are NOT restored (they were write-only + unverifiable). A
-- rollback that needs operator passwords must re-provision them via the (also
-- reverted) set-operator-password path.
\set ON_ERROR_STOP on
ALTER TABLE users ADD COLUMN IF NOT EXISTS operator_pw_hash text;
