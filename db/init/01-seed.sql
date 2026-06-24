-- ── Enterprise 1: Dev Enterprise ─────────────────────────────────────────────
INSERT INTO enterprises (id_enterprise, nm_enterprise, api_key)
VALUES (1, 'Dev Enterprise', 'dev-api-key') ON CONFLICT DO NOTHING;

INSERT INTO sites (id_site, id_enterprise, nm_site)
VALUES (1, 1, 'Dev Site') ON CONFLICT DO NOTHING;

INSERT INTO areas (id_area, id_site, id_enterprise, nm_area)
VALUES (1, 1, 1, 'Dev Area') ON CONFLICT DO NOTHING;

INSERT INTO equipments (id_equipment, id_area, id_site, id_enterprise, cd_equipment, nm_equipment, tp_equipment, status_type, production_speed, lead_machine)
VALUES
    (1, 1, 1, 1, 'MCH-01', 'Machine-01', 1, 1, 120, NULL),
    (2, 1, 1, 1, 'LN-01',  'Line-01',    3, 1, 120, 1)     -- lead machine = Machine-01
ON CONFLICT DO NOTHING;

INSERT INTO packml_register (id_enterprise, id_site, id_area, id_equipment, packml_topic, active, id_unit)
VALUES
    (1, 1, 1, 1, 'Dev Enterprise/Dev Site/Dev Area/Line-01/Machine-01', true, 1),
    (1, 1, 1, 2, 'Dev Enterprise/Dev Site/Dev Area/Line-01',            true, NULL)
ON CONFLICT DO NOTHING;

-- ── Enterprise 2: Demo Factory (second enterprise for multi-tenant debugging) ─
INSERT INTO enterprises (id_enterprise, nm_enterprise, api_key)
VALUES (2, 'Demo Factory', 'demo-api-key') ON CONFLICT DO NOTHING;

INSERT INTO sites (id_site, id_enterprise, nm_site)
VALUES (2, 2, 'Factory Site') ON CONFLICT DO NOTHING;

INSERT INTO areas (id_area, id_site, id_enterprise, nm_area)
VALUES (2, 2, 2, 'Assembly Area') ON CONFLICT DO NOTHING;

INSERT INTO equipments (id_equipment, id_area, id_site, id_enterprise, cd_equipment, nm_equipment, tp_equipment, status_type, production_speed, lead_machine)
VALUES
    (3, 2, 2, 2, 'ASM-MCH-01', 'Assembly-Machine-01', 1, 1, 120, NULL),
    (4, 2, 2, 2, 'ASM-LN-01',  'Assembly-Line-01',    3, 1, 120, 3)     -- lead machine = Assembly-Machine-01
ON CONFLICT DO NOTHING;

INSERT INTO packml_register (id_enterprise, id_site, id_area, id_equipment, packml_topic, active, id_unit)
VALUES
    (2, 2, 2, 3, 'Demo Factory/Factory Site/Assembly Area/Assembly-Line-01/Assembly-Machine-01', true, 3),
    (2, 2, 2, 4, 'Demo Factory/Factory Site/Assembly Area/Assembly-Line-01',                     true, NULL)
ON CONFLICT DO NOTHING;

-- ── Shifts ───────────────────────────────────────────────────────────────────
-- Generic 3-shift pattern: T1 06:00-14:00, T2 14:00-22:00, T3 22:00-06:00
-- begin_time/end_time = seconds from week_begin (Monday 00:00 = 0)
-- Mon=0, Tue=86400, Wed=172800, Thu=259200, Fri=345600

INSERT INTO shifts (id_shift, id_site, id_area, cd_shift, nm_shift)
VALUES
    (1, 1, 1, 'T1', 'Morning'),
    (2, 1, 1, 'T2', 'Afternoon'),
    (3, 1, 1, 'T3', 'Night'),
    (4, 2, 2, 'T1', 'Morning'),
    (5, 2, 2, 'T2', 'Afternoon'),
    (6, 2, 2, 'T3', 'Night')
ON CONFLICT DO NOTHING;

