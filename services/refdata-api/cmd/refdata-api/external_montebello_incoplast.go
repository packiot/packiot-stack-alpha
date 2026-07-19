// external_montebello_incoplast.go — ADR-0031 Workstream B, Family A: the
// Montebello (ent 6) and Incoplast (api_key) anti-corruption shims.
//
// Each run() below is a FROZEN reproduction of a back4 controller, pinned from
// source (the controller file is cited on each function). The shared membrane
// (auth-shape reproduction, owner binding, byte-identical encode, timeout,
// metrics) lives in external.go; these functions only (a) read under the $1=cid
// fence with SQL copied verbatim from back4 (its own $1 was the hardcoded
// enterprise id — now the injected customer_id) and (b) wrap the rows in the
// endpoint's frozen envelope.
//
// TWO NEW ENVELOPE FAMILIES vs the NEOPAC proof-of-pattern:
//   - {page,results,data} where `page` is the RAW query value (Montebello
//     data-sync does NOT parseInt it, unlike NEOPAC sap-report-sync) → Page is
//     `any`: a string when the param is present, the int default when absent.
//   - {newData} / {jobs_filtered} whose ts_* columns are reformatted by a
//     per-consumer VALUE adapter (moment's `[Z]` format) — see momentZFormat.
//
// NUMERIC-COLUMN BOUNDARY (same honesty as external.go): several of these reads
// are `SELECT *` / set-returning functions projecting columns that MAY be
// numeric/decimal (duration, net_production, gross_production, presscount).
// node-pg returns numeric as a STRING; pgx returns a numeric Go type. Which
// columns are numeric is a live-DDL property unreadable from the controller
// source, so it is NOT pinned in the golden fixtures — it is the §3c step-3
// SHADOW-DIFF item, gated before cutover. The golden fixtures below use only
// string/int/bool/time.Time values whose serialization IS pinnable.
package main

import (
	"context"
	"net/http"
	"strings"
	"time"
)

// momentZFormat reproduces back4's `moment(value).utc().format('YYYY-MM-DDTHH:mm:ss[Z]')`.
// The `[Z]` in a moment format string is a LITERAL Z (bracket-escaped), NOT a
// timezone token — so the output is second-precision UTC with a trailing literal
// Z and NO milliseconds. This is deliberately DIFFERENT from the default
// toISOString pin (normalizeExternalValue → `.000Z`, millisecond precision):
// reshaping the envelope without also reshaping these timestamp values would
// break byte-identity against the moment-formatted back4 output.
//
// Flagged for the §3c shadow-diff: back4 reads timestamp-WITHOUT-tz columns
// through node-pg, which parses them in the process LOCAL zone before `.utc()`;
// pgx parses naive timestamps as UTC. The FORMAT is pinned here; the naive-
// timestamp zone-of-parse is a driver nuance verified live, not from source.
func momentZFormat(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05") + "Z"
}

// ── Frozen envelope structs (declaration order = frozen key order) ───────────

// envPageResults is Montebello data-sync's frozen `{page,results,data}`. Page is
// `any` because back4 echoes `req.query.page` UNPARSED (a string when present),
// falling back to the int default 1 when the param is absent — the raw-page quirk.
type envPageResults struct {
	Page    any          `json:"page"`
	Results int          `json:"results"`
	Data    externalRows `json:"data"`
}

// envNewData is the frozen `{newData}` envelope shared by events_montebello and
// events_incoplast (both `res.json({ newData })`).
type envNewData struct {
	NewData externalRows `json:"newData"`
}

// envJobsFiltered is jobs_incoplast's frozen `{jobs_filtered}` envelope. NOTE:
// the task brief said "same family as {newData}" but the SOURCE key is
// `jobs_filtered` (getjobsIncoplast → `res.json({ jobs_filtered })`) — pinned
// from source, not the brief.
type envJobsFiltered struct {
	JobsFiltered externalRows `json:"jobs_filtered"`
}

// ── Montebello (Family A, ent 6) ─────────────────────────────────────────────

