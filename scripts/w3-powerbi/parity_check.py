#!/usr/bin/env python3
"""parity_check.py — W3 per-report parity gate (PREP STUB).

Proves a migrated Metabase report matches the PowerBI original for the SAME
tenant + period, within tolerance. This is the per-report sign-off gate
(docs/plans/w3-powerbi-migration-readiness.md §4).

THREE-WAY TIE-OUT per measure:
    powerbi (DAX export CSV)  ≈  postgres (ground-truth SQL)  ≈  metabase (migrated)
  - powerbi != postgres  -> a hidden DAX semantic (filter/tz/blank) to re-express
  - metabase != postgres -> the rebuild is wrong

Reuses the read-only prod pattern from scripts/powerbi-evidence-prod-read.sh
(BEGIN READ ONLY — prod is SELECT-only forever). Point PG* at a READ REPLICA.

STUB STATUS: the diff/tolerance engine is real; the three fetchers are marked
TODO — wire them when the target Metabase + a .pbix export exist. No network
calls are made until then, so this is safe to run/inspect now.

Spec file (YAML) per report — e.g. w3-powerbi/parity-specs/shift06.yaml:
    report: report_shift_enterprsie_06
    tenant_id: 6
    windows:
      - {start: "2026-07-01", end: "2026-08-01"}   # closed window (settled)
    measures:
      oee_quality:   {tol_abs: 0.001, tol_rel: 0.0, reason: "OEE ratio"}
      boxes_total:   {tol_abs: 0,     tol_rel: 0.0, reason: "counts must be exact"}
      avg_speed:     {tol_abs: 0.1,   tol_rel: 0.0}
    sources:
      powerbi_csv: exports/shift06_2026-07.csv      # DAX Studio export for this window
      postgres_sql: sql/shift06_groundtruth.sql     # {tenant_id},{start},{end} placeholders
      metabase:
        question_id: 123        # OR refdata_url: https://refdata.../v1/...
"""
from __future__ import annotations
import argparse, csv, sys
from dataclasses import dataclass

try:
    import yaml  # pip install pyyaml
except ImportError:
    print("need pyyaml: pip install pyyaml", file=sys.stderr); sys.exit(2)


@dataclass
class Tol:
    tol_abs: float = 0.0
    tol_rel: float = 0.0
    reason: str = ""


def within(expected: float, actual: float, t: Tol) -> bool:
    d = abs(expected - actual)
    if d <= t.tol_abs:
        return True
    if t.tol_rel and expected != 0 and d / abs(expected) <= t.tol_rel:
        return True
    return False


# ── fetchers (TODO: wire when targets exist) ────────────────────────────────
def fetch_powerbi(spec, window) -> dict[str, float]:
    """Load the DAX-Studio-exported CSV for this window → {measure: value}."""
    path = spec["sources"]["powerbi_csv"]
    out: dict[str, float] = {}
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            # expected columns: measure,value  (adapt to your DAX export shape)
            out[row["measure"]] = float(row["value"])
    return out


def fetch_postgres(spec, window) -> dict[str, float]:
    """Run the ground-truth SQL READ-ONLY against a Postgres read-replica.

    TODO: psycopg2 connect from PG* env; `SET TRANSACTION READ ONLY`;
    substitute {tenant_id},{start},{end}; return one row keyed by measure.
    Mirror scripts/powerbi-evidence-prod-read.sh's BEGIN READ ONLY guard.
    """
    raise NotImplementedError("wire postgres read-replica fetch (§4.1)")


def fetch_metabase(spec, window) -> dict[str, float]:
    """Run the migrated Metabase question (or refdata endpoint) → {measure: value}.

    TODO: POST /api/card/{question_id}/query/json with a session token, OR GET
    the refdata_url; map result columns → measures.
    """
    raise NotImplementedError("wire Metabase/refdata fetch (§4.2)")


# ── diff engine (real) ──────────────────────────────────────────────────────
def run(spec: dict) -> bool:
    tols = {m: Tol(**({k: v for k, v in cfg.items()})) for m, cfg in spec["measures"].items()}
    all_green = True
    for window in spec["windows"]:
        pbi = fetch_powerbi(spec, window)
        pg = fetch_postgres(spec, window)
        mb = fetch_metabase(spec, window)
        print(f"\n== window {window['start']}..{window['end']} (tenant {spec['tenant_id']}) ==")
        print(f"{'measure':<20}{'powerbi':>14}{'postgres':>14}{'metabase':>14}  verdict")
        for m, t in tols.items():
            e_pbi, e_pg, e_mb = pbi.get(m), pg.get(m), mb.get(m)
            leg1 = within(e_pbi, e_pg, t)      # DAX semantics vs source of truth
            leg2 = within(e_pg, e_mb, t)       # rebuild vs source of truth
            ok = leg1 and leg2
            all_green &= ok
            note = "" if ok else ("  <PBI≠PG: DAX gap>" if not leg1 else "  <MB≠PG: rebuild wrong>")
            print(f"{m:<20}{e_pbi:>14}{e_pg:>14}{e_mb:>14}  {'PASS' if ok else 'FAIL'}{note}")
    return all_green


def main() -> int:
    ap = argparse.ArgumentParser(description="W3 PowerBI↔Metabase parity gate")
    ap.add_argument("spec", help="parity spec YAML (see module docstring)")
    args = ap.parse_args()
    with open(args.spec) as fh:
        spec = yaml.safe_load(fh)
    green = run(spec)
    print("\nGATE:", "GREEN — safe to sign off this window set" if green else "RED — do NOT migrate")
    return 0 if green else 1


if __name__ == "__main__":
    sys.exit(main())
