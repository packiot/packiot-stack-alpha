package uplink

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeSelfSigned emits a throwaway cert+key PEM pair under dir and returns the
// two paths. It is enough to exercise tls.LoadX509KeyPair + the CA pool parse.
func writeSelfSigned(t *testing.T, dir, cn string) (certPath, keyPath string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IsCA:         true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPath = filepath.Join(dir, cn+"-cert.pem")
	keyPath = filepath.Join(dir, cn+"-key.pem")

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	return certPath, keyPath
}

// Empty set ⇒ Mode-A: no TLS, no error.
func TestLoadTLSConfig_EmptyIsModeA(t *testing.T) {
	cfg, err := LoadTLSConfig(TLSFiles{})
	if err != nil {
		t.Fatalf("empty TLSFiles: unexpected error: %v", err)
	}
	if cfg != nil {
		t.Fatalf("empty TLSFiles: want nil *tls.Config (Mode-A), got %#v", cfg)
	}
}

// Full cert+key+CA ⇒ a usable mutual-TLS config with a root pool.
func TestLoadTLSConfig_FullMTLS(t *testing.T) {
	dir := t.TempDir()
	cert, key := writeSelfSigned(t, dir, "BISPHARMA")
	ca, _ := writeSelfSigned(t, dir, "packiot-ca")

	cfg, err := LoadTLSConfig(TLSFiles{CertFile: cert, KeyFile: key, CAFile: ca})
	if err != nil {
		t.Fatalf("full mTLS: unexpected error: %v", err)
	}
	if cfg == nil {
		t.Fatal("full mTLS: want a *tls.Config, got nil")
	}
	if len(cfg.Certificates) != 1 {
		t.Fatalf("full mTLS: want 1 client certificate, got %d", len(cfg.Certificates))
	}
	if cfg.RootCAs == nil {
		t.Fatal("full mTLS: want a RootCAs pool from the CA file, got nil")
	}
	if cfg.MinVersion != tls.VersionTLS12 {
		t.Fatalf("full mTLS: want MinVersion TLS1.2, got %x", cfg.MinVersion)
	}
}

// Fail-closed: cert without key is an error, never a silent plaintext downgrade.
func TestLoadTLSConfig_PartialFailsClosed(t *testing.T) {
	dir := t.TempDir()
	cert, _ := writeSelfSigned(t, dir, "BISPHARMA")
	if _, err := LoadTLSConfig(TLSFiles{CertFile: cert}); err == nil {
		t.Fatal("cert without key: want error (fail-closed), got nil")
	}
}

// A missing file is an error, not a silent skip.
func TestLoadTLSConfig_MissingFile(t *testing.T) {
	if _, err := LoadTLSConfig(TLSFiles{CertFile: "/nope/cert.pem", KeyFile: "/nope/key.pem"}); err == nil {
		t.Fatal("missing files: want error, got nil")
	}
}
