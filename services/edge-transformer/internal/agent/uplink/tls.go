// tls.go — Mode-B mTLS material loader for the agent's WAN uplink (ADR-0042 §6).
//
// The agentcfg descriptor carries the cert/key/CA as secret:// REFERENCES, never
// values (ADR-0004 Layer-2 secrets discipline). At the client edge those refs
// are resolved OUT OF BAND (AWS Secrets Manager → files, or a mounted secret)
// and the RESOLVED FILE PATHS are handed to the agent via env — so a leaked
// value can never live in the descriptor OR in git. This loader turns those
// three files into a *tls.Config the paho client presents on the ssl:// broker.
//
// The CN of the loaded client cert is what the cloud broker's ACL scopes
// isolation on (spBv1.0/<CN>/#). This function does not assert the CN — the
// server ACL does — but it is the single place the client identity enters the
// process, so it is the natural home for a future CN-vs-tenant guard.
package uplink

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"strings"
)

// TLSFiles are the resolved on-disk paths to the mTLS material (post secret
// resolution). Empty CertFile ⇒ no mTLS (Mode-A loopback).
type TLSFiles struct {
	CertFile string // client certificate (PEM) — asserts CN=<tenant>
	KeyFile  string // client private key (PEM)
	CAFile   string // CA bundle that signs the cloud broker's server cert (PEM)
}

// Empty reports whether no mTLS material was supplied (the Mode-A case).
func (f TLSFiles) Empty() bool {
	return strings.TrimSpace(f.CertFile) == "" &&
		strings.TrimSpace(f.KeyFile) == "" &&
		strings.TrimSpace(f.CAFile) == ""
}

// LoadTLSConfig builds a mutual-TLS client config from the three PEM files.
// It fails closed: a partially-specified set (cert without key, or a missing
// file) is an error, never a silent downgrade to plaintext — the same
// fail-closed discipline the agent applies to its ingest key. Returns
// (nil, nil) only when ALL three paths are empty (Mode A).
func LoadTLSConfig(f TLSFiles) (*tls.Config, error) {
	if f.Empty() {
		return nil, nil
	}
	if f.CertFile == "" || f.KeyFile == "" {
		return nil, fmt.Errorf("uplink mTLS: cert and key are both required (cert=%q key=%q)", f.CertFile, f.KeyFile)
	}

	cert, err := tls.LoadX509KeyPair(f.CertFile, f.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("uplink mTLS: load client keypair: %w", err)
	}

	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	// A CA bundle is how the agent trusts the cloud broker's SERVER cert. On a
	// private WAN with a self-managed CA this is REQUIRED (the system roots do
	// not sign it); omit only when the server cert chains to a public root.
	if f.CAFile != "" {
		pem, err := os.ReadFile(f.CAFile)
		if err != nil {
			return nil, fmt.Errorf("uplink mTLS: read CA %s: %w", f.CAFile, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("uplink mTLS: CA %s contains no valid PEM certificates", f.CAFile)
		}
		cfg.RootCAs = pool
	}

	return cfg, nil
}
