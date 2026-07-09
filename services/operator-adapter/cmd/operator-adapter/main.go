// operator-adapter — the operator twin of the ingest-shim.
//
// Incoplast runs a bespoke operator UI (mui_* + Hasura) that performs operator
// actions — chiefly downtime justification, plus PO start — WITHOUT going
// through our edge-api. Those actions therefore never land in staging
// `user_logs`, so the shadow-mirror can't replay them to the packiot_shadow
// (F3) flow, and the two flows can't be compared for enterprise 4.
//
// This adapter closes that gap. A tee node in Incoplast's Node-RED posts each
// operator action here over HTTPS; the adapter maps it to the matching
// edge-api call, which writes `user_logs` in F1 (packiot). shadow-mirror then
// replays that to F3 (packiot_shadow), making both flows comparable.
//
// It is intentionally thin: authenticate the tee node, scope-check the tenant,
// map Incoplast field names → edge-api DTO field names, inject the
// enterprise-4 api key, call edge-api, translate status codes. Where a required
// field can't be mapped it returns 422 rather than guessing — a wrong
// downtime/PO write is worse than a rejected one.
package main

import (
	"crypto/tls"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/packiot/packiot-stack-alpha/services/operator-adapter/internal/adapter"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With(slog.String("service", "operator-adapter"))

	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	operatorKey := os.Getenv("OPERATOR_API_KEY")
	if operatorKey == "" {
		logger.Error("OPERATOR_API_KEY is required")
		os.Exit(1)
	}
	edgeKey := os.Getenv("EDGE_API_KEY")
	if edgeKey == "" {
		logger.Error("EDGE_API_KEY is required (the enterprise-4 api_key edge-api authenticates)")
		os.Exit(1)
	}
	entID, err := strconv.Atoi(os.Getenv("INCOPLAST_ENTERPRISE_ID"))
	if err != nil {
		logger.Error("INCOPLAST_ENTERPRISE_ID must be an integer", slog.String("err", err.Error()))
		os.Exit(1)
	}

	cfg := adapter.Config{
		OperatorAPIKey: operatorKey,
		EnterpriseID:   entID,
		TopicPrefix:    os.Getenv("INCOPLAST_TOPIC_PREFIX"),
	}

	edgeURL := getenv("EDGE_API_URL", "http://edge-api:8080")
	edge := adapter.NewEdgeClient(edgeURL, edgeKey, 10*time.Second)

	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewGoCollector())
	metrics := adapter.NewMetrics(reg)

	srv := adapter.NewServer(cfg, edge, metrics, logger)
	mux := srv.Handler()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))

	port := getenv("PORT", "8443")
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	if certFile == "" || keyFile == "" {
		// Refuse to serve operator actions in cleartext — the tee node carries
		// the shared secret and (indirectly) operator PII.
		logger.Error("TLS_CERT_FILE and TLS_KEY_FILE are required — the adapter refuses to serve plaintext")
		os.Exit(1)
	}

	httpSrv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}

	logger.Info("operator-adapter listening (TLS)",
		slog.String("port", port),
		slog.Int("enterprise", entID),
		slog.String("edge_api_url", edgeURL))
	if err := httpSrv.ListenAndServeTLS(certFile, keyFile); err != nil {
		logger.Error("https server exited", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

// runHealthcheck is the container HEALTHCHECK entrypoint. It hits the local
// /healthz over TLS, skipping cert verification (loopback, self-signed OK).
func runHealthcheck() int {
	port := getenv("PORT", "8443")
	client := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // loopback only
		},
	}
	resp, err := client.Get("https://127.0.0.1:" + port + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		return 1
	}
	resp.Body.Close()
	return 0
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
