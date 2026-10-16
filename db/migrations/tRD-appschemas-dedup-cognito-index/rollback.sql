-- tRD-appschemas-dedup-cognito-index / rollback.sql
-- Recreate the dropped duplicate partial-unique index (restores pre-migration state).
CREATE UNIQUE INDEX IF NOT EXISTS users_id_user_cognito_un
    ON identity.users USING btree (id_user_cognito)
    WHERE (id_user_cognito IS NOT NULL);