INSERT INTO shift_hours (id_shift, begin_time, end_time)
VALUES
    -- ── Site 1 / Dev Area ────────────────────────────────────────────────────
    -- Monday
    (1,  21600,  50400), (2,  50400,  79200), (3,  79200, 108000),
    -- Tuesday
    (1, 108000, 136800), (2, 136800, 165600), (3, 165600, 194400),
    -- Wednesday
    (1, 194400, 223200), (2, 223200, 252000), (3, 252000, 280800),
    -- Thursday
    (1, 280800, 309600), (2, 309600, 338400), (3, 338400, 367200),
    -- Friday
    (1, 367200, 396000), (2, 396000, 424800), (3, 424800, 453600),
    -- ── Site 2 / Assembly Area ───────────────────────────────────────────────
    -- Monday
    (4,  21600,  50400), (5,  50400,  79200), (6,  79200, 108000),
    -- Tuesday
    (4, 108000, 136800), (5, 136800, 165600), (6, 165600, 194400),
    -- Wednesday
    (4, 194400, 223200), (5, 223200, 252000), (6, 252000, 280800),
    -- Thursday
    (4, 280800, 309600), (5, 309600, 338400), (6, 338400, 367200),
    -- Friday
    (4, 367200, 396000), (5, 396000, 424800), (6, 424800, 453600)
ON CONFLICT DO NOTHING;

-- ── Enterprises 3 & 4 — layout ───────────────────────────────────────────────
--
--  Enterprise 3: AutoParts Corp
--    Site 3: Detroit Plant
--      Area 3: Stamping  → eq  5 PRESS-01 (machine)
--                           eq  6 Stamping-Line-01 (line, tp=3, lead=5)
--      Area 4: Welding   → eq  7 Welder-01 (machine, lead machine for sector)
--                           eq  8 Welding-Line-01 (line, tp=3, lead=7)  ← parent line
--                           eq  9 Welding-Sector-01 (sector, tp=2, lead=7)
--    Site 4: Chicago Plant
--      Area 5: Machining → eq 10 CNC-01 (machine)
--                           eq 11 Machining-Line-01 (line, tp=3, lead=10)
--      Area 6: Assembly  → eq 12 Assembly-01 (machine)
--                           eq 13 Assembly-Line-01 (line, tp=3, lead=12)
--
--  Enterprise 4: FoodCo Industries
--    Site 5: Sao Paulo Plant
--      Area 7: Processing → eq 14 Processor-01 (machine)
--                            eq 15 Processing-Line-01 (line, tp=3, lead=14)
--      Area 8: Packaging  → eq 16 Packer-01 (machine)
--                            eq 17 Packaging-Line-01 (line, tp=3, lead=16)
--    Site 6: Buenos Aires Plant
--      Area 9: Bottling   → eq 18 Filler-01 (machine)
--                            eq 19 Bottling-Line-01 (line, tp=3, lead=18)
--      Area 10: Labeling  → eq 20 Labeler-01 (machine)
--                            eq 21 Labeling-Line-01 (line, tp=3, lead=20)
--
--  Equipment IDs 5–21 (17 units, 2 enterprises + 4 sites + 8 areas).
--  packml_topic convention (from production):
--    line   : Enterprise/Site/Area/Line
--    sector : Enterprise/Site/Area/Line::Sector      ← sector name appended to Line in slot [3]
--    machine: Enterprise/Site/Area/Line::Sector/Mach ← 5-segment UNIT-LEVEL
--  Sector ALWAYS has a separate parent line entry alongside it (V4 + V4::PRESS pattern).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Enterprise 3: AutoParts Corp ─────────────────────────────────────────────
INSERT INTO enterprises (id_enterprise, nm_enterprise, api_key)
VALUES (3, 'AutoParts Corp', 'autoparts-api-key') ON CONFLICT DO NOTHING;

INSERT INTO sites (id_site, id_enterprise, nm_site)
VALUES
    (3, 3, 'Detroit Plant'),
    (4, 3, 'Chicago Plant')
ON CONFLICT DO NOTHING;

INSERT INTO areas (id_area, id_site, id_enterprise, nm_area)
VALUES
    (3,  3, 3, 'Stamping'),
    (4,  3, 3, 'Welding'),
    (5,  4, 3, 'Machining'),
    (6,  4, 3, 'Assembly')
ON CONFLICT DO NOTHING;

