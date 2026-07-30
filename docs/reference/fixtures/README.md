# Edge-Source Contract — Golden Fixtures

Canonical, conformant birth declarations for the [edge-source topic contract](../edge-source-topic-contract.md)
(ADR-0046). They validate against [`../schemas/edge-birth-declaration.schema.json`](../schemas/edge-birth-declaration.schema.json).

**These are the shared goldens.** `edge-transformer` (the consumer) and every producer
(the native `sparkplug-agent`, a client tee, HighByte) test against the *same* fixtures.
That shared golden — not a fallback parser — is the compatibility guarantee that lets the
legacy string-grammar scaffold be **deleted** once all producers converge.

| Fixture | Tenant | Shows |
|---|---|---|
| `cpack-birth-example.json` | CPACK | SparkPlug-native: a line device (gross+net from two counters) + a machine device (gross+net+scrap). Roles explicit; index only in `source_ref`. |
| `bisnago-birth-example.json` | BISNAGO | Numeric-counter client: the dumb tee resolves count-index→role at the edge and emits role-typed metrics. **NB:** bisnago's actual gross-vs-net assignment is *tee-gated* (the 2-ids-per-line question, `reference_plc_line_cardinality`) — this fixture shows the *target shape* once the live tee confirms which counter is infeed. |

Validate locally:
```
python3 - <<'PY'
import json, glob
try:
    import jsonschema
except ImportError:
    raise SystemExit("pip install jsonschema")
schema = json.load(open("docs/reference/schemas/edge-birth-declaration.schema.json"))
for f in glob.glob("docs/reference/fixtures/*-birth-example.json"):
    jsonschema.validate(json.load(open(f)), schema)
    print("OK", f)
PY
```
