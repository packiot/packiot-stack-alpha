#!/usr/bin/env bash
# refill-shift-history.sh — recompute an enterprise's LINE shift history ONE DAY PER TICK (newest→oldest)
# after a bulk speed/target change, without stalling the shared shift rollup (a big flagged
# batch of counters-only lines blows the job deadline and rolls back EVERY tenant's shifts).
# Success = the day drains; a day that does not drain in 8 min is unflagged and the run STOPS.
# Run ON the DB box:  ENT=5 FROM=2 TO=13 bash refill-shift-history.sh
ENT="${ENT:?}"; FROM="${FROM:-2}"; TO="${TO:-13}"
P(){ docker exec timescaledb psql -U postgres -d packiot_analytics -At -c "SET statement_timeout='60s'; $1" | tail -1; }
for d in $(seq "$FROM" "$TO"); do
  P "UPDATE gold.equipment_oee_shift o SET recalc_needed=true FROM core.equipments e WHERE o.id_equipment=e.id_equipment AND e.id_enterprise=$ENT AND e.tp_equipment=3 AND o.ts_value >= now()-interval '$((d+1)) days' AND o.ts_value < now()-interval '$d days'" >/dev/null
  ok=0
  for t in $(seq 1 16); do sleep 30
    C=$(P "SELECT count(*) FROM gold.equipment_oee_shift o JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise=$ENT AND e.tp_equipment=3 AND o.recalc_needed AND o.ts_value < now()-interval '$d days' AND o.ts_value >= now()-interval '30 days'")
    [ "$C" = 0 ] && { echo "$(date -u +%T) day -$d recomputed"; ok=1; break; }
  done
  if [ $ok = 0 ]; then
    P "UPDATE gold.equipment_oee_shift o SET recalc_needed=false FROM core.equipments e WHERE o.id_equipment=e.id_equipment AND e.id_enterprise=$ENT AND e.tp_equipment=3 AND o.recalc_needed AND o.ts_value < now()-interval '$d days'" >/dev/null
    echo "$(date -u +%T) day -$d did NOT drain in 8 min — unflagged, STOP"; exit 1
  fi
done; echo "$(date -u +%T) DONE"
