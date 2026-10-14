package main

import (
	"os"
	"testing"
)

// TestDBCredsFromEnvRequiresUserAndPassword pins the no-admin-fallback rule: enabled mode needs an
// explicit DB_USER (the old default was "postgres") as well as a password.
func TestDBCredsFromEnvRequiresUserAndPassword(t *testing.T) {
	unset := func(k string) {
		t.Setenv(k, "")
		if err := os.Unsetenv(k); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("no user", func(t *testing.T) {
		unset("DB_USER")
		t.Setenv("DB_PASSWORD", "x")
		if _, err := dbCredsFromEnv(); err == nil {
			t.Fatal("want an error without DB_USER")
		}
	})
	t.Run("no password", func(t *testing.T) {
		t.Setenv("DB_USER", "some_role")
		unset("DB_PASSWORD")
		if _, err := dbCredsFromEnv(); err == nil {
			t.Fatal("want an error without DB_PASSWORD")
		}
	})
	t.Run("both", func(t *testing.T) {
		t.Setenv("DB_USER", "some_role")
		t.Setenv("DB_PASSWORD", "x")
		c, err := dbCredsFromEnv()
		if err != nil || c.User != "some_role" {
			t.Fatalf("got %+v, %v", c, err)
		}
	})
}
