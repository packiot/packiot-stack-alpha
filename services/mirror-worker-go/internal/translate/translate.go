// Package translate maps prod entity IDs → staging entity IDs.
//
// Strategy by entity type:
//
//   enterprise   — hardcoded (prod CPACK=1 → staging CPACK=3); no lookup
//   site         — business key 'nm_site'
//   area         — business key 'nm_area'
//   equipment    — business key 'packml_topic' (canonical, post-remap)
//   PO           — mirror_id_map cache first, business key 'nu_production_order' fallback
//   event        — TODO phase 2 — mirror_id_map cache first, interval-overlap fallback (A4b)
//
// Mirrors the TS translate.ts faithfully.
package translate

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

type Translator struct {
	prod    *db.Prod
	staging *db.Staging
	cfg     *config.Config
	logger  *slog.Logger
}

func New(prod *db.Prod, staging *db.Staging, cfg *config.Config, logger *slog.Logger) *Translator {
	return &Translator{prod: prod, staging: staging, cfg: cfg, logger: logger}
}

// ErrUnmapped — translation target absent on staging. Caller writes to
// DLQ rather than retrying forever.
var ErrUnmapped = errors.New("entity unmapped on staging")

// remapTopic: prod's 'C-PACK/' prefix → staging's 'CPACK/'.
func remapTopic(prodTopic string) string {
	return strings.Replace(prodTopic, "C-PACK/", "CPACK/", 1)
}

func (t *Translator) Enterprise(prodID int) (int, error) {
	if prodID != t.cfg.ProdEnterpriseID {
		return 0, fmt.Errorf("unexpected prod enterprise %d, only %d is mirrored",
			prodID, t.cfg.ProdEnterpriseID)
	}
	return t.cfg.StagingEnterpriseID, nil
}

func (t *Translator) Site(ctx context.Context, prodSiteID int) (int, error) {
	var nmSite string
	found, err := t.prod.SelectOne(ctx,
		`SELECT nm_site FROM sites WHERE id_site = $1 AND id_enterprise = $2`,
		[]any{prodSiteID, t.cfg.ProdEnterpriseID}, &nmSite)
	if err != nil {
		return 0, fmt.Errorf("prod site lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod site row for id_site=%d: %w", prodSiteID, ErrUnmapped)
	}
	var stagingID int
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_site FROM sites WHERE nm_site = $1 AND id_enterprise = $2`,
		[]any{nmSite, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging site lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging site with nm_site=%q: %w", nmSite, ErrUnmapped)
	}
	return stagingID, nil
}

func (t *Translator) Area(ctx context.Context, prodAreaID int) (int, error) {
	var nmArea string
	found, err := t.prod.SelectOne(ctx,
		`SELECT nm_area FROM areas WHERE id_area = $1 AND id_enterprise = $2`,
		[]any{prodAreaID, t.cfg.ProdEnterpriseID}, &nmArea)
	if err != nil {
		return 0, fmt.Errorf("prod area lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod area row for id_area=%d: %w", prodAreaID, ErrUnmapped)
	}
	var stagingID int
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_area FROM areas WHERE nm_area = $1 AND id_enterprise = $2`,
		[]any{nmArea, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging area lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging area with nm_area=%q: %w", nmArea, ErrUnmapped)
	}
	return stagingID, nil
}

// Equipment resolves prod equipment_id → staging via packml_topic.
func (t *Translator) Equipment(ctx context.Context, prodEquipmentID int) (int, error) {
	var prodTopic string
	found, err := t.prod.SelectOne(ctx,
		`SELECT pr.packml_topic FROM packml_register pr
		  WHERE pr.id_equipment = $1 AND pr.id_enterprise = $2
		  ORDER BY pr.active DESC NULLS LAST LIMIT 1`,
		[]any{prodEquipmentID, t.cfg.ProdEnterpriseID}, &prodTopic)
	if err != nil {
		return 0, fmt.Errorf("prod packml_register lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod packml_register row for id_equipment=%d: %w",
			prodEquipmentID, ErrUnmapped)
	}
	stagingTopic := remapTopic(prodTopic)
	var stagingID int
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_equipment FROM packml_register
		  WHERE packml_topic = $1 AND id_enterprise = $2
		  ORDER BY active DESC NULLS LAST LIMIT 1`,
		[]any{stagingTopic, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging packml_register lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging packml_register row for topic=%q (remapped from %q): %w",
			stagingTopic, prodTopic, ErrUnmapped)
	}
	return stagingID, nil
}

// ProductionOrder: cache first, business-key fallback on nu_production_order.
func (t *Translator) ProductionOrder(ctx context.Context, prodPOID int64) (int64, error) {
	stagingID, found, err := t.staging.LookupMapping(ctx, "production_order", t.cfg.SourceName, prodPOID)
	if err != nil {
		return 0, fmt.Errorf("mapping lookup: %w", err)
	}
	if found {
		return stagingID, nil
	}
	var nu string
	found, err = t.prod.SelectOne(ctx,
		`SELECT nu_production_order::text FROM production_orders
		  WHERE id_production_order = $1 AND id_enterprise = $2`,
		[]any{prodPOID, t.cfg.ProdEnterpriseID}, &nu)
	if err != nil {
		return 0, fmt.Errorf("prod PO lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod PO row for id_production_order=%d: %w", prodPOID, ErrUnmapped)
	}
	var sid int64
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_production_order FROM production_orders
		  WHERE nu_production_order = $1 AND id_enterprise = $2
		  ORDER BY id_production_order DESC LIMIT 1`,
		[]any{nu, t.cfg.StagingEnterpriseID}, &sid)
	if err != nil {
		return 0, fmt.Errorf("staging PO lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging PO with nu_production_order=%q: %w", nu, ErrUnmapped)
	}
	return sid, nil
}

// EquipmentEvent — TODO phase 2 of MW-2 port.
// The TS version uses an interval-overlap matcher keyed on
// (equipment, status) with a minimum-overlap threshold. Defer the port
// because the SQL with NULL ts_end fallback needs careful pgx handling.
// Until ported, the event-* handlers will throw ErrUnmapped and rely on
// the TS mirror-worker (parallel-running) to handle event replays.
func (t *Translator) EquipmentEvent(_ context.Context, prodEventID int64) (int64, error) {
	return 0, fmt.Errorf("EquipmentEvent translator not yet ported (TS handles for now); prodEventID=%d: %w",
		prodEventID, ErrUnmapped)
}
