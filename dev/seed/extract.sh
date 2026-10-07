#!/usr/bin/env bash
# extract.sh — build the anonymized dev-seed payload from staging (ADR-0060 D4–D6). Runs on the self-hosted
# staging runner; raw data never leaves the host, only the anonymized, leak-gated output does.
#
#   PGURL=postgresql://… DEVSEED_HMAC_KEY=… OUT=/tmp/devseed dev/seed/extract.sh
#
# Every DB session is read-only (default_transaction_read_only=on) with a statement timeout, and
# extraction uses COPY (SELECT …) — compressed chunks are read transparently; never decompress_chunk.
# Steps (any failure stops the build):
#   1. live column inventory → validate.py           (fail-closed: unlisted table / unclassified column / new type)
#   2. tokens (tenant names) for scrub + leak gate   (kept OUTSIDE $OUT/payload: never packaged)
#   3. full pg_dump -Fc WITHOUT user/chunk data       (Timescale catalog kept: hypertables, caggs, policies survive)
#      + roles (no passwords); DDL secret scan
#   4. per table: COPY (SELECT cols FROM t WHERE …) | anonymize.py | gzip
#   5. leakgate.py over every output file
#   6. metadata.json (snapshot_end, since, tenant, counts, versions)
# DEVSEED_ROW_LIMIT=N adds LIMIT N per table (test runs only).
set -euo pipefail
: "${PGURL:?set PGURL}" "${DEVSEED_HMAC_KEY:?set DEVSEED_HMAC_KEY}"
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${SEED_CONF_DIR:-$HERE}   # manifest.yml + classification.yml (override only for tests)
OUT=${OUT:-$PWD/devseed-out}
IMG=${PG_CLIENT_IMAGE:-postgres:15-alpine}
TENANT=$(awk '/^tenant:/{print $2}' "$CONF/manifest.yml")
WINDOW=$(awk '/^window_days:/{print $2}' "$CONF/manifest.yml")
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "ABORT: $IMG not present (this script never pulls)"; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT/payload/data" "$OUT/private"
chmod 700 "$OUT/private"
RO='-c default_transaction_read_only=on -c statement_timeout=600000'
psql_ro() { docker run --rm -i --network host -e PGOPTIONS="$RO" "$IMG" psql "$PGURL" -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== 1. inventory + validate"
psql_ro -At -F $'\t' -f - > "$OUT/private/columns.tsv" <<'SQL'
SELECT n.nspname, c.relname,
       CASE WHEN EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates a WHERE a.view_schema=n.nspname AND a.view_name=c.relname) THEN 'cagg'
            WHEN EXISTS (SELECT 1 FROM timescaledb_information.hypertables h WHERE h.hypertable_schema=n.nspname AND h.hypertable_name=c.relname) THEN 'hypertable'
            ELSE CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview' WHEN 'p' THEN 'partitioned' ELSE 'foreign' END END,
       ic.column_name, ic.data_type
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN information_schema.columns ic ON ic.table_schema=n.nspname AND ic.table_name=c.relname
WHERE c.relkind IN ('r','v','m','p','f') AND n.nspname NOT IN ('pg_catalog','information_schema','cron')
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%'
ORDER BY 1,2,ic.ordinal_position;
SQL
psql_ro -At -F $'\t' -c "SELECT table_schema, table_name, column_name FROM information_schema.columns
  WHERE is_generated='ALWAYS' AND table_schema NOT IN ('pg_catalog','information_schema');" > "$OUT/private/generated.tsv"
python3 "$HERE/validate.py" --columns "$OUT/private/columns.tsv" --manifest "$CONF/manifest.yml" --classification "$CONF/classification.yml" --generators "$CONF/generators"

echo "== 2. snapshot window + tokens"
SNAPSHOT_END=$(psql_ro -At -c "SELECT now()")
SINCE=$(psql_ro -At -c "SELECT '$SNAPSHOT_END'::timestamptz - interval '$WINDOW days'")
psql_ro -At -F $'\t' -v tenant="$TENANT" -f - > "$OUT/private/tokens.tsv" <<'SQL'
SELECT 'enterprise', nm_enterprise FROM core.enterprises WHERE id_enterprise = :tenant
UNION SELECT 'site', nm_site FROM core.sites WHERE id_enterprise = :tenant
UNION SELECT 'area', nm_area FROM core.areas WHERE id_enterprise = :tenant
UNION SELECT 'equipment', nm_equipment FROM core.equipments WHERE id_enterprise = :tenant
UNION SELECT 'equipment_code', cd_equipment FROM core.equipments WHERE id_enterprise = :tenant
UNION SELECT 'client', nm_client FROM core.clients WHERE id_enterprise = :tenant
UNION SELECT 'product', nm_product FROM core.products WHERE id_enterprise = :tenant
UNION SELECT 'product_family', nm_product_family FROM core.product_families WHERE id_enterprise = :tenant;
SQL
# the enterprise name's first word (e.g. a brand before "-Staging") is a token of its own
awk -F'\t' '$1=="enterprise"{split($2,w,/[^[:alnum:]]+/); if (length(w[1])>=4) print "enterprise\t" w[1]}' "$OUT/private/tokens.tsv" >> "$OUT/private/tokens.tsv"
echo "tokens: $(wc -l < "$OUT/private/tokens.tsv")   window: $SINCE .. $SNAPSHOT_END"

