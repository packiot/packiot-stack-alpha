package erpconnector

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// SecretScheme is the required prefix for a DSN reference. The descriptor
// carries a POINTER into the secret store, never a value. This mirrors
// clientconfig.secretScheme (the loader enforces the same rule at parse
// time); we re-declare it here so the connector's own enforcement does not
// depend on the loader having run — defense in depth.
const SecretScheme = "secret://"

// SecretResolver turns a `secret://…` reference into the actual secret
// value (here, a database DSN). It is the seam that keeps AWS Secrets
// Manager out of this package: EnvSecretResolver ships for dev/test, and a
// production SecretsManagerResolver — wrapping the exact client already in
// internal/secrets — implements the same one-method interface and drops in
// with no change to any connector code.
type SecretResolver interface {
	// Resolve fetches the value behind ref. Implementations MUST reject a
	// ref that is not a SecretScheme reference (use RequireSecretRef) so the
	// no-cleartext guarantee holds no matter which resolver is wired.
	Resolve(ctx context.Context, ref string) (string, error)
}

// RequireSecretRef enforces "must be a secret:// reference, never a value".
// It is the single chokepoint behind the Incoplast cleartext-Oracle-creds
// finding: Manager.New calls it on every declared DSN before a connector is
// built, and every SecretResolver calls it before resolving. A literal DSN
// (host=…;user=…;password=…) fails here, loudly, at init — it can never
// reach a live connection.
func RequireSecretRef(field, val string) error {
	if strings.HasPrefix(val, SecretScheme) {
		return nil
	}
	if strings.TrimSpace(val) == "" {
		return fmt.Errorf("erpconnector: %s is empty — a %s reference is required", field, SecretScheme)
	}
	return fmt.Errorf(
		"erpconnector: %s=%q must be a %s reference, not a literal value (secrets by reference only)",
		field, redact(val), SecretScheme)
}

// redact avoids echoing a leaked credential into logs/errors while still
// giving an operator enough to identify which field is wrong.
func redact(val string) string {
	if len(val) <= 4 {
		return "****"
	}
	return val[:2] + "…****"
}

// EnvSecretResolver resolves a reference from an environment variable — the
// dev/CI escape hatch, matching the CREDS_SOURCE=env pattern in
// internal/secrets. The env var name is derived deterministically from the
// reference so a descriptor and its deployment agree without a lookup table:
//
//	secret://incoplast/erp/dsn   →   <Prefix>INCOPLAST_ERP_DSN
//
// with Prefix defaulting to "ERP_SECRET_". SECURITY: like CREDS_SOURCE=env,
// this is for dev/test only — production wires a SecretsManagerResolver.
type EnvSecretResolver struct {
	// Prefix is prepended to the derived name. Empty → "ERP_SECRET_".
	Prefix string
}

func (r EnvSecretResolver) Resolve(_ context.Context, ref string) (string, error) {
	if err := RequireSecretRef("dsn_ref", ref); err != nil {
		return "", err
	}
	name := r.envVarName(ref)
	val := os.Getenv(name)
	if val == "" {
		return "", fmt.Errorf("erpconnector: env secret %q (from %s) is unset", name, ref)
	}
	return val, nil
}

func (r EnvSecretResolver) envVarName(ref string) string {
	prefix := r.Prefix
	if prefix == "" {
		prefix = "ERP_SECRET_"
	}
	path := strings.TrimPrefix(ref, SecretScheme)
	var b strings.Builder
	b.WriteString(prefix)
	prevUnderscore := false
	for _, c := range strings.ToUpper(path) {
		switch {
		case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			b.WriteRune(c)
			prevUnderscore = false
		default:
			// collapse any run of separators (/ . - :) into a single '_'
			if !prevUnderscore {
				b.WriteByte('_')
				prevUnderscore = true
			}
		}
	}
	return b.String()
}

// StaticResolver is a map-backed SecretResolver for tests and fixtures:
// reference → value. It still enforces the secret:// rule so tests exercise
// the real enforcement path rather than bypassing it.
type StaticResolver map[string]string

func (m StaticResolver) Resolve(_ context.Context, ref string) (string, error) {
	if err := RequireSecretRef("dsn_ref", ref); err != nil {
		return "", err
	}
	val, ok := m[ref]
	if !ok {
		return "", fmt.Errorf("erpconnector: no static secret registered for %q", ref)
	}
	return val, nil
}
