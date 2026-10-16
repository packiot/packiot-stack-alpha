-- rollback for t-downtime-resolved-unique: drop the key (the deleted rows were duplicates; not restored).
DROP INDEX IF EXISTS serving.dt_events_resolved_event_uk;
-- the previous refresh body is the same minus the advisory lock, DISTINCT ON and ON CONFLICT clauses.
