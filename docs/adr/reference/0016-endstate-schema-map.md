# End-state schema map — the refactored database at consolidation

Six layers + the absent seventh. The promotion-gate view.

1. **Ingest (raw truth)**: equipment_values (hypertable, dedup key,
   constraint-light, 180d), equipment_events(_man), user_logs (audit +
   replay backbone).
2. **Reference & config (public)**: enterprises→sites→areas→equipments;
   packml_register, shifts, shift_hours; products/product_families/
   clients/users/language_packs; DESCRIPTORS: label_formats,
   box_production_bridges (customization as rows).
3. **Time buckets (CAggs, real-time + policies)**:
   agg_equipment_values_{1min,10min,1hour}, ca_discrete_changes_1s,
   ca_equipment_boxes_{1s,1hour}. Pure math.
4. **Business windows (P3b)**: production_orders (natural key, partial
   UNIQUE running, ts CHECKs), production_orders_runtime (gist EXCLUDE
   anti-overlap), {equipment,area,site}_runtime_{shift,1hour,1day,
   1week,1month}.
5. **Current-state (UNS)**: uns_{equipment,area}_current_* +
   uns_site_current_* + uns_equipment_current_metrics — one row per
   entity, ms reads.
6. **Customer pools (customer_reports)**: shift, speed, boxes (flipped
   ✅), sap_data_sync (owner-gated), production_sync (config-ready).
   Legacy _NN names = façades until Wave 4.
7. **Absent by ledger**: uns_metrics, monitoramento_*, dead c35,
   version-sprawl generations, façades post-repoint, Hasura metadata.

One sentence: raw truth flows through buckets into business windows
and current caches, guided by reference data, configured by
descriptors, exported through tenant-keyed pools — every
customer-specific NAME reduced to a customer_id VALUE.
