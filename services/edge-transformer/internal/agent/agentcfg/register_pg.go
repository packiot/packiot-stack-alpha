// register_pg.go — the pgx-backed RegisterFetcher (task #13, ADR-0009 Phase-2
// "add pgx only if the transformer needs DB access for tenant discovery"). This
// is exactly that phase: the register-driven loader reads the tenant's
// equipment set from packml_register.
//
// It is compiled unconditionally but DIALLED only when AGENT_TAGMAP_FROM_REGISTER
// is on (see cmd/sparkplug-agent/main.go), so the default agent run keeps zero
// DB dependency at runtime. The query mirrors operator-adapter's resolver: a
// packml_register→equipments→areas→sites join scoped to the tenant enterprise,
// with the same deterministic "shortest topic per equipment" tie-break as
// translate.go (an equipment has one register row per metric; the canonical
// equipment topic is the shortest one).
package agentcfg

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PGRegisterFetcher fetches the tenant's equipment rows from packml_register.
type PGRegisterFetcher struct {
	pool *pgxpool.Pool
}

// NewPGRegisterFetcher builds a fetcher over an existing pool.
func NewPGRegisterFetcher(pool *pgxpool.Pool) *PGRegisterFetcher {
	return &PGRegisterFetcher{pool: pool}
}

// compile-time assertion.
var _ RegisterFetcher = (*PGRegisterFetcher)(nil)

// FetchEquipment returns one row per active equipment under the enterprise: the
// canonical (shortest) packml_topic, its id_equipment, and tp_equipment. The
// canonicalPrefix is advisory (the loader filters by prefix after fixup); the
// enterprise scope is the authoritative cross-tenant guard.
//
// DISTINCT ON (id_equipment) + ORDER BY length(packml_topic) picks the canonical
// short topic per equipment (e.g. "C-PACK/SC/LINHAS/L4/TEXA"), discarding the
// per-metric extensions ("/Admin/…", "/Status/…") — the same rule translate.go
// established after a prod incident where a non-deterministic LIMIT 1 picked a
// corrupted long topic.
func (f *PGRegisterFetcher) FetchEquipment(ctx context.Context, enterpriseID int, canonicalPrefix string) ([]RegisterRow, error) {
	const q = `
		SELECT DISTINCT ON (e.id_equipment)
		       e.id_equipment, pr.packml_topic, e.tp_equipment
		  FROM packml_register pr
		  JOIN equipments e ON e.id_equipment = pr.id_equipment
		  JOIN areas a      ON a.id_area      = e.id_area
		  JOIN sites s      ON s.id_site      = a.id_site
		 WHERE s.id_enterprise = $1
		   AND pr.active
		   AND pr.id_equipment IS NOT NULL
		 ORDER BY e.id_equipment,
		          length(pr.packml_topic) ASC,
		          pr.id_packml_register ASC
	`
	rows, err := f.pool.Query(ctx, q, enterpriseID)
	if err != nil {
		return nil, fmt.Errorf("packml_register fetch (ent %d): %w", enterpriseID, err)
	}
	defer rows.Close()

	var out []RegisterRow
	for rows.Next() {
		var r RegisterRow
		if err := rows.Scan(&r.IDEquipment, &r.PackMLTopic, &r.TPEquipment); err != nil {
			return nil, fmt.Errorf("scan register row: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate register rows: %w", err)
	}
	return out, nil
}
