# t-prodt169-po-totals-own-runtimes — rehearsal fixture

On a throwaway postgres:15 (never staging or production):

```bash
docker run -d --name p169-pg -e POSTGRES_PASSWORD=x postgres:15
psql … -f test/fixture.sql   # 4 relations + the PRE-migration view + AC-15 data (R1/R2/R3, gap stops)
psql … -f 01-up.sql
psql … -f test/run.sql       # replace R2 → each PO's downtime/produced/scrap = sums over its own runtimes
psql … -f rollback.sql       # old view: C3/C5 fail (R2's stop counted in both POs, gap stop counted)
psql … -f 01-up.sql          # idempotent re-apply
```
Every check line prints `got` and `want`.
