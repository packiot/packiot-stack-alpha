// createpo.go — ADR-0010 10.3 slice 3: parameter 30805 (create PO),
// ported from Prep 30805 + Build 30805 (the capture file).
//
// One tx replaces prod's two-round-trip prep/build split. Chain:
// ensure product family → ensure product → ensure client → resolve
// ids + inherited conversion_factor → INSERT PO status=1 with
// ON CONFLICT (id_enterprise, id_order) DO UPDATE custom_field +
// id_equipment (the natural-key upsert — bug-247/248 rules).
//
// GUARDRAIL STATEMENT (audit rules): relies on production_orders'
// natural key UNIQUE (id_enterprise, id_order); satisfies the ts
// CHECK via status=1 with ts_start NULL. product_families/products/
// clients are REFERENCE-plane → refSchema (public on both DBs).
//
// DEFENSIVE DIVERGENCE (documented): prod's family-id subselect
// filtered by name ONLY (no enterprise) — cross-enterprise name
// collisions would error. We filter by (name, enterprise): identical
// result whenever prod worked, no error where prod would break.
package pocontrol

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// HandlesCreatePO reports whether id belongs to slice 3.
func HandlesCreatePO(id int) bool { return id == 30805 }

type createPOPayload struct {
	IDOrder         json.Number     `json:"id_order"`
	OrderQuantity   json.Number     `json:"order_quantity"`
	NmProduct       string          `json:"nm_product"`
	CdProduct       string          `json:"cd_product"`
	TxtProduct      string          `json:"txt_product"`
	NmClient        string          `json:"nm_client"`
	CdProductFamily *string         `json:"cd_product_family"`
	CustomField     json.RawMessage `json:"custom_field"`
	Timestamp       json.Number     `json:"timestamp"`
}

const cpFamilyUpsert = `
	INSERT INTO %[2]s.product_families (nm_product_family, id_enterprise)
	VALUES ($1, $2)
	ON CONFLICT (id_enterprise, nm_product_family) DO UPDATE SET nm_product_family = EXCLUDED.nm_product_family
	RETURNING id_product_family`

const cpProductInsert = `
	INSERT INTO %[2]s.products (nm_product, id_product_family, txt_product, id_enterprise, cd_product)
	SELECT $1, $2, $3, $4, $5
	 WHERE NOT EXISTS (SELECT 1 FROM %[2]s.products WHERE cd_product = $5 AND id_enterprise = $4)`

const cpClientUpsert = `
	INSERT INTO %[2]s.clients (nm_client, id_enterprise)
	VALUES ($1, $2)
	ON CONFLICT (nm_client, id_enterprise) DO NOTHING`

const cpResolve = `
	SELECT (SELECT id_product FROM %[2]s.products  WHERE cd_product = $1 AND id_enterprise = $3),
	       (SELECT id_client  FROM %[2]s.clients   WHERE nm_client  = $2 AND id_enterprise = $3),
	       (SELECT conversion_factor FROM %[1]s.production_orders
	         WHERE id_product = (SELECT id_product FROM %[2]s.products WHERE cd_product = $1 AND id_enterprise = $3)
	         ORDER BY ts_creation DESC LIMIT 1)`

const cpInsertPO = `
	INSERT INTO %[1]s.production_orders
	       (id_enterprise, id_site, id_area, id_equipment, id_product, id_client,
	        status, production_programmed, production_ordered, id_order, ts_creation,
	        txt_production_order_description, conversion_factor, id_order_text, custom_field)
	VALUES ($1, $2, $3, $4, $5, $6, 1, $7, $7, $8, $9, $10, $11, $12, $13)
	ON CONFLICT (id_enterprise, id_order) DO UPDATE SET
	       custom_field = EXCLUDED.custom_field, id_equipment = EXCLUDED.id_equipment`

func (h *Handler) executeCreatePO(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	info, err := h.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil {
		return fmt.Errorf("resolve: %w", err)
	}
	if info == nil {
		h.noops.Add(1)
		return nil
	}
	var p createPOPayload
	if err := json.Unmarshal(m.Value, &p); err != nil {
		return fmt.Errorf("30805 payload: %w", err)
	}
	idOrder, err := p.IDOrder.Int64()
	if err != nil {
		return fmt.Errorf("30805 id_order required: %w", err)
	}
	qty, _ := p.OrderQuantity.Float64()
	tsMs, terr := p.Timestamp.Int64()
	if terr != nil || tsMs == 0 {
		tsMs = m.Timestamp
	}
	tsCreated := time.UnixMilli(tsMs).Round(time.Second).UTC()

	// Prod: absent family → the '' family (DO UPDATE keeps RETURNING).
	family := ""
	if p.CdProductFamily != nil {
		family = *p.CdProductFamily
	}
	custom := "null"
	if len(p.CustomField) > 0 {
		custom = string(p.CustomField)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	var familyID int64
	if err := tx.QueryRow(ctx, fmt.Sprintf(cpFamilyUpsert, schema, refSchema),
		family, info.IDEnterprise).Scan(&familyID); err != nil {
		return fmt.Errorf("family upsert: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(cpProductInsert, schema, refSchema),
		p.NmProduct, familyID, p.TxtProduct, info.IDEnterprise, p.CdProduct); err != nil {
		return fmt.Errorf("product insert: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(cpClientUpsert, schema, refSchema),
		p.NmClient, info.IDEnterprise); err != nil {
		return fmt.Errorf("client upsert: %w", err)
	}
	var idProduct, idClient *int64
	var convFactor *float64
	if err := tx.QueryRow(ctx, fmt.Sprintf(cpResolve, schema, refSchema),
		p.CdProduct, p.NmClient, info.IDEnterprise).Scan(&idProduct, &idClient, &convFactor); err != nil && err != pgx.ErrNoRows {
		return fmt.Errorf("resolve ids: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(cpInsertPO, schema),
		info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		idProduct, idClient, qty, idOrder, tsCreated,
		p.TxtProduct, convFactor, fmt.Sprint(idOrder), custom); err != nil {
		return fmt.Errorf("po insert: %w", err)
	}
	h.created.Add(1)
	return tx.Commit(ctx)
}
