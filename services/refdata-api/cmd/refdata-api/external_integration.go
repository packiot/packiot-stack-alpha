// external_integration.go — ADR-0031 Workstream B, Family A: the back4
// `/integration/*` anti-corruption shims (JobDataIntegration, ApiJobReport,
// get-shift-validation).
//
// WHAT MAKES THIS FAMILY DIFFERENT FROM NEOPAC/MONTEBELLO/INCOPLAST
// ────────────────────────────────────────────────────────────────
// Every shim here is mounted on a route with a PATH PARAMETER:
//
//	back4 routes.js
//	  GET /integration/job_data_integration/:id_enterprise  (Montebello)
//	  GET /integration/get-shift-validation/:id_enterprise   (Montebello)
//	  GET /integration/job_report/:id_enterprise             (Incoplast)
//
// In back4 the CLIENT names the tenant: the controller reads `req.params
// .id_enterprise` and trusts it after a light api_key cross-check. That is the
// exact "client supplies the tenant" hazard ADR-0027 exists to kill. The ACL
// keeps the FOREIGN CONTRACT (the same 400/422/500 status bodies, the same
// `:id_enterprise` URL shape a real SAP/Montebello/Incoplast client already
// calls) while making refdata the injection authority: the api_key resolves to a
// cid through QUERY_API_KEYS, the path `:id_enterprise` must equal that cid, and
// the cid must equal the shim's config-bound owner. No id_enterprise literal.
//
// The path parameter is why the framework grew muxPattern + exemptMatch (auth.go):
// the auth-exempt set was exact-path, so `/integration/job_report/123` never
// matched the manifest key `/integration/job_report/:id_enterprise` and fell
// through to the JSON-401 middleware — breaking the foreign contract before the
// shim ran.
//
// THREE DISTINCT AUTH LADDERS (pinned from source, cited per function):
//   - job_data_integration / job_report: resolve api_key→enterprise; unknown →
//     400 (per-endpoint body); path id != that enterprise → 422 "Invalid id".
//   - get-shift-validation: a DISTINCT MEMBRANE — the service `throw`s and the
//     controller `catch`es to `res.status(500).send(error.message)`, so EVERY
//     error (auth included) is a 500-with-message, not the 400/401/422 matrix.
//
// DRIVER-SERIALIZATION BOUNDARY (§3c shadow-diff — now CLOSED at the reader,
// external.go): job_report's presscount is `sum(gross_production_incr)` →
// DOUBLE PRECISION (live-typed SELECT-only from prod), so it is a JSON NUMBER on
// both drivers — job_report is numeric-CLEAN. get_data_sync_enterprsie_06b projects
// bigint/numeric(10,2) → node-pg strings and a jsonb supervisornotes → an OBJECT in
// jsonb's stored key order; get-shift-validation's txt_validation_notes is jsonb
// likewise. All are pinned in the golden fixtures below in their node-pg form.
package main

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// dateOnlyFormat reproduces the DAO's `dayjs(value).format('YYYY-MM-DD')` — a
// bare calendar date, no time, no zone suffix. Only get-shift-validation's
// ShiftsValidationDAO.findByTopic applies it (to ts_value_production).
//
// ZONE NUANCE (§3c — RESOLVED, CLEAN): ts_value_production is a Postgres `date`
// (no time-of-day). node-pg parses `date` at LOCAL midnight and dayjs WITHOUT
// `.utc()` formats in the SAME local zone, so the calendar day never shifts;
// pgx decodes `date` at UTC midnight and we format in the value's own location.
// Under the UTC container both services run in (neither sets TZ) the two are
// byte-identical, and because format and parse share the one zone the result is
// stable even off-UTC. The FORMAT is what is pinned.
func dateOnlyFormat(t time.Time) string {
	return t.Format("2006-01-02")
}

// ── Frozen envelope structs (declaration order = frozen key order) ───────────

// envDataIntegration is JobDataIntegrationController's frozen `{data_integration}`
// (res.json({ data_integration })).
type envDataIntegration struct {
	DataIntegration externalRows `json:"data_integration"`
}

// envJobReport is ApiJobReportController's frozen `{job_report}`.
type envJobReport struct {
	JobReport externalRows `json:"job_report"`
}