// runMontebelloDataSync reproduces integrations/montebello/data-sync.controller.js
// (DataSyncController.execute):
//   - header x-api-key auth (default membrane), owner-bound to ent 6;
//   - optional `site` filter (UPPER'd), LIMIT/OFFSET pagination, defaults
//     page=1 limit=600, offset=(page-1)*limit;
//   - frozen `{page,results,data}` where `page` is the RAW query value.
//
// The 404 "Data not found" branch is DEAD in back4: db.query returns [] on error
// (truthy), so `if (!data)` never fires — reproduced faithfully by NOT emitting
// it (deps.query already mirrors back4's error→[] swallow).
func runMontebelloDataSync(ctx context.Context, deps shimDeps, _ int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	site := q.Get("site")

	// The raw-page quirk: echo the query string unparsed; default is the int 1.
	pageRaw := q.Get("page")
	var page any = 1
	if pageRaw != "" {
		page = pageRaw
	}
	// For LIMIT/OFFSET we need numbers. back4 relies on JS coercing the string
	// operands of `(page - 1) * limit`; parseIntDefault gives the same result
	// for the integer inputs a real client sends (default limit 600, not 1000).
	pageNum := parseIntDefault(pageRaw, 1)
	limitNum := parseIntDefault(q.Get("limit"), 600)
	offset := (pageNum - 1) * limitNum

	var data externalRows
	if site != "" {
		data = deps.query(ctx,
			`select * from v_piot_production_data_sync_cust6 where site = UPPER($1) limit $2 offset $3`,
			site, limitNum, offset)
	} else {
		data = deps.query(ctx,
			`select * from v_piot_production_data_sync_cust6 limit $1 offset $2`,
			limitNum, offset)
	}
	return envPageResults{Page: page, Results: len(data.rows), Data: data}, nil
}

// runMontebelloEvents reproduces ApiMontebelloEventsController.getdowntimesMontebello
// + repositories/ApiMontebelloEvents/Downtimes.js:
//   - `api_key` QUERY-param auth (400 "api_key is required!", reject
//     "Not authorized!"), owner-bound to ent 6 (queryAPIKeyAuth in the registry);
//   - read set-returning get_downtime_sync_enterprsie_06(), optional nm_site
//     filter (UPPER'd — parameterized here, string-interpolated in back4);
//   - frozen `{newData}` with the ts_event/ts_end/last_update moment[Z] adapter.
func runMontebelloEvents(ctx context.Context, deps shimDeps, _ int, r *http.Request) (any, *shimError) {
	siteName := strings.TrimSpace(r.URL.Query().Get("site_name"))
	var data externalRows
	if siteName != "" {
		data = deps.query(ctx,
			`select * from get_downtime_sync_enterprsie_06() where nm_site = UPPER($1)`,
			siteName)
	} else {
		data = deps.query(ctx, `select * from get_downtime_sync_enterprsie_06()`)
	}
	return envNewData{NewData: data.withMomentZColumns("ts_event", "ts_end", "last_update")}, nil
}

// ── Incoplast (Family A, api_key) ────────────────────────────────────────────

// runIncoplastEvents reproduces ApiIncoplastEventsController.getDowntimesIncoplast
// + repositories/ApiIncoplastEvents/Downtimes.js:
//   - `api_key` QUERY-param auth (400 "api_key is required!"); owner-bound (see
//     the OWNER-BINDING NOTE on queryAPIKeyAuth — back4 had no reject here);
//   - the big union read fenced by $1 = cid (back4's id_enterprise), with
//     $2 startTime / $3 endTime / $4 limit — SQL copied verbatim so the column
//     ORDER (hence the frozen row shape) is identical;
//   - frozen `{newData}` with the ts_event/ts_end/last_update moment[Z] adapter.
func runIncoplastEvents(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	// back4 defaults: moment() (LOCAL) minus 1 month / now, 'YYYY-MM-DDTHH:mm:ss'.
	// These are default-only (a real client passes explicit bounds); the local-
	// vs-UTC zone of the default is a non-load-bearing nuance noted for §3c.
	startTime := q.Get("startTime")
	if startTime == "" {
		startTime = time.Now().AddDate(0, -1, 0).Format("2006-01-02T15:04:05")
	}
	endTime := q.Get("endTime")
	if endTime == "" {
		endTime = time.Now().Format("2006-01-02T15:04:05")
	}
	limit := parseIntDefault(q.Get("limit"), 200)

	data := deps.query(ctx, sqlIncoplastEvents, cid, startTime, endTime, limit)
	return envNewData{NewData: data.withMomentZColumns("ts_event", "ts_end", "last_update")}, nil
}

// runIncoplastJobs reproduces ApiIncoplastJobsController.getjobsIncoplast +
// repositories/ApiIncoplastJobs/Jobs.js:
//   - `api_key` QUERY-param auth (400 "api_key is required!"), owner-bound;
//   - production_orders ⋈ packml_register fenced by $1 = cid, $2 ts_start,
//     $3 limit; status ∈ {2,3,4}; SQL verbatim (column order preserved);
//   - frozen `{jobs_filtered}` with the ts_start/ts_end/last_update moment[Z]
//     adapter (the SQL already `at time zone 'utc'`-normalizes those columns).
func runIncoplastJobs(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	tsStart := q.Get("ts_start")
	if tsStart == "" || tsStart == "undefined" {
		// back4: moment.utc().subtract(20,'days').format('YYYY-MM-DD HH:mm:ss')
		tsStart = time.Now().UTC().AddDate(0, 0, -20).Format("2006-01-02 15:04:05")
	}
	limit := q.Get("limit")
	limitNum := 100
	if limit != "" && limit != "undefined" {
		limitNum = parseIntDefault(limit, 100)
	}

	data := deps.query(ctx, sqlIncoplastJobs, cid, tsStart, limitNum)
	return envJobsFiltered{JobsFiltered: data.withMomentZColumns("ts_start", "ts_end", "last_update")}, nil
}

