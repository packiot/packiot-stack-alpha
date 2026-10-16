# t-ts-c3-partition-tooling — rehearsal fixture

On a throwaway TimescaleDB 2.27.0-pg15:

```bash
docker run -d --name c3-pg -e POSTGRES_PASSWORD=x timescale/timescaledb:2.27.0-pg15
psql … -f test/fixture.sql   # events-like (identity, shared sequence, compression, view, grants, comments, retention row),
                             # plc-like (forced RLS + policy), bronze-like (immutability trigger)
psql … -f 01-up.sql
psql … -f test/run.sql       # prepare → copy → changes AFTER the copy → swap → 18 checks
```
Every check line says what it wants (`want …`). 2026-10-15: all pass.
