package replicate

// PO product/client ENRICH pass — part of the PO reconciler tick.
//
// Why it exists: neither path that creates CPACK POs in the twin carries the
// product or the client. The user_logs replay (handlers.go) only sees the
// operator payload (idOrder, quantity, notes), and the reconciler INSERT
// (reconcile.go) copies status/counters/timestamps. Legacy attaches
// id_product/id_client outside the audit trail (ERP-planned POs are created
// with them), so since the cutover EVERY twin PO landed with both NULL: the
// Overview "Client / Product" labels were blank, and so was anything else
// joining products/clients (measured 2026-09-25: 0 of 1,285 September twin POs
// linked vs 235 of 448 in legacy).
//
// What it does, per tick:
//  1. twin POs in the window that still have a NULL id_product or id_client;
//  2. legacy's product/client (with names) for those same id_orders;
//  3. resolve each dimension in the twin by its NATURAL KEY, which the schema
//     enforces as unique: (id_enterprise, nm_product) / (id_enterprise,
//     nm_client) / (id_enterprise, nm_product_family). Ids are NOT trusted on
//     their own: both sequences sit at legacy's max, so the next native twin
//     product and the next legacy product would share an id while being
//     different products. A dimension missing in the twin is created, keeping
//     the legacy id when it is free (the historian archive joins id_product);
//  4. one set-based UPDATE that fills ONLY the NULL columns (COALESCE), so a
//     value set in the new stack is never overwritten.
//
// Read-only on legacy. Idempotent: a re-run finds nothing NULL left to fill.

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

// Twin POs still missing a product or a client, created inside the window.
const sqlEnrichTwinCandidates = `SELECT id_order FROM core.production_orders
	 WHERE id_enterprise = $1 AND (id_product IS NULL OR id_client IS NULL)
	   AND ts_creation > $2`

// Legacy's product/client for those id_orders, with the names the twin
// resolves by. Only rows that actually carry something are returned.
const sqlEnrichLegacyLinks = `SELECT po.id_order,
	       po.id_product, p.nm_product, p.cd_product, pf.nm_product_family,
	       po.id_client, c.nm_client
	  FROM production_orders po
	  LEFT JOIN products p ON p.id_product = po.id_product
	  LEFT JOIN product_families pf ON pf.id_product_family = p.id_product_family
	  LEFT JOIN clients c ON c.id_client = po.id_client
	 WHERE po.id_enterprise = $1 AND po.id_order = ANY($2::bigint[])
	   AND (po.id_product IS NOT NULL OR po.id_client IS NOT NULL)`

const (
	sqlEnrichFindProduct = `SELECT id_product FROM core.products WHERE id_enterprise = $1 AND nm_product = $2`
	sqlEnrichFindFamily  = `SELECT id_product_family FROM core.product_families WHERE id_enterprise = $1 AND nm_product_family = $2`
	sqlEnrichFindClient  = `SELECT id_client FROM core.clients WHERE id_enterprise = $1 AND nm_client = $2`

	sqlEnrichInsertFamily = `INSERT INTO core.product_families (nm_product_family, id_enterprise)
	VALUES ($1, $2) ON CONFLICT DO NOTHING`

	// Keep the legacy id when nobody holds it; otherwise the second statement
	// lets the sequence pick one. ON CONFLICT DO NOTHING covers every unique
	// constraint (name, code) — the caller re-reads by name afterwards.
	sqlEnrichInsertProductKeepID = `INSERT INTO core.products (id_product, nm_product, cd_product, id_product_family, id_enterprise)
	SELECT $1, $2, $3, $4, $5
	 WHERE NOT EXISTS (SELECT 1 FROM core.products WHERE id_product = $1)
	ON CONFLICT DO NOTHING`
	sqlEnrichInsertProduct = `INSERT INTO core.products (nm_product, cd_product, id_product_family, id_enterprise)
	VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING`
	sqlEnrichInsertClientKeepID = `INSERT INTO core.clients (id_client, nm_client, id_enterprise)
	SELECT $1, $2, $3
	 WHERE NOT EXISTS (SELECT 1 FROM core.clients WHERE id_client = $1)
	ON CONFLICT DO NOTHING`
	sqlEnrichInsertClient = `INSERT INTO core.clients (nm_client, id_enterprise)
	VALUES ($1, $2) ON CONFLICT DO NOTHING`

	// After inserting an explicit id, move the sequence past it so a later
	// native insert can't collide with it.
	sqlEnrichBumpProductSeq = `SELECT setval(pg_get_serial_sequence('core.products','id_product'), $1)
	 WHERE $1 > (SELECT last_value FROM core.products_id_product_seq)`
	sqlEnrichBumpClientSeq = `SELECT setval(pg_get_serial_sequence('core.clients','id_client'), $1)
	 WHERE $1 > (SELECT last_value FROM core.clients_id_client_seq)`

	// Fill ONLY what is still NULL — never overwrite a value set in the twin.
	sqlEnrichUpdatePOs = `UPDATE core.production_orders po
	   SET id_product = COALESCE(po.id_product, u.id_product),
	       id_client  = COALESCE(po.id_client, u.id_client),
	       last_update = now()
	  FROM unnest($2::bigint[], $3::bigint[], $4::bigint[]) AS u(id_order, id_product, id_client)
	 WHERE po.id_enterprise = $1 AND po.id_order = u.id_order
	   AND ((po.id_product IS NULL AND u.id_product IS NOT NULL)
	     OR (po.id_client IS NULL AND u.id_client IS NOT NULL))`
)