INSERT INTO equipments (id_equipment, id_area, id_site, id_enterprise, cd_equipment, nm_equipment, tp_equipment, status_type, production_speed, lead_machine)
VALUES
    ( 5,  3, 3, 3, 'PRESS-01',   'Press-01',           1, 1,  80, NULL),
    ( 6,  3, 3, 3, 'STM-LN-01',  'Stamping-Line-01',   3, 1,  80,    5),
    ( 7,  4, 3, 3, 'WLD-01',     'Welder-01',          1, 1,  60, NULL),
    ( 8,  4, 3, 3, 'WLD-LN-01',  'Welding-Line-01',    3, 1,  60,    7),  -- parent line for sector
    ( 9,  4, 3, 3, 'WLD-SEC-01', 'Welding-Sector-01',  2, 1,  60,    7),  -- sector (tp=2)
    (10,  5, 4, 3, 'CNC-01',     'CNC-01',             1, 1,  40, NULL),
    (11,  5, 4, 3, 'MCH-LN-01',  'Machining-Line-01',  3, 1,  40,   10),
    (12,  6, 4, 3, 'ASM-01',     'Assembly-01',        1, 1, 100, NULL),
    (13,  6, 4, 3, 'ASM-LN-01',  'Assembly-Line-01',   3, 1, 100,   12)
ON CONFLICT DO NOTHING;

INSERT INTO packml_register (id_enterprise, id_site, id_area, id_equipment, packml_topic, active, id_unit)
VALUES
    (3, 3, 3,  5, 'AutoParts Corp/Detroit Plant/Stamping/Stamping-Line-01/Press-01',                          true,  5),
    (3, 3, 3,  6, 'AutoParts Corp/Detroit Plant/Stamping/Stamping-Line-01',                                   true, NULL),
    (3, 3, 4,  7, 'AutoParts Corp/Detroit Plant/Welding/Welding-Line-01::Welding-Sector-01/Welder-01',        true,  7),
    (3, 3, 4,  8, 'AutoParts Corp/Detroit Plant/Welding/Welding-Line-01',                                     true, NULL),
    (3, 3, 4,  9, 'AutoParts Corp/Detroit Plant/Welding/Welding-Line-01::Welding-Sector-01',                  true, NULL),
    (3, 4, 5, 10, 'AutoParts Corp/Chicago Plant/Machining/Machining-Line-01/CNC-01',                          true, 10),
    (3, 4, 5, 11, 'AutoParts Corp/Chicago Plant/Machining/Machining-Line-01',                                 true, NULL),
    (3, 4, 6, 12, 'AutoParts Corp/Chicago Plant/Assembly/Assembly-Line-01/Assembly-01',                       true, 12),
    (3, 4, 6, 13, 'AutoParts Corp/Chicago Plant/Assembly/Assembly-Line-01',                                   true, NULL)
ON CONFLICT DO NOTHING;

-- ── Enterprise 4: FoodCo Industries ──────────────────────────────────────────
INSERT INTO enterprises (id_enterprise, nm_enterprise, api_key)
VALUES (4, 'FoodCo Industries', 'foodco-api-key') ON CONFLICT DO NOTHING;

INSERT INTO sites (id_site, id_enterprise, nm_site)
VALUES
    (5, 4, 'Sao Paulo Plant'),
    (6, 4, 'Buenos Aires Plant')
ON CONFLICT DO NOTHING;

INSERT INTO areas (id_area, id_site, id_enterprise, nm_area)
VALUES
    ( 7,  5, 4, 'Processing'),
    ( 8,  5, 4, 'Packaging'),
    ( 9,  6, 4, 'Bottling'),
    (10,  6, 4, 'Labeling')
ON CONFLICT DO NOTHING;

INSERT INTO equipments (id_equipment, id_area, id_site, id_enterprise, cd_equipment, nm_equipment, tp_equipment, status_type, production_speed, lead_machine)
VALUES
    (14,  7, 5, 4, 'PROC-01',    'Processor-01',       1, 1, 200, NULL),
    (15,  7, 5, 4, 'PROC-LN-01', 'Processing-Line-01', 3, 1, 200,   14),
    (16,  8, 5, 4, 'PKG-01',     'Packer-01',          1, 1, 300, NULL),
    (17,  8, 5, 4, 'PKG-LN-01',  'Packaging-Line-01',  3, 1, 300,   16),
    (18,  9, 6, 4, 'BTL-01',     'Filler-01',          1, 1, 150, NULL),
    (19,  9, 6, 4, 'BTL-LN-01',  'Bottling-Line-01',   3, 1, 150,   18),
    (20, 10, 6, 4, 'LBL-01',     'Labeler-01',         1, 1, 250, NULL),
    (21, 10, 6, 4, 'LBL-LN-01',  'Labeling-Line-01',   3, 1, 250,   20)
