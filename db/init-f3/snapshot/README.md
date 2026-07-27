# db/init-f3/snapshot — the authoritative F3 schema DDL (GATED, not yet populated)

`compose.production.yml`'s `db-schema-f3` one-shot applies every `*.sql` here, in
alphabetical order, against the fresh prod DB — assembling F3 as `public`.

**This directory is intentionally empty of SQL right now.** It is populated by the
gated producer:

```sh
./scripts/capture-f3-snapshot.sh        # needs USER go (staging DB read)
```

which writes ordered, curated `NN-*.sql` files here (a schema-only, data-free dump
of staging `packiot_shadow`, with staging debris + fixtures excluded and cagg
policies re-tuned for prod — see ../README.md §4).

Until then, `db-schema-f3` exits 0 with a loud warning and builds nothing, and
`scripts/prod-f3-schema-parity-check.sh gate` FAILs — the intended safe state:
no client data flows into prod F3 until the schema is proven == `packiot_shadow`.

Do NOT hand-write schema files here. The whole point (../README.md §3) is that a
hand-assembled schema does not reach parity; the snapshot must be dumped FROM the
authoritative live F3 so it matches by construction.
