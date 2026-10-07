-- t-device-bindings — ADR-0061 P0: one row per DEVICE binding a declared, opaque device_key to its equipment.
--
-- WHY: the cloud resolves every SparkPlug metric by its PackML name (core.topic_routing / the packml_register view).
-- ADR-0061 replaces that with an identity declared once, at birth: the producer sends device_key in the DBIRTH and the
-- decoder binds it to id_equipment. This table is that binding. It is the replacement for core.topic_routing, which
-- stays untouched (and still routes) until each client switches (ADR-0061 D7) and is dropped in P5.
--
-- MODEL
--   * one row per equipment that has at least one active routing row today (topic_routing models TOPICS, often
--     several per machine; a device has exactly ONE key, so the 84 metric-level rows that could never carry the
--     machine's key under topic_routing's global-unique index simply collapse into their equipment here)
--   * device_key = 'dk_' + 32 hex from gen_random_uuid(): opaque, random, environment-independent (it is promoted
--     staging → prod as-is). Never derived from names: the CHECK rejects anything else, so a derived string such as
--     '<CLIENT>-SC-LINHAS-L5-<MACHINE>' cannot be stored by mistake.
--   * (id_equipment, id_enterprise) is a composite FK: a binding cannot point at another tenant's equipment.
--   * at most one ACTIVE binding per equipment; device_key unique globally (it is random; uniqueness is a guard).
--   * edge_node / device / bound_at: the SparkPlug edge node + device that last presented this key in a birth.
--     Filled by the decoder from P2 on; NULL until then.
--   * RLS enabled + FORCED with the house tenant_isolation policy (core.topic_routing has no RLS today although
--     readapi_ro can SELECT it: this table does not repeat that gap).
-- Idempotent: re-running creates nothing twice and never regenerates a key.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

-- target of the composite FK; id_equipment is already the PK, so this is trivially unique (283 rows, instant)
CREATE UNIQUE INDEX IF NOT EXISTS equipments_id_equipment_id_enterprise_uq ON core.equipments (id_equipment, id_enterprise);

CREATE TABLE IF NOT EXISTS core.device_bindings (
    id_device_binding bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_enterprise     integer     NOT NULL,
    id_equipment      integer     NOT NULL,
    device_key        text        NOT NULL CONSTRAINT device_bindings_key_format CHECK (device_key ~ '^dk_[0-9a-f]{32}$'),
    edge_node         text,
    device            text,
    bound_at          timestamptz,
    active            boolean     NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT device_bindings_equipment_fk FOREIGN KEY (id_equipment, id_enterprise)
        REFERENCES core.equipments (id_equipment, id_enterprise) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT device_bindings_key_uq UNIQUE (device_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS device_bindings_one_active_per_equipment ON core.device_bindings (id_equipment) WHERE active;
CREATE INDEX IF NOT EXISTS device_bindings_enterprise_idx ON core.device_bindings (id_enterprise);

COMMENT ON TABLE core.device_bindings IS
  'ADR-0061: declared device identity. device_key (opaque, sent in the SparkPlug DBIRTH) → id_equipment. Replaces core.topic_routing.';
COMMENT ON COLUMN core.device_bindings.device_key IS 'Opaque random key dk_<32 hex>; never derived from names; promoted staging→prod unchanged.';
COMMENT ON COLUMN core.device_bindings.bound_at IS 'Last DBIRTH that presented this key (set by the decoder from ADR-0061 P2).';

DROP TRIGGER IF EXISTS trg_set_updated_at ON core.device_bindings;
CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON core.device_bindings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE core.device_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.device_bindings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON core.device_bindings;
CREATE POLICY tenant_isolation ON core.device_bindings
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));

GRANT SELECT ON core.device_bindings TO readapi_ro, cloudbeaver_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.device_bindings TO cloudbeaver_rw;

-- guard: core.equipments.id_enterprise is nullable; a routed equipment without a tenant cannot be bound. Fail with a
-- clear message instead of a NOT NULL error (the whole transaction rolls back either way).
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM core.equipments e
   WHERE e.id_enterprise IS NULL
     AND EXISTS (SELECT 1 FROM core.topic_routing tr WHERE tr.id_equipment = e.id_equipment AND tr.active);
  IF n > 0 THEN RAISE EXCEPTION 't-device-bindings: % routed equipment(s) have no id_enterprise; fix them first', n; END IF;
END $$;

-- backfill: one binding per equipment that routes today, tenant taken from the EQUIPMENT (the FK enforces it)
INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key)
SELECT e.id_enterprise, e.id_equipment, 'dk_' || replace(gen_random_uuid()::text, '-', '')
FROM core.equipments e
WHERE EXISTS (SELECT 1 FROM core.topic_routing tr WHERE tr.id_equipment = e.id_equipment AND tr.active)
  AND NOT EXISTS (SELECT 1 FROM core.device_bindings b WHERE b.id_equipment = e.id_equipment AND b.active);

COMMIT;