// envShiftData is GetShiftValidationController's frozen `{shift_data}`
// (res.json({ shift_data: output })).
type envShiftData struct {
	ShiftData externalRows `json:"shift_data"`
}

// ── The /integration/:id_enterprise auth ladders ─────────────────────────────

// integrationEnterpriseAuth reproduces the back4 auth ladder shared by
// JobDataIntegrationController.getDataIntegration and
// ApiJobReportController.getJobReport (identical shape, different missing body):
//
//	const check_id = await ide_repo.getIdEnterpriseFromApiKey(api_key); // by api_key
//	if (Object.keys(check_id).length === 0) return res.status(400).send(<missingBody>);
//	else if (check_id[0].id_enterprise != id_enterprise) return res.status(422).send("Invalid id");
//	if (!api_key || api_key == "undefined") return res.status(400).send("api_key is required!");
//	if (!(await ide_repo.authenticate(id_enterprise, api_key))) return res.status(401).send("Unauthorized access");
//
// The FIRST two branches are the live ones: a missing/unknown api_key resolves to
// an empty enterprise lookup → 400 <missingBody>; a valid key whose enterprise
// doesn't equal the path `:id_enterprise` → 422 "Invalid id". The `api_key is
// required!` 400 and the `Unauthorized access` 401 are DEAD given this ordering (a
// falsy key already 400s at branch 1, and authenticate re-checks the same key by
// the id branch 2 already pinned) — documented, not reachable.
//
// ACL owner binding folds into branch 2: this shim serves exactly ONE tenant, so
// the resolved cid must equal the bound owner. cid != owner (a valid NON-owner
// key) → 422 "Invalid id", which is byte-identical to back4's own response for the
// common "your key's enterprise ≠ the path id you requested" case. The one
// behavioural change vs back4 is that a foreign tenant can no longer read ITS OWN
// data through this now-single-tenant shim (back4 would 200 it); flagged for §3d.
func integrationEnterpriseAuth(missingBody string) externalAuth {
	return func(r *http.Request, keys map[string]int, owner int) (int, *shimError) {
		apiKey := r.URL.Query().Get("api_key")
		cid, ok := keys[apiKey]
		if !ok {
			// getIdEnterpriseFromApiKey → [] (covers missing/undefined/unknown key).
			return 0, &shimError{status: http.StatusBadRequest, body: missingBody}
		}
		pathEnt, perr := strconv.Atoi(strings.TrimSpace(r.PathValue("id_enterprise")))
		if perr != nil || cid != pathEnt || cid != owner {
			return 0, &shimError{status: http.StatusUnprocessableEntity, body: "Invalid id"}
		}
		return cid, nil
	}
}

// integrationShiftValidationAuth reproduces the DISTINCT membrane of
// get-shift-validation. The service calls `packmlDAO.authenticate(id_enterprise,
// api_key)` — `SELECT api_key FROM enterprises WHERE id_enterprise = <path id>`,
// compared to the supplied api_key — and on mismatch `throw new Error('Not
// authorized!')`, which the controller catches to `res.status(500).send(error
// .message)`. So auth failure here is 500 "Not authorized!" (text/html), NOT the
// 400/401/422 matrix.
//
// The DAO keys on the PATH id_enterprise, so auth passes iff enterprises[path].
// api_key == api_key, i.e. iff the api_key's own enterprise (cid) equals the path
// id. The ACL owner binding (cid must equal the bound owner) folds into the same
// 500. A non-numeric path or unknown key both become 500 "Not authorized!" here;
// back4's non-numeric-path case actually 500s with a runtime TypeError string (an
// unprovisioned lookup), an un-pinnable implementation detail a real client never
// triggers — collapsed to the same "Not authorized!" 500 and flagged for §3d.
func integrationShiftValidationAuth(r *http.Request, keys map[string]int, owner int) (int, *shimError) {
	apiKey := r.URL.Query().Get("api_key")
	cid, ok := keys[apiKey]
	pathEnt, perr := strconv.Atoi(strings.TrimSpace(r.PathValue("id_enterprise")))
	if !ok || perr != nil || cid != pathEnt || cid != owner {
		return 0, &shimError{status: http.StatusInternalServerError, body: "Not authorized!"}
	}
	return cid, nil
}