// legacyLink is one legacy PO's product/client, as names the twin can resolve.
type legacyLink struct {
	idOrder     int64
	productID   *int64
	productName *string
	productCode *string
	familyName  *string
	clientID    *int64
	clientName  *string
}

// enrichRow is one resolved twin update. A nil id means "nothing to fill".
type enrichRow struct {
	idOrder   int64
	productID *int64
	clientID  *int64
}

// buildEnrichBatch turns resolved rows into the three parallel arrays the
// UPDATE unnests, dropping rows with nothing to fill.
func buildEnrichBatch(rows []enrichRow) (orders []int64, products, clients []*int64) {
	for _, r := range rows {
		if r.productID == nil && r.clientID == nil {
			continue
		}
		orders = append(orders, r.idOrder)
		products = append(products, r.productID)
		clients = append(clients, r.clientID)
	}
	return orders, products, clients
}

// dimResolver resolves twin dimension ids by natural key, caching per pass.
type dimResolver struct {
	rc       *POReconciler
	ent      int
	keepIDs  bool // create missing dims with legacy's id when free
	products map[string]*int64
	families map[string]*int64
	clients  map[string]*int64
}

func (rc *POReconciler) runEnrich(ctx context.Context) {
	ent := rc.cfg.DstEnterprise
	since := time.Now().AddDate(0, 0, -rc.cfg.ReconcileEnrichWindowDays)

	candidates, err := rc.enrichCandidates(ctx, ent, since)
	if err != nil {
		rc.logger.Warn("PO enrich: twin candidate fetch failed", slog.String("err", err.Error()))
		return
	}
	if len(candidates) == 0 {
		return
	}
	links, err := rc.enrichLegacyLinks(ctx, candidates)
	if err != nil {
		rc.logger.Warn("PO enrich: legacy fetch failed", slog.String("err", err.Error()))
		return
	}

	res := &dimResolver{rc: rc, ent: ent, keepIDs: rc.cfg.ReconcileEnrichKeepLegacyIDs,
		products: map[string]*int64{}, families: map[string]*int64{}, clients: map[string]*int64{}}
	rows := make([]enrichRow, 0, len(links))
	for _, l := range links {
		row := enrichRow{idOrder: l.idOrder}
		if l.productID != nil {
			row.productID = res.product(ctx, l)
		}
		if l.clientID != nil {
			row.clientID = res.client(ctx, l)
		}
		rows = append(rows, row)
	}

	orders, products, clients := buildEnrichBatch(rows)
	if len(orders) == 0 {
		return
	}
	ct, err := rc.dest.Exec(ctx, sqlEnrichUpdatePOs, ent, orders, products, clients)
	if err != nil {
		rc.logger.Warn("PO enrich: update failed", slog.String("err", err.Error()))
		return
	}
	n := int(ct.RowsAffected())
	rc.m.AddReconcileEnriched(n)
	rc.logger.Info("PO enrich pass done",
		slog.Int("twin_candidates", len(candidates)),
		slog.Int("legacy_links", len(links)),
		slog.Int("enriched", n))
}

