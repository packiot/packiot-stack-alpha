-- Rollback: drop the function (the heal skips the call when it is absent).
DROP FUNCTION IF EXISTS ops.sandbox_fix_running_without_runtime(integer);