// ── Montebello: job_data_integration → {data_integration} ────────────────────

// runJobDataIntegration reproduces JobDataIntegrationController.getDataIntegration
// + JobDataIntegrationRepository.dataIntegration:
//   - post-auth validation: `!days_interval || days_interval <= 0 || days_interval
//     > 41` → 400 "days interval must be between 1 and 41";
//   - read the ent-06-FROZEN set-returning get_data_sync_enterprsie_06b(days), with
//     an optional UPPER'd `site` filter (string-interpolated in back4 →
//     parameterized here). The function is pre-scoped to enterprise 06 and takes
//     NO id_enterprise arg, so — exactly like NEOPAC sap-report-sync — there is no
//     $1 tenant column to fence in SQL; the ENTIRE fence is the owner binding.
//   - frozen `{data_integration}` envelope. back4 res.json's the rows straight (no
//     moment/date adapter), so timestamps use the default toISOString pin.
func runJobDataIntegration(ctx context.Context, deps shimDeps, _ int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	di := parseIntDefault(q.Get("days_interval"), 0) // absent/non-numeric ⇒ 0 ⇒ rejected (mirrors !days_interval)
	if di <= 0 || di > 41 {
		return nil, &shimError{status: http.StatusBadRequest, body: "days interval must be between 1 and 41"}
	}
	site := q.Get("site")
	var data externalRows
	if site != "" {
		data = deps.query(ctx,
			`select * from get_data_sync_enterprsie_06b($1) where site = UPPER($2)`, di, site)
	} else {
		data = deps.query(ctx, `select * from get_data_sync_enterprsie_06b($1)`, di)
	}
	return envDataIntegration{DataIntegration: data}, nil
}

// ── Incoplast: job_report → {job_report} ─────────────────────────────────────

// runJobReport reproduces ApiJobReportController.getJobReport +
// JobReportRepository.jobReport:
//   - post-auth validation: `!id_equipment || id_equipment == "undefined"` → 400
//     "id_equipment is required!";
//   - id_equipment is a client list ("{1,2}" / "[1,2]" / "1,2") → strip brackets,
//     split on comma, map to int (back4: replace(/[{\[()\]}]/g,”).split(',')
//     .map(Number)) — bound as an int[] instead of back4's string-interpolated
//     `IN (...)`;
//   - the 48h/30d TPR press-count CTE, fenced by $1 = the injected cid (back4's
//     path id_enterprise) at every `id_enterprise = $1`; SQL column ORDER preserved
//     so the frozen row shape is identical (id_equipment, cd_shift,
//     ts_value_production, id_order, presscount, ts_start, packml_topic);
//   - frozen `{job_report}`. No moment adapter (res.json straight → toISOString).
//     presscount (sum → int8/numeric) is the §3c numeric shadow-diff.
func runJobReport(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError) {
	idEquipmentRaw := r.URL.Query().Get("id_equipment")
	if idEquipmentRaw == "" || idEquipmentRaw == "undefined" {
		return nil, &shimError{status: http.StatusBadRequest, body: "id_equipment is required!"}
	}
	ids := parseIDList(idEquipmentRaw)
	data := deps.query(ctx, sqlJobReport, cid, ids)
	return envJobReport{JobReport: data}, nil
}

// parseIDList reproduces back4's `id_equipment.replace(/[{\[()\]}]/g,”).split(',')
// .map(Number)`: strip the bracket family, split on comma, parse each to int.
// Non-numeric tokens (which back4 would turn into NaN → a 500 SQL error) are
// dropped — a degenerate input a real Incoplast client never sends.
func parseIDList(raw string) []int {
	cleaned := strings.NewReplacer("{", "", "[", "", "(", "", ")", "", "]", "", "}", "").Replace(raw)
	var ids []int
	for _, p := range strings.Split(cleaned, ",") {
		if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil {
			ids = append(ids, n)
		}
	}
	return ids
}

// ── Montebello: get-shift-validation → {shift_data} (distinct 500 membrane) ───

