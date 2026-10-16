-- t243 (naming tidy) · drop the orphaned Portuguese-named view
-- public.monitoramento_execucao_functions. It was a trivial
--   SELECT ts_value, function_name FROM function_execution_log
-- convenience view with 0 DB dependents and 0 service/Superset consumers (verified).
-- The user approved renaming it to function_execution_monitor, but since nothing
-- reads it, the tidy action is to DROP it rather than keep a renamed orphan.
-- (function_execution_log itself lives in `ops` and is untouched.) If a cleanly-named
-- convenience view is ever wanted: CREATE VIEW ops.function_execution_monitor AS
-- SELECT ts_value, function_name FROM ops.function_execution_log;
DROP VIEW IF EXISTS public.monitoramento_execucao_functions;