// ── Verbatim back4 SQL (column order = the frozen row shape) ──────────────────
//
// Copied byte-for-byte from the back4 repositories so the projected column set
// AND ORDER match exactly (the only change: back4 built these with $1..$N where
// $1 was the api_key's enterprise; here $1 is the membrane-injected cid, which
// the owner binding pins to the shim's bound customer). String interpolation of
// UPPER('${site}') in back4 is the ONE thing NOT copied — it is parameterized in
// the dynamic-filter shims above; these two functions have no user filter.

const sqlIncoplastEvents = `
            select * from (
                select
                    id_order, nm_site,nm_equipment,sector,cd_shift,
                    ts_event,
                    ts_end,
                    duration,  cd_machine,
                    cd_category,
                    cd_subcategory,
                    txt_downtime_notes, id_equipment_event as pack_id,
                    custom_field,
                    packml_topic,
                    cd_category_client,
                    cd_subcategory_client,
                    last_update
                from
                    (
                        select
                            id_equipment_event,
                            ts_event,
                            ee.ts_end,
                            ee.id_equipment,
                            case
                                when eq.tp_equipment = 2 then eq.id_equipment
                                else null
                            end as id_sector,
                            eq.id_equipment as id_line,
                            case
                                when eq.tp_equipment = 3 then eq.nm_equipment
                                else null
                            end as nm_equipment,
                            case
                                when eq.tp_equipment = 2 then eq.nm_equipment
                                else null
                            end as sector,
                            eq.id_area,
                            eq.id_site,
                            eq.id_parentequipment,
                            cd_machine,
                            ee.duration,
                            cd_category,
                            cd_subcategory,
                            txt_downtime_notes,
                            st.timezone,
                            st.nm_site,
                            eq.stop_threshold_time,
                            ee.planned_downtime ,
                            ee.change_over,
                            ers.ts_range,
                            pr.packml_topic,
                            (
                                select id_order from production_orders po where
                                    po.id_production_order  =
                                        (select id_production_order from production_orders_runtime por
                                            where ee.ts_event <@ por.runtime_timerange
                                            and id_equipment = eq.id_equipment
                                        )
                            ),
                                                    (
                                select custom_field from production_orders po where
                                    po.id_production_order  =
                                        (select id_production_order from production_orders_runtime por
                                            where ee.ts_event <@ por.runtime_timerange
                                            and id_equipment = eq.id_equipment
                                        )
                            ),
                            sh.cd_shift,
                            ers.id_shift, ee.id_enterprise,
                            ee.cd_category_client, ee.cd_subcategory_client,
                            ee.last_update
                        from
                            (select * from equipment_events
                                where id_enterprise = $1
                                and ts_event >= now() - interval '1 month'
                                union all
                                select * from equipment_events_man
                                where id_enterprise = $1
                                and ts_event >= now() - interval '2 month' ) ee
                            left join equipments eq on eq.id_equipment = ee.id_equipment
                            left join sites st on eq.id_site = st.id_site
                            left join equipment_runtime_shift ers on ee.ts_event <@ ers.ts_range and ers.id_equipment = ee.id_equipment
                            left join shifts sh on ers.id_shift = sh.id_shift
                            left join packml_register pr on pr.id_equipment = eq.id_equipment
                    where
                            (ee.status <> 6 or ee.status is null)
                            and
                            ee.last_update is not null
                            and eq.event_should_be_displayed = true
                        ) manual_stop
                where
                    id_enterprise = $1
                    and id_line = any( select e.id_equipment from equipments e where id_enterprise = $1 )
                    and last_update >= $2
                    and last_update <= $3
            )AAA order by last_update desc
            limit $4;
        `

const sqlIncoplastJobs = `
            SELECT po.id_production_order,
            po.id_order,
            po.net_production,
            po.gross_production,
            po.ts_start at time zone 'utc' as ts_start,
            po.ts_end at time zone 'utc' as ts_end,
            po.id_equipment,
            po.status,
            po.id_enterprise,
            pr.packml_topic as topic,
            po.custom_field,
            po.last_update at time zone 'utc' as last_update
        FROM production_orders po
            JOIN packml_register pr on pr.id_equipment = po.id_equipment
        WHERE (po.status = ANY (ARRAY[2, 3, 4])) and ts_start >= $2 and po.id_enterprise = $1 order by po.last_update desc limit $3;
        `
