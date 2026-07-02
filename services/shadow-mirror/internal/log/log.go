// Package log wires structured JSON logging with the "service" attribute
// on every line, matching the oeecloud-worker + mirror-worker convention.
package log

import (
	"log/slog"
	"os"
)

func Setup(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
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
	return slog.New(h).With(slog.String("service", "shadow-mirror"))
}
