# ADR-0047 §1 — Counter-role resolver REMOVED (2026-08-26)

The DB-driven counter-role override (ADR-0047 P0 #1 — the
`internal/counterroles` resolver + the `Message.RoleKind`/`RoleUnitTopic`
wiring in `calc_production_counters`) was **removed entirely** on 2026-08-26,
not merely left disabled.

Root cause: it read `packml_register.id_infeedcounter` /
`id_outfeedcounter` / `id_rejectcounter` to infer each counter's gross/net/scrap
role, but a **sibling feature — Phase-9 line aggregation
(`cmd/edge-transformer/line_param30700_seed.go`) — already uses those same
columns as wire count-indices.** The overlap produced the CPACK L5 net-phantom
(disabled via commit `1ecbb072`). The feature had no real consumer: no tenant
populated those columns for the role-override purpose, and `COUNTER_ROLES_FROM_DB`
defaulted false (so the resolver was never constructed and every override branch
was already dead at runtime — removal is behavior-preserving).

Requirement for any future re-attempt: a DB-driven counter-role override MUST
introduce its own **dedicated** columns — e.g. `id_infeed_equipment`,
`id_outfeed_equipment`, `id_reject_equipment` — that are distinct from the
count-index columns Phase-9 owns. Do not reuse the `id_*counter` columns.
