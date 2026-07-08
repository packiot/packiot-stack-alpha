package main

import (
	"strings"
	"testing"
	"time"
)

// Tenancy isolation gate (ADR-0021 M1 §2, Level-1 as a merge rule).
//
// The composable read surface is multi-tenant: customer_id is injected
// server-side from the API key as $1 and is NEVER client-supplied. The
// structural invariant that guarantees no cross-tenant bleed is:
//
//	every dataset's FIRST parameter is pEnterprise (bound to $1), and its
//	SQL actually uses $1 to scope to that tenant.
//
// A dataset added without that guard — a raw SELECT with no enterprise
// scope, or one whose first param is a client-supplied filter — would
// return another tenant's rows. This test fails such a dataset at CI,
// so isolation is a checked property, not a hope. It is deliberately
// DB-free: it proves the *contract* every dataset must honor.

func TestEveryDatasetIsTenantScoped(t *testing.T) {
	if len(datasets) == 0 {
		t.Fatal("no datasets registered — the isolation gate has nothing to guard")
	}
	for name, ds := range datasets {
		// 1. The tenancy guard must be the FIRST parameter, so it binds $1.
		if len(ds.params) == 0 || ds.params[0].kind != pEnterprise {
			t.Errorf("dataset %q: params[0] must be pEnterprise (customer_id from auth, $1); "+
				"a dataset whose first arg is client-supplied leaks across tenants", name)
			continue
		}
		// 2. pEnterprise must appear EXACTLY once — a second injected
		//    enterprise arg would desync the $-index of the rest.
		nEnt := 0
		for _, p := range ds.params {
			if p.kind == pEnterprise {
				nEnt++
			}
		}
		if nEnt != 1 {
			t.Errorf("dataset %q: expected exactly one pEnterprise param, got %d", name, nEnt)
		}
		// 3. The SQL must actually USE $1 — a dataset that takes the
		//    enterprise arg but never references it isn't scoped.
		if !strings.Contains(ds.sql, "$1") {
			t.Errorf("dataset %q: SQL never references $1 (the injected customer_id) — not tenant-scoped:\n%s",
				name, ds.sql)
		}
	}
}

// compileDataset must place the caller's customerID at $1 for every
// dataset, regardless of the request body — the client cannot move it.
func TestCompiledArgsPinCustomerIDAtDollarOne(t *testing.T) {
	const tenantA, tenantB = 3, 4
	for name, ds := range datasets {
		req := datasetReq{Dataset: name}
		if ds.windowed {
			// minimal valid window so compile doesn't reject on bounds
			req.Window = &dsWindow{From: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), To: time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)}
		}
		aSQL, aArgs, aErr := compileDataset(req, tenantA)
		bSQL, bArgs, bErr := compileDataset(req, tenantB)
		if aErr != nil || bErr != nil {
			// A dataset needing required client params can't be compiled
			// from an empty body — the structural test above already
			// guards those; skip the arg check here.
			continue
		}
		if len(aArgs) == 0 || aArgs[0] != tenantA || len(bArgs) == 0 || bArgs[0] != tenantB {
			t.Errorf("dataset %q: $1 must be the caller's customerID (got %v / %v for tenants %d/%d)",
				name, first(aArgs), first(bArgs), tenantA, tenantB)
		}
		// The compiled SQL must be identical across tenants — only the
		// bound arg differs. Divergent SQL would hint at customerID
		// leaking into the query text.
		if aSQL != bSQL {
			t.Errorf("dataset %q: compiled SQL differs between tenants — customerID must be a bound arg, not text", name)
		}
	}
}

func first(a []any) any {
	if len(a) == 0 {
		return nil
	}
	return a[0]
}