ON CONFLICT DO NOTHING;

INSERT INTO packml_register (id_enterprise, id_site, id_area, id_equipment, packml_topic, active, id_unit)
VALUES
    (4, 5,  7, 14, 'FoodCo Industries/Sao Paulo Plant/Processing/Processing-Line-01/Processor-01', true, 14),
    (4, 5,  7, 15, 'FoodCo Industries/Sao Paulo Plant/Processing/Processing-Line-01',               true, NULL),
    (4, 5,  8, 16, 'FoodCo Industries/Sao Paulo Plant/Packaging/Packaging-Line-01/Packer-01',       true, 16),
    (4, 5,  8, 17, 'FoodCo Industries/Sao Paulo Plant/Packaging/Packaging-Line-01',                 true, NULL),
    (4, 6,  9, 18, 'FoodCo Industries/Buenos Aires Plant/Bottling/Bottling-Line-01/Filler-01',      true, 18),
    (4, 6,  9, 19, 'FoodCo Industries/Buenos Aires Plant/Bottling/Bottling-Line-01',                true, NULL),
    (4, 6, 10, 20, 'FoodCo Industries/Buenos Aires Plant/Labeling/Labeling-Line-01/Labeler-01',     true, 20),
    (4, 6, 10, 21, 'FoodCo Industries/Buenos Aires Plant/Labeling/Labeling-Line-01',                true, NULL)
ON CONFLICT DO NOTHING;

-- ── Shifts for new sites (same Mon–Fri 3-shift pattern) ──────────────────────
INSERT INTO shifts (id_shift, id_site, id_area, cd_shift, nm_shift)
VALUES
    ( 7, 3, 3, 'T1', 'Morning'),   ( 8, 3, 3, 'T2', 'Afternoon'),   ( 9, 3, 3, 'T3', 'Night'),
    (10, 3, 4, 'T1', 'Morning'),   (11, 3, 4, 'T2', 'Afternoon'),   (12, 3, 4, 'T3', 'Night'),
    (13, 4, 5, 'T1', 'Morning'),   (14, 4, 5, 'T2', 'Afternoon'),   (15, 4, 5, 'T3', 'Night'),
    (16, 4, 6, 'T1', 'Morning'),   (17, 4, 6, 'T2', 'Afternoon'),   (18, 4, 6, 'T3', 'Night'),
    (19, 5, 7, 'T1', 'Morning'),   (20, 5, 7, 'T2', 'Afternoon'),   (21, 5, 7, 'T3', 'Night'),
    (22, 5, 8, 'T1', 'Morning'),   (23, 5, 8, 'T2', 'Afternoon'),   (24, 5, 8, 'T3', 'Night'),
    (25, 6, 9, 'T1', 'Morning'),   (26, 6, 9, 'T2', 'Afternoon'),   (27, 6, 9, 'T3', 'Night'),
    (28, 6,10, 'T1', 'Morning'),   (29, 6,10, 'T2', 'Afternoon'),   (30, 6,10, 'T3', 'Night')
ON CONFLICT DO NOTHING;