// runShiftValidation reproduces GetShiftValidationService.execute (auth already
// done by integrationShiftValidationAuth). It is a MULTI-DAO resolution, every
// failure surfacing as a 500-with-message (the controller's catch):
//   - resolve the topic: with `site`, packmlDAO.getSiteTopic (packml_topic LIKE
//     UPPER('%'||site)) → empty ⇒ 500 "Site does not exist!"; without `site`,
//     packmlDAO.getEnterpriseTopic → the first packml_topic's leading '/'-segment;
//   - then `days_interval <= 0 || days_interval > 41` ⇒ 500 "Days interval must be
//     between 1 and 41" (note: AFTER topic resolution, and a CAPITAL 'D' — distinct
//     from job_data_integration's lowercase 400 body);
//   - ShiftsValidationDAO.findByTopic → the explicit-key row projection (SELECT
//     order = the DAO's object-literal order) with ts_value_production rendered as
//     a dayjs `YYYY-MM-DD` date (withDateOnlyColumns).
//
// All resolution reads are fenced by $1 = cid (the injected owner). findByTopic is
// fenced indirectly by the resolved topic (which came from the tenant's own
// packml_register). shift_hrs / validation / index1 are potential numerics → §3c.
func runShiftValidation(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	site := q.Get("site")
	di := parseIntDefault(q.Get("days_interval"), 0)

	// 1) Topic resolution (packmlDAO). Only packml_topic is needed; projecting it
	// explicitly (back4 SELECT *'d then read .packml_topic) — the intermediate is
	// never returned, so narrowing the projection changes no external contract.
	var topic string
	if site != "" {
		gs := deps.query(ctx,
			`select packml_topic from packml_register pr where id_enterprise = $1 and packml_topic like UPPER($2)`,
			cid, "%"+site)
		if len(gs.rows) == 0 {
			return nil, &shimError{status: http.StatusInternalServerError, body: "Site does not exist!"}
		}
		topic = firstColString(gs)
	} else {
		ge := deps.query(ctx,
			`select packml_topic from packml_register pr where id_enterprise = $1 LIMIT 1`, cid)
		if len(ge.rows) == 0 {
			// back4: getEnterprise[0].topic on [] → TypeError → 500 (un-pinnable V8
			// message). Unreachable for a provisioned owner; collapsed to a stable
			// 500 and flagged for §3d rather than inventing the exact string.
			return nil, &shimError{status: http.StatusInternalServerError, body: "Enterprise topic not found!"}
		}
		// getEnterpriseTopic maps topic = packml_topic.split('/')[0].
		topic = strings.SplitN(firstColString(ge), "/", 2)[0]
	}

	// 2) days_interval window (after topic resolution, per the service order).
	if di <= 0 || di > 41 {
		return nil, &shimError{status: http.StatusInternalServerError, body: "Days interval must be between 1 and 41"}
	}

	// 3) findByTopic — column order = the DAO's object-literal order; back4's
	// `interval '${days}day'` and `like '%${topic}%'` string-interpolations are
	// parameterized (di * interval '1 day', and $2 = '%'||topic||'%').
	data := deps.query(ctx, sqlShiftValidation, di, "%"+topic+"%")
	return envShiftData{ShiftData: data.withDateOnlyColumns("ts_value_production")}, nil
}

// firstColString returns the first column of the first row as a string ("" if the
// value is nil or absent) — used to lift a resolved packml_topic out of an
// intermediate externalRows without importing the whole map machinery.
func firstColString(er externalRows) string {
	if len(er.rows) == 0 || len(er.rows[0]) == 0 {
		return ""
	}
	if s, ok := er.rows[0][0].(string); ok {
		return s
	}
	return ""
}

// ── Verbatim back4 SQL (column order = the frozen row shape) ──────────────────