func (rc *POReconciler) enrichCandidates(ctx context.Context, ent int, since time.Time) ([]int64, error) {
	rows, err := rc.dest.Query(ctx, sqlEnrichTwinCandidates, ent, since)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

func (rc *POReconciler) enrichLegacyLinks(ctx context.Context, idOrders []int64) ([]legacyLink, error) {
	rows, err := rc.legacy.Query(ctx, sqlEnrichLegacyLinks, rc.cfg.SrcEnterprise, idOrders)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []legacyLink
	for rows.Next() {
		var l legacyLink
		if err := rows.Scan(&l.idOrder, &l.productID, &l.productName, &l.productCode, &l.familyName,
			&l.clientID, &l.clientName); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// findID runs a single-id lookup; (nil, nil) when there is no row.
func (d *dimResolver) findID(ctx context.Context, sql string, args ...any) (*int64, error) {
	var id int64
	err := d.rc.dest.QueryRow(ctx, sql, args...).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

func (d *dimResolver) skip(reason string, l legacyLink, err error) *int64 {
	d.rc.m.IncReconcileEnrichSkip(reason)
	attrs := []any{slog.String("reason", reason), slog.Int64("id_order", l.idOrder)}
	if err != nil {
		attrs = append(attrs, slog.String("err", err.Error()))
	}
	d.rc.logger.Warn("PO enrich: link skipped", attrs...)
	return nil
}

func (d *dimResolver) family(ctx context.Context, name string) (*int64, error) {
	if id, ok := d.families[name]; ok {
		return id, nil
	}
	id, err := d.findID(ctx, sqlEnrichFindFamily, d.ent, name)
	if err == nil && id == nil {
		if _, err = d.rc.dest.Exec(ctx, sqlEnrichInsertFamily, name, d.ent); err == nil {
			id, err = d.findID(ctx, sqlEnrichFindFamily, d.ent, name)
		}
	}
	if err != nil {
		return nil, err
	}
	d.families[name] = id
	return id, nil
}

func (d *dimResolver) product(ctx context.Context, l legacyLink) *int64 {
	if l.productName == nil || *l.productName == "" {
		return d.skip("product_unnamed", l, nil)
	}
	name := *l.productName
	if id, ok := d.products[name]; ok {
		return id
	}
	id, err := d.findID(ctx, sqlEnrichFindProduct, d.ent, name)
	if err != nil {
		return d.skip("product_lookup_error", l, err)
	}
	if id == nil {
		if l.familyName == nil || *l.familyName == "" {
			return d.skip("product_no_family", l, nil)
		}
		fam, ferr := d.family(ctx, *l.familyName)
		if ferr != nil || fam == nil {
			return d.skip("family_unresolved", l, ferr)
		}
		kept := false
		var ierr error
		if d.keepIDs {
			ct, err := d.rc.dest.Exec(ctx, sqlEnrichInsertProductKeepID, *l.productID, name, l.productCode, *fam, d.ent)
			ierr, kept = err, err == nil && ct.RowsAffected() > 0
		}
		if ierr == nil && kept {
			_, ierr = d.rc.dest.Exec(ctx, sqlEnrichBumpProductSeq, *l.productID)
		} else if ierr == nil {
			_, ierr = d.rc.dest.Exec(ctx, sqlEnrichInsertProduct, name, l.productCode, *fam, d.ent)
		}
		if ierr != nil {
			return d.skip("product_insert_error", l, ierr)
		}
		if id, err = d.findID(ctx, sqlEnrichFindProduct, d.ent, name); err != nil || id == nil {
			// e.g. its cd_product is already taken by a differently-named product.
			return d.skip("product_conflict", l, err)
		}
	}
	d.products[name] = id
	return id
}

func (d *dimResolver) client(ctx context.Context, l legacyLink) *int64 {
	if l.clientName == nil || *l.clientName == "" {
		return d.skip("client_unnamed", l, nil)
	}
	name := *l.clientName
	if id, ok := d.clients[name]; ok {
		return id
	}
	id, err := d.findID(ctx, sqlEnrichFindClient, d.ent, name)
	if err != nil {
		return d.skip("client_lookup_error", l, err)
	}
	if id == nil {
		kept := false
		var ierr error
		if d.keepIDs {
			ct, err := d.rc.dest.Exec(ctx, sqlEnrichInsertClientKeepID, *l.clientID, name, d.ent)
			ierr, kept = err, err == nil && ct.RowsAffected() > 0
		}
		if ierr == nil && kept {
			_, ierr = d.rc.dest.Exec(ctx, sqlEnrichBumpClientSeq, *l.clientID)
		} else if ierr == nil {
			_, ierr = d.rc.dest.Exec(ctx, sqlEnrichInsertClient, name, d.ent)
		}
		if ierr != nil {
			return d.skip("client_insert_error", l, ierr)
		}
		if id, err = d.findID(ctx, sqlEnrichFindClient, d.ent, name); err != nil || id == nil {
			return d.skip("client_conflict", l, err)
		}
	}
	d.clients[name] = id
	return id
}