echo "== 3. DDL dump (no data) + roles + secret scan"
EXCL=()
for s in $(cut -f1 "$OUT/private/columns.tsv" | sort -u) _timescaledb_internal; do EXCL+=(--exclude-table-data="$s.*"); done
docker run --rm --network host -e PGOPTIONS="$RO" "$IMG" pg_dump "$PGURL" -Fc "${EXCL[@]}" > "$OUT/payload/schema.dump"
docker run --rm --network host -e PGOPTIONS="$RO" "$IMG" pg_dumpall -d "$PGURL" --roles-only --no-role-passwords > "$OUT/payload/roles.sql"
docker run --rm -i "$IMG" pg_restore -f - < "$OUT/payload/schema.dump" > "$OUT/private/schema.sql"
if grep -Eqi "password[[:space:]]*=|postgres(ql)?://[^ ]*@|(^|[^a-z_])(host|hostaddr)[[:space:]]*=" "$OUT/private/schema.sql" "$OUT/payload/roles.sql"; then
  echo "ABORT: DDL secret scan matched (connection string / password in schema or roles)"; exit 1
fi
echo "schema.dump $(du -h "$OUT/payload/schema.dump" | cut -f1), roles.sql $(wc -l < "$OUT/payload/roles.sql") lines, secret scan clean"

echo "== 4. extract + anonymize"
python3 - "$CONF/manifest.yml" "$OUT/private/columns.tsv" "$OUT/private/generated.tsv" "${DEVSEED_ROW_LIMIT:-}" > "$OUT/private/copies.tsv" <<'PY'
import re, sys
manifest, columns, generated, limit = sys.argv[1:5]
gen = {tuple(l.rstrip('\n').split('\t')) for l in open(generated) if l.strip()}
cols = {}
for l in open(columns):
    s, t, k, c, ty = l.rstrip('\n').split('\t')
    if (s, t, c) not in gen:
        cols.setdefault((s, t), []).append(c)
rx = re.compile(r'^  (\w+)\.(\w+): \{mode: (\w+)(?:, where: "([^"]*)")?\}')
for l in open(manifest):
    m = rx.match(l)
    if not m or m[3] not in ('rows', 'full'):
        continue
    s, t, mode, where = m.groups()
    sel = ', '.join('"%s"' % c for c in cols[(s, t)])
    q = f'SELECT {sel} FROM "{s}"."{t}"' + (f' WHERE {where}' if where else '') + (f' LIMIT {int(limit)}' if limit else '')
    print(f'{s}.{t}\t{q}')
PY
while IFS=$'\t' read -r table query; do
  printf '%s\n' "COPY ($query) TO STDOUT WITH (FORMAT csv, HEADER, NULL '\\N');" \
    | psql_ro -v tenant="$TENANT" -v since="'$SINCE'::timestamptz" -f - \
    | python3 "$HERE/anonymize.py" --table "$table" --tokens "$OUT/private/tokens.tsv" --classification "$CONF/classification.yml" \
    | gzip -6 > "$OUT/payload/data/$table.csv.gz"
done < "$OUT/private/copies.tsv"