// sqlJobReport is JobReportRepository.jobReport, copied so the projected column
// set AND ORDER match. The two back4 string-interpolations are parameterized: $1
// replaces the [id_enterprise] bind (now the injected cid), and $2 replaces the
// `IN (` + id_equipment.join(',') + `)` list with `= ANY($2::int[])`.
const sqlJobReport = `
        --base report para TPR operator
        with turnos as (
        select
          id_equipment,
          cd_shift,
          id_shift,
          ts_value_production,
          ts_value  as tz_value,
          case
            when ts_end > now() then now()
            else ts_end  end as tz_end
        from equipment_runtime_shift
        where id_equipment in (select id_equipment from equipments where id_enterprise = $1 and tp_equipment = 3)
        and ts_value  >=now() - interval '48 hour'
        and ts_value < now()
        ), presscount as (
          select
          id_equipment,
          id_site,
          id_area,
          ts_value  as tz_value,
          gross_production_incr
          from agg_equipment_values_1min_t
          where id_equipment in (select id_equipment from equipments where id_enterprise = $1 and tp_equipment = 3)
          and ts_value >= now() - interval '48 hour'
          and ts_value >=  (select min(tz_value) from turnos)
          and id_enterprise = $1
          and id_site in (select id_site from sites where id_enterprise = $1)
          and id_area in (select id_area from areas where id_enterprise = $1)
        ), prod_orders as (
          select
          porun.id_equipment,
          po.id_enterprise,
          po.id_area,
          po.id_site,
          po.id_order,
          lower(porun.runtime_timerange)  as job_start,
          case when upper(porun.runtime_timerange) is null then now()  else upper(porun.runtime_timerange)  end as job_end
        from production_orders_runtime porun, production_orders po
        where porun.id_equipment in (select id_equipment from equipments where id_enterprise = $1 and tp_equipment = 3)
        and po.id_equipment = porun.id_equipment
        and po.id_enterprise = $1
        and po.id_production_order = porun.id_production_order
        and lower(porun.runtime_timerange) >= now() - interval '30 day'
        ),base_for_splits as (
        select
          shi.id_equipment,
          shi.cd_shift,
          shi.ts_value_production,
          po.id_order,
          case when tz_value > job_start then tz_value else job_start end as ts_start,
          case when tz_end < job_end then tz_end else job_end end as ts_end,
          po.id_site,
          po.id_area,
          shi.id_shift
        from turnos shi
        left join prod_orders po
        on po.job_start < shi.tz_end
        and po.job_end >= shi.tz_value
        and po.id_equipment = shi.id_equipment
        order by shi.id_equipment, shi.tz_value
        )
        select
          bfs.id_equipment,
          bfs.cd_shift,
          bfs.ts_value_production,
          bfs.id_order,
          sum(pc.gross_production_incr) as presscount,
          bfs.ts_start,
          packml_topic
        from base_for_splits bfs
        left join presscount pc
        on pc.tz_value between bfs.ts_start and bfs.ts_end
        and pc.id_equipment = bfs.id_equipment
        and pc.id_site = bfs.id_site
        and pc.id_area = bfs.id_area
        left join packml_register pr
        on pc.id_equipment = pr.id_equipment
        where pc.id_equipment = ANY($2::int[])
        group by 1,2,3,4,6,7
        order by 1,6 desc
        `

// sqlShiftValidation is ShiftsValidationDAO.findByTopic, copied so the projected
// column set AND ORDER match the DAO's object-literal remap (index1, packml_topic,
// id_site, shift_hrs, ts_value_production, cd_shift, validation, id_order,
// txt_validation_notes, nm_user_validation, ts_user_validation, shift_start_time,
// to_delete). back4's `interval '${days_interval} day'` → `$1 * interval '1 day'`;
// `packml_topic like '%${topic}%'` → `like $2` (the caller passes '%'||topic||'%').
const sqlShiftValidation = `
        select
            evs.index1,
            pr.packml_topic,
            pr.id_site,
            evs.shift_hrs,
            evs.ts_value_production,
            evs.cd_shift,
            evs.validation,
            evs.id_order,
            evs.txt_validation_notes,
            evs.nm_user_validation,
            evs.ts_user_validation,
            evs.shift_start_time,
            evs.to_delete
        from equipment_validation_shift evs
        left join packml_register pr on pr.id_equipment = evs.id_equipment
        where
        ts_value_production >= now() - ($1 * interval '1 day')
        and to_delete is FALSE
        and pr.packml_topic like $2
        order by ts_value_production desc, shift_hrs desc LIMIT 1000;
        `
