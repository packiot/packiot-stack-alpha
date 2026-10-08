-- t-adr0062-p1-po-number-expand — ADR-0062 step 1 (expand): the client's PO number becomes the authoritative,
-- text, unique-per-enterprise business key; po_uuid (UUIDv7) is the handle for ids minted outside the DB; the
-- integer id_order keeps working for every current writer/reader (it is retired in the contract step).
--
--   * core.uuidv7(ts)             RFC 9562 UUIDv7 (PG 15 has no uuidv7()): 48-bit unix-ms timestamp + random.
--   * core.po_number_corrections  reviewed, data-driven number fixes, applied by the trigger on every write
--                                 (so the legacy replicator and the sandbox twin pick them up without code).
--                                 D5: PO 101585550 (+ twin 601585550) 889185 → 889583.
--   * trigger production_orders_po_number (BEFORE INSERT/UPDATE OF id_order, id_order_text):
--       - the number is trimmed (never re-formatted: '08396260' stays '08396260');
--       - a writer that sends only the integer gets id_order_text = id_order::text;
--       - an UPDATE that renumbers only the integer carries a mirrored text along;
--       - a writer that sends only the text (or id_order = 0, the CSV-import "too big" placeholder that made
--         such POs overwrite each other) gets id_order = the number when it is digits-only, fits int4 and is
--         free, else a NEGATIVE internal value from a sequence — never collides with a client's own number;
--       - a reviewed correction is applied.
--   * backfill: every NULL text = id_order::text; po_uuid from ts_creation (time-ordered); then
--     id_order_text NOT NULL + UNIQUE (id_enterprise, id_order_text). A new duplicate now FAILS LOUDLY.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION core.uuidv7(ts timestamptz DEFAULT clock_timestamp())
RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT encode(
           set_bit(set_bit(
             overlay(uuid_send(gen_random_uuid())
                     PLACING substring(int8send((extract(epoch FROM ts) * 1000)::bigint) FROM 3)
                     FROM 1 FOR 6),
             52, 1), 53, 1),
           'hex')::uuid
$$;
COMMENT ON FUNCTION core.uuidv7(timestamptz) IS
  'RFC 9562 UUIDv7 (48-bit unix-ms timestamp, version 7, variant, random) — PG 15 has no built-in. ADR-0062.';

CREATE TABLE IF NOT EXISTS core.po_number_corrections (
  id_production_order bigint PRIMARY KEY,
  from_text  varchar(255) NOT NULL,
  to_text    varchar(255) NOT NULL,
  reason     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.po_number_corrections IS
  'ADR-0062: reviewed client-PO-number fixes; the production_orders trigger rewrites from_text → to_text for that PO on every write.';
INSERT INTO core.po_number_corrections (id_production_order, from_text, to_text, reason) VALUES
  (101585550, '889185', '889583', 'ADR-0062 D5: legacy text duplicated PO 101574989; 889583 is this PO''s own number (user 2026-10-07)'),
  (601585550, '889185', '889583', 'ADR-0062 D5: sandbox twin of 101585550')
ON CONFLICT (id_production_order) DO NOTHING;

CREATE SEQUENCE IF NOT EXISTS core.production_orders_internal_id_order_seq
  INCREMENT BY -1 MINVALUE -2147483648 MAXVALUE -1 START WITH -1;
COMMENT ON SEQUENCE core.production_orders_internal_id_order_seq IS
  'ADR-0062: internal id_order for POs whose client number is not a free int4 (negative — never a client number).';

CREATE OR REPLACE FUNCTION core.production_orders_po_number()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE corr varchar;
BEGIN
  NEW.id_order_text := nullif(btrim(NEW.id_order_text), '');
  IF TG_OP = 'UPDATE' AND NEW.id_order IS DISTINCT FROM OLD.id_order
     AND NEW.id_order_text IS NOT DISTINCT FROM OLD.id_order_text AND OLD.id_order_text = OLD.id_order::text THEN
    NEW.id_order_text := NEW.id_order::text;           -- integer-only renumber: keep the mirror in step
  END IF;
  IF NEW.id_order = 0 AND NEW.id_order_text IS DISTINCT FROM '0' THEN
    NEW.id_order := NULL;                               -- CSV-import placeholder: not a number
  END IF;
  IF NEW.id_order_text IS NULL AND NEW.id_order IS NOT NULL THEN
    NEW.id_order_text := NEW.id_order::text;            -- integer-only writer
  END IF;
  IF NEW.id_order IS NULL THEN                          -- text-only writer
    IF NEW.id_order_text ~ '^[0-9]{1,10}$' AND NEW.id_order_text::bigint <= 2147483647
       AND NOT EXISTS (SELECT 1 FROM core.production_orders p
                        WHERE p.id_enterprise = NEW.id_enterprise AND p.id_order = NEW.id_order_text::int
                          AND p.id_production_order IS DISTINCT FROM NEW.id_production_order) THEN
      NEW.id_order := NEW.id_order_text::int;
    ELSE
      NEW.id_order := nextval('core.production_orders_internal_id_order_seq');
    END IF;
  END IF;
  SELECT c.to_text INTO corr FROM core.po_number_corrections c
   WHERE c.id_production_order = NEW.id_production_order AND c.from_text = NEW.id_order_text;
  IF corr IS NOT NULL THEN
    NEW.id_order_text := corr;
  END IF;
  RETURN NEW;
END
$fn$;

ALTER TABLE core.production_orders ADD COLUMN IF NOT EXISTS po_uuid uuid;

-- one pass: number backfill (+ trim) + reviewed corrections + time-ordered uuid
UPDATE core.production_orders p
   SET id_order_text = coalesce(
         (SELECT c.to_text FROM core.po_number_corrections c
           WHERE c.id_production_order = p.id_production_order AND c.from_text = btrim(p.id_order_text)),
         nullif(btrim(p.id_order_text), ''),
         p.id_order::text),
       po_uuid = coalesce(p.po_uuid, core.uuidv7(p.ts_creation));

ALTER TABLE core.production_orders
  ALTER COLUMN po_uuid SET DEFAULT core.uuidv7(),
  ALTER COLUMN po_uuid SET NOT NULL,
  ALTER COLUMN id_order_text SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS production_orders_po_uuid_key ON core.production_orders (po_uuid);
CREATE UNIQUE INDEX IF NOT EXISTS production_orders_id_enterprise_order_number_key
  ON core.production_orders (id_enterprise, id_order_text);

DROP TRIGGER IF EXISTS production_orders_po_number ON core.production_orders;
CREATE TRIGGER production_orders_po_number
  BEFORE INSERT OR UPDATE OF id_order, id_order_text ON core.production_orders
  FOR EACH ROW EXECUTE FUNCTION core.production_orders_po_number();

COMMENT ON COLUMN core.production_orders.id_order_text IS
  'ADR-0062: THE client''s PO number (API field order_number) — text as given (trimmed), UNIQUE per enterprise.';
COMMENT ON COLUMN core.production_orders.id_order IS
  'DEPRECATED (ADR-0062): internal integer kept for current writers/readers; negative = assigned (client number not a free int4). Dropped in the contract step.';
COMMENT ON COLUMN core.production_orders.po_uuid IS
  'ADR-0062: UUIDv7 handle for ids minted outside the DB (offline boxes, cross-environment). Internal joins use id_production_order.';

COMMIT;
