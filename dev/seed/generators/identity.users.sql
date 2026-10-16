-- identity.users (manifest mode: replace) — synthetic dev users, never real people.
-- Shape mirrors staging (2026-10-07, aggregates only): every tenant user has user_roles = 3, internal_user,
-- active, menu {"custom_user": []}, America/Sao_Paulo, en-US. id_user_cognito stays NULL: read-api links it on
-- first login (identity.users UPDATE grant, t276) against the dev Cognito pool (ADR-0060). example.com is
-- reserved (RFC 2606), so these addresses can never reach a real inbox.
INSERT INTO identity.users (user_email, user_name, id_enterprise, phone_number, user_roles, timezone, languages,
                            user_menu, internal_user, active, id_user_cognito)
SELECT u.email, u.name, e.id_enterprise, NULL, 3, 'America/Sao_Paulo', 'en-US', '{"custom_user": []}'::jsonb, true, true, NULL
  FROM core.enterprises e
 CROSS JOIN (VALUES ('dev-admin@example.com', 'Dev Admin'),
                    ('dev-engineer@example.com', 'Dev Engineer'),
                    ('dev-viewer@example.com', 'Dev Viewer')) AS u(email, name)
 WHERE NOT EXISTS (SELECT 1 FROM identity.users x WHERE x.user_email = u.email);
