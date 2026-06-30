// Package log centralises slog setup. JSON output for prod-grade log
// aggregation (Promtail → Loki); level driven by config.
//
// Lifted verbatim from services/oeecloud-worker/internal/log per ADR-0009
// reuse rule — only the `service` constant changes.
//
// TODO(ADR-0009 Phase 2): consider a slog.Handler that attaches a `tenant`
// attribute to every log line emitted from a per-tenant consumer goroutine
// (context.WithValue + a custom Handler.Handle). Keeps grep-by-tenant
// trivial in Loki.
package log

import (
	"log/slog"
	"os"
	"strings"
)

// Setup returns a slog.Logger configured for the given level string.
// Falls back to info on unknown values.
func Setup(level string) *slog.Logger {
	var lvl slog.Level
	switch strings.ToLower(level) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	logger := slog.New(h).With(
		slog.String("service", "edge-transformer"),
	)
	slog.SetDefault(logger)
	return logger
}