echo "== 5. leak gate"
python3 "$HERE/leakgate.py" --tokens "$OUT/private/tokens.tsv" --columns "$OUT/private/columns.tsv" "$OUT"/payload/data/*.csv.gz

echo "== 6. metadata"
python3 - "$OUT" "$TENANT" "$WINDOW" "$SNAPSHOT_END" "$SINCE" "$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)" <<'PY'
import csv, gzip, json, sys, pathlib
out, tenant, window, end, since, sha = sys.argv[1:7]
data = pathlib.Path(out, 'payload', 'data')
counts = {p.name[:-7]: sum(1 for _ in csv.reader(gzip.open(p, 'rt', newline=''))) - 1 for p in sorted(data.glob('*.csv.gz'))}   # rows, not lines: fields may contain newlines
types = {}
for l in open(pathlib.Path(out, 'private', 'columns.tsv')):
    s, t, k, c, ty = l.rstrip('\n').split('\t')
    if f'{s}.{t}' in counts:
        types.setdefault(f'{s}.{t}', {})[c] = ty
json.dump({'tenant': int(tenant), 'window_days': int(window), 'snapshot_end': end, 'since': since,
           'source_commit': sha, 'row_counts': counts, 'column_types': types},
          open(pathlib.Path(out, 'payload', 'metadata.json'), 'w'), indent=1)
print(f'{len(counts)} tables, {sum(counts.values())} rows')
PY
echo "== 7. load plan (load.sql: run by the seed image at first start with -v delta_days=N)"
# mode-replace tables are generated at load (validate.py rule 5 guarantees one generator per replace table)
mkdir -p "$OUT/payload/generators" && cp "$CONF/generators/"*.sql "$OUT/payload/generators/"
python3 - "$OUT" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1]); meta = json.load(open(out / 'payload' / 'metadata.json'))
cagg = sorted({f'{l.split(chr(9))[0]}.{l.split(chr(9))[1]}' for l in open(out / 'private' / 'columns.tsv') if l.split('\t')[2] == 'cagg'})
hyper = sorted({f'{l.split(chr(9))[0]}.{l.split(chr(9))[1]}' for l in open(out / 'private' / 'columns.tsv') if l.split('\t')[2] == 'hypertable'})
D = "make_interval(days => :delta_days)"
def expr(c, ty):
    q = f'"{c}"'
    if ty.startswith('timestamp'):
        return f'{q} + {D}'
    if ty == 'date':
        return f'{q} + :delta_days'
    if ty == 'tstzrange':
        return (f"CASE WHEN {q} IS NULL OR isempty({q}) THEN {q} ELSE tstzrange(lower({q}) + {D}, upper({q}) + {D}, "
                f"(CASE WHEN lower_inc({q}) THEN '[' ELSE '(' END) || (CASE WHEN upper_inc({q}) THEN ']' ELSE ')' END)) END")
    return q
L = ['-- generated by extract.sh: loads /seed/data with every timestamp/date/tstzrange shifted by :delta_days (whole weeks)',
     '\\set ON_ERROR_STOP on', 'SET session_replication_role = replica;']
for table, n in meta['row_counts'].items():
    s, t = table.split('.', 1)
    import gzip, csv
    with gzip.open(out / 'payload' / 'data' / f'{table}.csv.gz', 'rt') as f:
        header = next(csv.reader(f))
    types = meta['column_types'][table]
    cols = ', '.join(f'"{c}"' for c in header)
    L += [f'-- {table}: {n} rows',
          f'CREATE TEMP TABLE _l (LIKE "{s}"."{t}");',
          f"COPY _l ({cols}) FROM PROGRAM 'gunzip -c /seed/data/{table}.csv.gz' WITH (FORMAT csv, HEADER, NULL '\\N');",
          f'INSERT INTO "{s}"."{t}" ({cols}) OVERRIDING SYSTEM VALUE SELECT {", ".join(expr(c, types[c]) for c in header)} FROM _l;',
          'DROP TABLE _l;',
          f"DO $$ BEGIN IF (SELECT count(*) FROM \"{s}\".\"{t}\") <> {n} THEN RAISE EXCEPTION 'devseed: {table} row count mismatch'; END IF; END $$;"]
gens = sorted(p.name for p in (out / 'payload' / 'generators').glob('*.sql'))
L += ['SET session_replication_role = origin;',
      *[f"\\i /seed/generators/{g}" for g in gens],
      "UPDATE core.enterprises SET api_key = 'dev-api-key-' || id_enterprise;",
      *[f"CALL refresh_continuous_aggregate('{c}', now() - interval '60 days', now() + interval '1 day');" for c in cagg],
      *[f"SELECT count(*) AS dropped_{i} FROM drop_chunks('{h}', older_than => now() - interval '35 days');" for i, h in enumerate(hyper)],
      'ANALYZE;']
(out / 'payload' / 'load.sql').write_text('\n'.join(L) + '\n')
print(f"load.sql: {len(meta['row_counts'])} tables, {len(cagg)} caggs, {len(hyper)} hypertables")
PY
echo "DONE: payload in $OUT/payload (package it); $OUT/private holds tokens + raw inventory: delete after the build"