INSERT INTO shift_hours (id_shift, begin_time, end_time)
VALUES
    -- Sites 3–6 all use same Mon–Fri T1/T2/T3 windows (shifts 7–30 follow same offsets)
    -- Mon
     (7,21600,50400),(8,50400,79200),(9,79200,108000),
    (10,21600,50400),(11,50400,79200),(12,79200,108000),
    (13,21600,50400),(14,50400,79200),(15,79200,108000),
    (16,21600,50400),(17,50400,79200),(18,79200,108000),
    (19,21600,50400),(20,50400,79200),(21,79200,108000),
    (22,21600,50400),(23,50400,79200),(24,79200,108000),
    (25,21600,50400),(26,50400,79200),(27,79200,108000),
    (28,21600,50400),(29,50400,79200),(30,79200,108000),
    -- Tue
     (7,108000,136800),(8,136800,165600),(9,165600,194400),
    (10,108000,136800),(11,136800,165600),(12,165600,194400),
    (13,108000,136800),(14,136800,165600),(15,165600,194400),
    (16,108000,136800),(17,136800,165600),(18,165600,194400),
    (19,108000,136800),(20,136800,165600),(21,165600,194400),
    (22,108000,136800),(23,136800,165600),(24,165600,194400),
    (25,108000,136800),(26,136800,165600),(27,165600,194400),
    (28,108000,136800),(29,136800,165600),(30,165600,194400),
    -- Wed
     (7,194400,223200),(8,223200,252000),(9,252000,280800),
    (10,194400,223200),(11,223200,252000),(12,252000,280800),
    (13,194400,223200),(14,223200,252000),(15,252000,280800),
    (16,194400,223200),(17,223200,252000),(18,252000,280800),
    (19,194400,223200),(20,223200,252000),(21,252000,280800),
    (22,194400,223200),(23,223200,252000),(24,252000,280800),
    (25,194400,223200),(26,223200,252000),(27,252000,280800),
    (28,194400,223200),(29,223200,252000),(30,252000,280800),
    -- Thu
     (7,280800,309600),(8,309600,338400),(9,338400,367200),
    (10,280800,309600),(11,309600,338400),(12,338400,367200),
    (13,280800,309600),(14,309600,338400),(15,338400,367200),
    (16,280800,309600),(17,309600,338400),(18,338400,367200),
    (19,280800,309600),(20,309600,338400),(21,338400,367200),
    (22,280800,309600),(23,309600,338400),(24,338400,367200),
    (25,280800,309600),(26,309600,338400),(27,338400,367200),
    (28,280800,309600),(29,309600,338400),(30,338400,367200),
    -- Fri
     (7,367200,396000),(8,396000,424800),(9,424800,453600),
    (10,367200,396000),(11,396000,424800),(12,424800,453600),
    (13,367200,396000),(14,396000,424800),(15,424800,453600),
    (16,367200,396000),(17,396000,424800),(18,424800,453600),
    (19,367200,396000),(20,396000,424800),(21,424800,453600),
    (22,367200,396000),(23,396000,424800),(24,424800,453600),
    (25,367200,396000),(26,396000,424800),(27,424800,453600),
    (28,367200,396000),(29,396000,424800),(30,424800,453600)
ON CONFLICT DO NOTHING;

-- ── Production orders ────────────────────────────────────────────────────────
-- status: 1=available 2=running 3=finished 4=paused
-- POs 1-10: currently running
-- POs 11-15: finished earlier today (ts_end + production_final set)
-- POs 16-18: paused mid-run (status=4, runtime rows all closed)

INSERT INTO production_orders (id_production_order, id_enterprise, id_site, id_area, id_equipment, nm_production_order, status, ts_start, ts_end, production_final)
VALUES
    -- Running
    ( 1, 1, 1, 1,  2, 'PO-DEV-001',   2, NOW()-INTERVAL '2 hours',  NULL, NULL),
    ( 2, 2, 2, 2,  4, 'PO-DEMO-001',  2, NOW()-INTERVAL '1 hour',   NULL, NULL),
    ( 3, 3, 3, 3,  6, 'PO-APC-001',   2, NOW()-INTERVAL '3 hours',  NULL, NULL),
    ( 4, 3, 3, 4,  9, 'PO-APC-002',   2, NOW()-INTERVAL '2 hours',  NULL, NULL),
    ( 5, 3, 4, 5, 11, 'PO-APC-003',   2, NOW()-INTERVAL '4 hours',  NULL, NULL),
    ( 6, 3, 4, 6, 13, 'PO-APC-004',   2, NOW()-INTERVAL '1 hour',   NULL, NULL),
    ( 7, 4, 5, 7, 15, 'PO-FCI-001',   2, NOW()-INTERVAL '5 hours',  NULL, NULL),
    ( 8, 4, 5, 8, 17, 'PO-FCI-002',   2, NOW()-INTERVAL '2 hours',  NULL, NULL),
    ( 9, 4, 6, 9, 19, 'PO-FCI-003',   2, NOW()-INTERVAL '3 hours',  NULL, NULL),
    (10, 4, 6,10, 21, 'PO-FCI-004',   2, NOW()-INTERVAL '1 hour',   NULL, NULL),
    -- Finished (status=3)
    (11, 1, 1, 1,  2, 'PO-DEV-000',   3, NOW()-INTERVAL '8 hours',  NOW()-INTERVAL '2 hours',  11200),
    (12, 2, 2, 2,  4, 'PO-DEMO-000',  3, NOW()-INTERVAL '9 hours',  NOW()-INTERVAL '3 hours',   8400),
    (13, 3, 3, 3,  6, 'PO-APC-000',   3, NOW()-INTERVAL '10 hours', NOW()-INTERVAL '4 hours',  10800),
    (14, 3, 4, 5, 11, 'PO-APC-100',   3, NOW()-INTERVAL '12 hours', NOW()-INTERVAL '5 hours',   4200),
    (15, 4, 5, 7, 15, 'PO-FCI-000',   3, NOW()-INTERVAL '7 hours',  NOW()-INTERVAL '1 hour',   41000),
    -- Paused (status=4)
    (16, 3, 3, 4,  9, 'PO-APC-200',   4, NOW()-INTERVAL '5 hours',  NULL, NULL),
    (17, 4, 5, 8, 17, 'PO-FCI-100',   4, NOW()-INTERVAL '4 hours',  NULL, NULL),
    (18, 3, 4, 6, 13, 'PO-APC-300',   4, NOW()-INTERVAL '6 hours',  NULL, NULL)
