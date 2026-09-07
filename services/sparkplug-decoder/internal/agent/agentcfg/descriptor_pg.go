// descriptor_pg.go — the pgx-backed DescriptorStatusFetcher (ADR-0045
// Phase-2a). It reads ONE column, client_descriptors.status, scoped to the
// tenant enterprise — the per-tenant cutover flip signal that edge-api's
// onboarding endpoints write and the agent reads at boot (see cutover.go).
//
// client_descriptors is OWNED + written by edge-api (a sibling repo); the agent
// only reads it. It may not exist yet on a given environment (edge-api's
// migration is a separate deploy), so the caller treats a query error as a SAFE
// fallback to the static tag map — the fetcher never assumes the table is
// present.
//
// It reuses the SAME pgxpool the register loader uses (register_pg.go): the
// boot path opens one pool, reads the status with it, and — only if the tenant
// is cutover — fetches the register rows with it. Never a second pool.
package agentcfg

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DescriptorStatusFetcher reads a tenant's config-as-data lifecycle status from
// client_descriptors.
type DescriptorStatusFetcher struct {
	pool *pgxpool.Pool
}

// NewDescriptorStatusFetcher builds a fetcher over an existing pool (the same
// pool the register loader uses — do not open a second one).
func NewDescriptorStatusFetcher(pool *pgxpool.Pool) *DescriptorStatusFetcher {
	return &DescriptorStatusFetcher{pool: pool}
}

// FetchStatus returns client_descriptors.status for the enterprise.
//
// A MISSING row is ("", nil) — "no descriptor for this tenant yet", a normal
// pre-onboarding state, NOT an error — so the caller falls back to the static
// map without a warning. Any real failure (table absent, DB down, scan error)
// is returned as a non-nil error; the caller logs it and still falls back to
// static (fail-safe: a broken read never flips a tenant).
func (f *DescriptorStatusFetcher) FetchStatus(ctx context.Context, enterpriseID int) (string, error) {
	const q = `SELECT status FROM client_descriptors WHERE id_enterprise = $1`
	var status string
	err := f.pool.QueryRow(ctx, q, enterpriseID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("client_descriptors status (ent %d): %w", enterpriseID, err)
	}
	return status, nil
}
