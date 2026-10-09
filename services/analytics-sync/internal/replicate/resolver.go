package replicate

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
)

// StagingEquip is the resolved staging-side identity of a legacy equipment.
// id_site / id_area / id_enterprise are taken from the STAGING equipments
// row (never trusted from the legacy payload), so PO inserts always carry a
// self-consistent staging hierarchy.
type StagingEquip struct {
	IDEquipment  int
	IDSite       int
	IDArea       int
	IDEnterprise int
}

// Resolver maps legacy ids -> staging ids by NATURAL KEY.
//
//   - enterprise: a fixed configured map (1 -> 3).
//   - equipment:  legacy id_equipment -> packml BASE topic (enterprise
//     prefix stripped) -> staging id_equipment. The base topic is the
//     one non-Admin/Status packml_topic, so `C-PACK/SC/LINHAS/L5/BREYER`
//     and `CPACK/SC/LINHAS/L5/BREYER` both normalise to
//     `SC/LINHAS/L5/BREYER` and join. Equipment NAMES are NOT unique in
//     CPACK (BREYER/TEXA/PTH repeat across lines) — the topic path is the
//     only stable natural key.
//
// The whole map is built once at startup from both pools and cached; a
// per-id read-through miss just logs (unresolved legacy equipment is a
// topology drift the operator must reconcile, not a poison message).
type Resolver struct {
	srcEnterprise int
	dstEnterprise int

	mu    sync.RWMutex
	equip map[int]StagingEquip // legacy id_equipment -> staging identity
}

// normalizeBaseTopic strips the leading enterprise-name segment
// (`C-PACK/...` vs `CPACK/...`) so the structural suffix is comparable
// across the two DBs. Uppercased for defensive case-insensitivity.
func normalizeBaseTopic(topic string) string {
	i := strings.IndexByte(topic, '/')
	if i < 0 {
		return ""
	}
	return strings.ToUpper(strings.TrimSpace(topic[i+1:]))
}

// isCountTopic reports whether a packml_topic is a per-tag count/status
// leaf rather than the equipment's clean base topic.
func isCountTopic(topic string) bool {
	return strings.Contains(topic, "/Admin/") || strings.Contains(topic, "/Status/") ||
		strings.HasSuffix(topic, "/Status")
}

// hasEmptySegment reports whether any `/`-delimited path segment is empty
// (a `//`, a leading `/`, or a trailing `/`). Such a topic is never a valid
// equipment base topic — it is a hierarchy-node artifact.
//
// Why this guard exists: the STAGING SANDBOX-CPACK twin (ent 2000003) has
// historically accumulated INACTIVE junk rows like
// `SANDBOX_CPACK/SC/LINHAS//` and `SBXCPACK_STAGING/SC/CELULA1//` — emitted
// by an earlier packml-topic generator run with empty line/machine name
// segments, under stale enterprise-name prefixes. Because such a topic is
// SHORTER than the real base topic (`SBXCPACK/SC/LINHAS/L6/POLYTYPE`) and is
// NOT an Admin/Status leaf, baseTopicByEquip's shortest-non-count pick chose
// the junk, normalising the equipment to `SC/LINHAS//` instead of
// `SC/LINHAS/L6/POLYTYPE`. That orphaned the real base-topic norm, so 7 CPACK
// lead machines (CER400/HOTMADAG/POLYTYPE1/PTH40-03/FLEXO/L6-POLYTYPE/SLEEVE1)
// resolved to nothing on the sandbox and their replayed operator downtimes
// were dropped as "unresolved equipment". fetchEquipTopics already filters
// id_equipment IS NOT NULL; this guard closes the same drift at the topic
// level so the resolver is robust even if such rows are re-linked.
func hasEmptySegment(topic string) bool {
	for _, seg := range strings.Split(topic, "/") {
		if strings.TrimSpace(seg) == "" {
			return true
		}
	}
	return false
}

