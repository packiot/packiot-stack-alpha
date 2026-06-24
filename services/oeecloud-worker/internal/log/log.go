// Package log centralises slog setup. JSON output for prod-grade
// log aggregation (Promtail → Loki); level driven by config.
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
		slog.String("service", "oeecloud-worker"),
	)
	slog.SetDefault(logger)
	return logger
}
