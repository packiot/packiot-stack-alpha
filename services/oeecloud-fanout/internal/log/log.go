// Package log provides a slog.Logger configured from a level string,
// matching the oeecloud-worker logging convention.
package log

import (
	"log/slog"
	"os"
	"strings"
)

// Setup returns a JSON slog.Logger at the given level ("debug"|"info"|
// "warn"|"error"; anything else → info).
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
	return slog.New(h)
}