// baseTopicByEquip reduces a set of (id_equipment, packml_topic) rows to a
// single normalised base topic per equipment: the shortest topic that is
// not an Admin/Status leaf. Pure so it is unit-testable without a DB.
func baseTopicByEquip(rows []equipTopic) map[int]string {
	best := map[int]string{}    // id -> raw base topic (shortest non-leaf)
	for _, r := range rows {
		if isCountTopic(r.topic) || hasEmptySegment(r.topic) {
			continue
		}
		cur, ok := best[r.id]
		if !ok || len(r.topic) < len(cur) {
			best[r.id] = r.topic
		}
	}
	out := make(map[int]string, len(best))
	for id, t := range best {
		if n := normalizeBaseTopic(t); n != "" {
			out[id] = n
		}
	}
	return out
}

type equipTopic struct {
	id    int
	topic string
}

// BuildResolver constructs the legacy->staging equipment map by reading
// packml_register from both DBs plus the staging equipments hierarchy.
func BuildResolver(ctx context.Context, legacy, dest *pgxpool.Pool, srcEnt, dstEnt int, logger *slog.Logger) (*Resolver, error) {
	legRows, err := fetchEquipTopics(ctx, legacy, srcEnt)
	if err != nil {
		return nil, fmt.Errorf("legacy packml_register: %w", err)
	}
	dstRows, err := fetchEquipTopics(ctx, dest, dstEnt)
	if err != nil {
		return nil, fmt.Errorf("dest packml_register: %w", err)
	}
	legByEquip := baseTopicByEquip(legRows) // legacy id -> norm
	dstByEquip := baseTopicByEquip(dstRows) // staging id -> norm

	// Invert staging: norm -> staging id.
	dstByNorm := make(map[string]int, len(dstByEquip))
	for id, norm := range dstByEquip {
		dstByNorm[norm] = id
	}

	// Staging equipments hierarchy: staging id -> (site, area).
	hier, err := fetchHierarchy(ctx, dest, dstEnt)
	if err != nil {
		return nil, fmt.Errorf("dest equipments hierarchy: %w", err)
	}

	equip := make(map[int]StagingEquip, len(legByEquip))
	var unresolved []int
	for legID, norm := range legByEquip {
		dstID, ok := dstByNorm[norm]
		if !ok {
			unresolved = append(unresolved, legID)
			continue
		}
		h := hier[dstID] // zero-value site/area if the equipments row is missing
		equip[legID] = StagingEquip{
			IDEquipment:  dstID,
			IDSite:       h.site,
			IDArea:       h.area,
			IDEnterprise: dstEnt,
		}
	}

	logger.Info("resolver built",
		slog.Int("legacy_equipments", len(legByEquip)),
		slog.Int("staging_equipments", len(dstByEquip)),
		slog.Int("mapped", len(equip)),
		slog.Int("unresolved", len(unresolved)))
	if len(unresolved) > 0 {
		logger.Warn("unresolved legacy equipment (no staging twin by base topic)",
			slog.Any("legacy_ids", unresolved))
	}

	return &Resolver{srcEnterprise: srcEnt, dstEnterprise: dstEnt, equip: equip}, nil
}

type siteArea struct{ site, area int }

func fetchEquipTopics(ctx context.Context, pool *pgxpool.Pool, ent int) ([]equipTopic, error) {
	rows, err := pool.Query(ctx,
		`SELECT id_equipment, packml_topic FROM packml_register
		   WHERE id_enterprise = $1 AND id_equipment IS NOT NULL AND packml_topic IS NOT NULL`,
		ent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []equipTopic
	for rows.Next() {
		var e equipTopic
		if err := rows.Scan(&e.id, &e.topic); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func fetchHierarchy(ctx context.Context, pool *pgxpool.Pool, ent int) (map[int]siteArea, error) {
	rows, err := pool.Query(ctx,
		`SELECT id_equipment, id_site, id_area FROM equipments WHERE id_enterprise = $1`, ent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int]siteArea{}
	for rows.Next() {
		var id, site, area int
		if err := rows.Scan(&id, &site, &area); err != nil {
			return nil, err
		}
		out[id] = siteArea{site: site, area: area}
	}
	return out, rows.Err()
}

// ResolveEquipment maps a legacy id_equipment to its staging identity.
func (r *Resolver) ResolveEquipment(legacyID int) (StagingEquip, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.equip[legacyID]
	return e, ok
}

// DstEnterprise is the staging enterprise id for the polled tenant.
func (r *Resolver) DstEnterprise() int { return r.dstEnterprise }
