// Package erpconnector implements the driver-agnostic ERP / database
// connector (ADR-0019 C2 / task G1). It is the governed, secrets-safe home
// for the two-way sync a factory runs against its on-prem ERP: we *read*
// production orders / scrap / users OUT of the customer's database and
// *write* downtime / production records INTO it.
//
// It replaces the assessment's worst finding — an Incoplast Node-RED flow
// doing this through a database node plus shell scripts writing CSV files,
// with CLEARTEXT Oracle credentials embedded in the flow. Everything that
// was implicit and un-observable there is explicit and instrumented here.
//
// # What defines a connector
//
// Nothing inline. A connector exists only because a tenant's descriptor
// (client.yaml, parsed by internal/clientconfig) declares an integration:
//
//	capabilities:
//	  integrations:
//	    - type: database
//	      driver: oracle                       # oracle | mssql | postgres | sqlite
//	      dsn_ref: secret://incoplast/erp/dsn  # a REFERENCE, never a value
//	      reads:  [sql/incoplast/read_pos.sql] # versioned SQL template files
//	      writes: [sql/incoplast/write_downtime.sql]
//	      dedup_key: id_external               # declarative de-duplication
//
// The clientconfig.Integration struct is already parsed upstream; this
// package consumes it. Reads/Writes are references to *versioned SQL
// template files* on disk (loaded by TemplateStore), never SQL strings
// built at runtime — there is deliberately no code path that concatenates
// runtime data into a query (§Security, below).
//
// # Inert by construction
//
// Manager.New filters clientconfig.Integration entries to Type=="database".
// With none declared, the Manager holds zero connectors and Manager.Start
// is a no-op that returns immediately — the transformer's running behavior
// is unchanged. A connector is only ever opened when a descriptor asks for
// it, and New refuses to build one unless its DSN is a secret reference
// (defense-in-depth over the clientconfig loader's own check).
//
// # The four responsibilities
//
//  1. Resolve secrets by reference. dsn_ref is a `secret://…` pointer
//     fetched at runtime through a SecretResolver (EnvSecretResolver ships;
//     an AWS Secrets Manager impl slots in without touching this package).
//     A literal DSN is REFUSED at init — the cleartext-creds finding made
//     structurally impossible.
//  2. Reads. Run a read SQL template on cadence, scan rows into a typed
//     Row, and hand a ReadResult to the ReadSink seam. Wiring the sink INTO
//     the PO-control path (production orders → edge-api) is a later step;
//     this package lands the rows and a clear seam.
//  3. Writes. Run a write SQL template, mapping a platform Event's params
//     into the customer's ERP tables, parameterized (no injection surface).
//  4. Declarative dedup. A row already synced by its dedup_key value is not
//     re-sent — the SeenSet interface replaces Incoplast's ad-hoc
//     `differences`/rbe nodes.
//
// # Driver abstraction
//
// DBDriver + Conn abstract the backend so oracle/mssql/postgres/sqlite slot
// in behind one interface. The reference driver is SQLiteDriver (pure-Go
// modernc.org/sqlite — the same zero-cgo dependency the outbox uses, so
// tests need no external database). ORACLE IS THE PRODUCTION TARGET: a
// real deployment registers a godror-backed DBDriver; the interface is the
// only thing that changes, and none of the read/write/dedup logic moves.
//
// # Durability + observability
//
// Reads and writes emit metrics through the callback Metrics struct (same
// decoupling trick as internal/command — this package does not import
// prometheus). The metric surface is:
//
//	edge_transformer_erp_rows_read_total{dataset}
//	edge_transformer_erp_rows_written_total{dataset}
//	edge_transformer_erp_errors_total{dataset,op}
//	edge_transformer_erp_sync_lag_seconds{dataset}   (gauge)
//
// so an ERP outage is visible, not silent. Dedup durability is a documented
// choice: the shipped SeenSet is in-memory + bounded (memSeenSet), which
// covers same-process re-sends; a persisted SeenSet (a SQLite table, exactly
// the outbox pattern in internal/outbox) is the production upgrade for
// dedup that survives a restart, and slots in behind the SeenSet interface.
//
// # Security posture (this reaches into a customer's corporate network)
//
//   - Secrets by reference only, enforced at connector init.
//   - SQL lives in versioned, reviewed template files — never runtime
//     strings. TemplateStore refuses paths that escape its root.
//   - Least-privilege DB account on the customer side is an onboarding
//     requirement (documented; not enforced from here).
//
// # Wiring seam (follow-up, mirrors internal/outbox)
//
// Like the outbox when it first landed, this is the package scaffold and is
// NOT yet wired into cmd/edge-transformer/main.go. The wiring PR builds a
// Manager from the loaded clientconfig.Config, a SecretResolver, a
// TemplateStore rooted at the tenant SQL dir, and the default driver set,
// then runs Manager.Start in the boot errgroup. With today's descriptors
// (no database integration) that call is a no-op, which is why landing it
// changes no running behavior.
package erpconnector