ON CONFLICT (id_production_order) DO NOTHING;

-- ── Production order runtimes ─────────────────────────────────────────────────
-- running  → 1 open segment (ts_end IS NULL)
-- finished → 1 closed segment (ts_end NOT NULL)
-- paused   → ran for a while, then closed (ts_end NOT NULL, PO status=4)

INSERT INTO production_order_runtime (id_production_order, id_enterprise, id_equipment, ts_start, ts_end, net_production, scrap)
VALUES
    -- Running POs
    ( 1, 1,  2, NOW()-INTERVAL '2 hours',  NULL,  11200,  350),
    ( 2, 2,  4, NOW()-INTERVAL '1 hour',   NULL,   5500,  180),
    ( 3, 3,  6, NOW()-INTERVAL '3 hours',  NULL,   9800,  420),
    ( 4, 3,  9, NOW()-INTERVAL '2 hours',  NULL,   6800,  380),
    ( 5, 3, 11, NOW()-INTERVAL '4 hours',  NULL,   5600,  120),
    ( 6, 3, 13, NOW()-INTERVAL '1 hour',   NULL,   4800,  200),
    ( 7, 4, 15, NOW()-INTERVAL '5 hours',  NULL,  42000, 2800),
    ( 8, 4, 17, NOW()-INTERVAL '2 hours',  NULL,  28000, 1400),
    ( 9, 4, 19, NOW()-INTERVAL '3 hours',  NULL,  19800, 1200),
    (10, 4, 21, NOW()-INTERVAL '1 hour',   NULL,  14000,  600),
    -- Finished POs
    (11, 1,  2, NOW()-INTERVAL '8 hours',  NOW()-INTERVAL '2 hours',  11200,  350),
    (12, 2,  4, NOW()-INTERVAL '9 hours',  NOW()-INTERVAL '3 hours',   8400,  280),
    (13, 3,  6, NOW()-INTERVAL '10 hours', NOW()-INTERVAL '4 hours',  10800,  420),
    (14, 3, 11, NOW()-INTERVAL '12 hours', NOW()-INTERVAL '5 hours',   4200,  180),
    (15, 4, 15, NOW()-INTERVAL '7 hours',  NOW()-INTERVAL '1 hour',   41000, 2800),
    -- Paused POs (runtime closed when operator hit pause)
    (16, 3,  9, NOW()-INTERVAL '5 hours',  NOW()-INTERVAL '30 minutes',  7200, 420),
    (17, 4, 17, NOW()-INTERVAL '4 hours',  NOW()-INTERVAL '1 hour',     28000, 900),
    (18, 3, 13, NOW()-INTERVAL '6 hours',  NOW()-INTERVAL '45 minutes', 14400, 700)
ON CONFLICT DO NOTHING;

-- ── Historical equipment events (6-hour downtime history per lead machine) ────
-- Lead machines: 1,3,5,7 (ent 1-3), 10,12 (ent 3 Chicago), 14,16,18,20 (ent 4)
-- After rebuild the new IDs apply: CNC=10, Assembly-01=12, Processor=14 etc.
-- status: 6=Running/Execute  10=Held/Stopped
-- Machines currently stopped (ts_end IS NULL on most recent status=10): eq 1, 11(→12), 15(→16)

INSERT INTO equipment_events
    (ts_event, id_enterprise, id_equipment, status, txt_downtime_notes, forced_creation_system, planned_downtime, ts_end, duration)
