# PowerBI gate — prod-read fidelity evidence

- Generated: 2026-07-06 20:38Z by scripts/powerbi-evidence-prod-read.sh
- Method: ported writers' computation re-run against PROD inputs
  (BEGIN READ ONLY, awslambda), compared with prod's live report
  tables. Port-time baselines: shift06 1197/1197 rows (1180 exact,
  98.6% — remainder is the moving-base artifact class), speed33 63/68.

- `BEGIN`
- `SET`
- `SPEED33 computed=88 live=82 joined=81 exact=78`
- `SHIFT06 computed=1182 live=62032 exact=1165`
- `ROLLBACK`

- Non-exact remainders are expected from the moving-base artifact
  class (prod keeps writing while we read; see PORTING.md artifact
  taxonomy). Sign-off threshold: joined/exact ratios consistent with
  port-time baselines.
