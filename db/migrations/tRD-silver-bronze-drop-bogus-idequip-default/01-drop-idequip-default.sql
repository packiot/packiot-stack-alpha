-- tRD-silver-bronze — SAFE win: drop the bogus auto-increment DEFAULT on the
-- id_equipment FK column.
--
-- FINDING: silver.equipment_values.id_equipment (and the inherited
-- bronze.equipment_values_raw.id_equipment) carry
--     DEFAULT nextval('silver.equipment_values_id_equipment_seq')
-- id_equipment is a FOREIGN KEY to core.equipments — it must be supplied by the
-- producer, never fabricated from a sequence. This is a classic CREATE-TABLE-LIKE /
-- accidental-serial leftover: if any INSERT ever omitted id_equipment it would
-- silently invent a garbage FK instead of failing loudly.
--
-- Why it is HARMLESS TODAY but still worth fixing: every writer supplies
-- id_equipment explicitly — it is part of the UNIQUE(id_equipment, ts_value) upsert
-- key (writers/equipment_values.go buildProcessed lists id_equipment in the INSERT
-- column list; the bronze golden test declares it NOT NULL with no default). So the
-- sequence has never fired (the column comment / FK semantics prove intent). The
-- default is a latent footgun, not a live bug.
--
-- SAFE: dropping a column DEFAULT is a catalog-only change (no table rewrite, even
-- on these hypertables) and touches no reader — defaults only affect writers that
-- OMIT the column, of which there are none. source_seq / ingested_at defaults are
-- CORRECT (auto-assigned lineage) and are left untouched.
--
-- The owned sequence silver.equipment_values_id_equipment_seq is left in place
-- (still OWNED BY the column) so this migration stays trivially reversible; it is
-- now inert. Dropping the sequence itself is a separate, optional cleanup.

ALTER TABLE silver.equipment_values      ALTER COLUMN id_equipment DROP DEFAULT;
ALTER TABLE bronze.equipment_values_raw  ALTER COLUMN id_equipment DROP DEFAULT;