VALUES
-- ── Machine-01 (eq=1, ent=1) ──────────────────────────────────────────────────
(NOW()-INTERVAL '5h 30m', 1,  1,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '4h 50m', 1,  1, 10, '[EQUIPMENT] Sensor fault',               true,  false, NOW()-INTERVAL '4h 35m', 900),
(NOW()-INTERVAL '4h 35m', 1,  1,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '3h 10m', 1,  1, 10, '[TOOLING] Tool change',                  true,  false, NOW()-INTERVAL '2h 50m', 1200),
(NOW()-INTERVAL '2h 50m', 1,  1,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '1h 20m', 1,  1, 10, '[SHORTAGE] Raw material shortage',       true,  false, NOW()-INTERVAL '1h 5m',  900),
(NOW()-INTERVAL '1h  5m', 1,  1,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '20m',    1,  1, 10, '[OTHERS] Unplanned stop',                true,  false, NULL, NULL),
-- ── Assembly-Machine-01 (eq=3, ent=2) ─────────────────────────────────────────
(NOW()-INTERVAL '4h',     2,  3,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '3h 20m', 2,  3, 10, '[MAINTENANCE] Scheduled maintenance',    true,  true,  NOW()-INTERVAL '3h',     1200),
(NOW()-INTERVAL '3h',     2,  3,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '1h 40m', 2,  3, 10, '[PROCESS] Quality hold',                 true,  false, NOW()-INTERVAL '1h 15m', 1500),
(NOW()-INTERVAL '1h 15m', 2,  3,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── Press-01 (eq=5, ent=3) ────────────────────────────────────────────────────
(NOW()-INTERVAL '6h',     3,  5,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '4h 30m', 3,  5, 10, '[EQUIPMENT] Drive fault',                true,  false, NOW()-INTERVAL '4h 10m', 1200),
(NOW()-INTERVAL '4h 10m', 3,  5,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h',     3,  5, 10, '[TOOLING] Die change',                   true,  false, NOW()-INTERVAL '1h 35m', 1500),
(NOW()-INTERVAL '1h 35m', 3,  5,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── Welder-01 (eq=7, ent=3) ───────────────────────────────────────────────────
(NOW()-INTERVAL '5h',     3,  7,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '4h 15m', 3,  7, 10, '[EQUIPMENT] Machine jam',                true,  false, NOW()-INTERVAL '4h',     900),
(NOW()-INTERVAL '4h',     3,  7,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h 30m', 3,  7, 10, '[PROCESS] Rejects above threshold',      true,  false, NOW()-INTERVAL '2h 10m', 1200),
(NOW()-INTERVAL '2h 10m', 3,  7,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '45m',    3,  7, 10, '[SHORTAGE] Feeder empty',                true,  false, NOW()-INTERVAL '30m',    900),
(NOW()-INTERVAL '30m',    3,  7,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── CNC-01 (eq=10 after rebuild, eq=9 pre-rebuild) ────────────────────────────
(NOW()-INTERVAL '4h',     3, 10,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h 20m', 3, 10, 10, '[MAINTENANCE] Filter replacement',       true,  true,  NOW()-INTERVAL '2h',     1200),
(NOW()-INTERVAL '2h',     3, 10,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── Assembly-01 (eq=12 after rebuild, eq=11 pre-rebuild) ──────────────────────
(NOW()-INTERVAL '3h',     3, 12,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h',     3, 12, 10, '[EQUIPMENT] Servo error',                true,  false, NOW()-INTERVAL '1h 40m', 1200),
(NOW()-INTERVAL '1h 40m', 3, 12,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '30m',    3, 12, 10, '[OTHERS] Operator unavailable',          true,  false, NULL, NULL),
-- ── Processor-01 (eq=14 after rebuild, eq=13 pre-rebuild) ─────────────────────
(NOW()-INTERVAL '6h',     4, 14,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '5h 20m', 4, 14, 10, '[PROCESS] Product changeover',           true,  false, NOW()-INTERVAL '4h 55m', 1500),
(NOW()-INTERVAL '4h 55m', 4, 14,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '3h 40m', 4, 14, 10, '[EQUIPMENT] Mechanical failure',         true,  false, NOW()-INTERVAL '3h 20m', 1200),
(NOW()-INTERVAL '3h 20m', 4, 14,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h',     4, 14, 10, '[SHORTAGE] Component missing',           true,  false, NOW()-INTERVAL '1h 45m', 900),
(NOW()-INTERVAL '1h 45m', 4, 14,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '30m',    4, 14, 10, '[PROCESS] Format adjustment',            true,  false, NOW()-INTERVAL '15m',    900),
(NOW()-INTERVAL '15m',    4, 14,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── Packer-01 (eq=16 after rebuild, eq=15 pre-rebuild) ────────────────────────
(NOW()-INTERVAL '5h',     4, 16,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '4h 20m', 4, 16, 10, '[EQUIPMENT] Sensor fault',               true,  false, NOW()-INTERVAL '4h 5m',  900),
(NOW()-INTERVAL '4h  5m', 4, 16,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '3h',     4, 16, 10, '[TOOLING] Blade replacement',            true,  false, NOW()-INTERVAL '2h 35m', 1500),
(NOW()-INTERVAL '2h 35m', 4, 16,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '1h 30m', 4, 16, 10, '[SHORTAGE] Awaiting replenishment',      true,  false, NOW()-INTERVAL '1h 10m', 1200),
(NOW()-INTERVAL '1h 10m', 4, 16,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '25m',    4, 16, 10, '[EQUIPMENT] Drive fault',                true,  false, NULL, NULL),
-- ── Filler-01 (eq=18 after rebuild, eq=17 pre-rebuild) ────────────────────────
(NOW()-INTERVAL '4h',     4, 18,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '2h 45m', 4, 18, 10, '[MAINTENANCE] Lubrication',              true,  true,  NOW()-INTERVAL '2h 25m', 1200),
(NOW()-INTERVAL '2h 25m', 4, 18,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '1h',     4, 18, 10, '[OTHERS] External factor',               true,  false, NOW()-INTERVAL '45m',    900),
(NOW()-INTERVAL '45m',    4, 18,  6, 'Machine resumed',                        false, false, NULL, NULL),
-- ── Labeler-01 (eq=20 after rebuild, eq=19 pre-rebuild) ───────────────────────
(NOW()-INTERVAL '3h',     4, 20,  6, 'Machine resumed',                        false, false, NULL, NULL),
(NOW()-INTERVAL '1h 50m', 4, 20, 10, '[EQUIPMENT] Machine jam',                true,  false, NOW()-INTERVAL '1h 35m', 900),
(NOW()-INTERVAL '1h 35m', 4, 20,  6, 'Machine resumed',                        false, false, NULL, NULL)
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

-- ── UNS Metrics (2h history, 5-min resolution, 6 metrics × 10 lines) ─────────
-- Line/sector IDs after rebuild: 2,4,6,9,11,13,15,17,19,21
-- Values are static seeds; the oeecloud simulation writes live ones.

INSERT INTO uns_metrics (ts_value, id_enterprise, id_site, id_area, id_equipment, metric_name, metric_value, metric_type)
SELECT
    ts,
    eq.id_enterprise,
    eq.id_site,
    eq.id_area,
    eq.id_equipment,
    m.metric_name,
    CASE m.metric_name
        WHEN 'availability'   THEN ROUND((0.82 + random() * 0.12)::numeric, 4)
        WHEN 'performance'    THEN ROUND((0.78 + random() * 0.15)::numeric, 4)
        WHEN 'quality'        THEN ROUND((0.96 + random() * 0.03)::numeric, 4)
        WHEN 'oee'            THEN ROUND((0.58 + random() * 0.22)::numeric, 4)
        WHEN 'net_production' THEN FLOOR(200  + random() * 800)
        WHEN 'speed'          THEN FLOOR(60   + random() * 180)
    END,
    'double'
FROM
    generate_series(NOW() - INTERVAL '2 hours', NOW(), INTERVAL '5 minutes') AS ts,
    (VALUES
        ( 2, 1, 1,  1), ( 4, 2, 2,  2), ( 6, 3, 3,  3),
        ( 9, 3, 3,  4), (11, 3, 4,  5), (13, 3, 4,  6),
        (15, 4, 5,  7), (17, 4, 5,  8), (19, 4, 6,  9), (21, 4, 6, 10)
    ) AS eq(id_equipment, id_enterprise, id_site, id_area),
    (VALUES ('availability'), ('performance'), ('quality'), ('oee'), ('net_production'), ('speed')) AS m(metric_name)
ON CONFLICT (ts_value, id_equipment, metric_name) DO NOTHING;
