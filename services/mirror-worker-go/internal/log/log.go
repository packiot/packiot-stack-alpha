// Package log centralises slog setup. JSON output for Promtail → Loki.
package log

import (
	"log/slog"
	"os"
	"strings"
)

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
	logger := slog.New(h).With(slog.String("service", "mirror-worker-go"))
	slog.SetDefault(logger)
	return logger
}
