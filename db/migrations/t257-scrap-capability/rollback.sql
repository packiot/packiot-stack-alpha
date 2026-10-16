-- t257 rollback — drop the additive scrap-capability serving function.
-- Safe: additive, no other object depends on it (read-api calls it dynamically by name).
DROP FUNCTION IF EXISTS serving.equipment_scrap_capability(integer);
