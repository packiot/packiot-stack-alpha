package caggsplit

import (
	"strings"
	"testing"
)

const sample = `
	WITH a AS (
	    SELECT 1 AS k
	), b AS MATERIALIZED (
	    -- prose that says UPDATE must not count
	    SELECT k, 2 AS v FROM a
	)
	UPDATE t SET v = b.v
	  FROM b
	 WHERE t.k = b.k`

func TestSplit(t *testing.T) {
	got, err := Spec{Temp: "b_snap", Tail: "SELECT * FROM b", Feeds: []string{"b"}}.Split(sample)
	if err != nil {
		t.Fatal(err)
	}
	st := Statements(got)
	if len(st) != 3 {
		t.Fatalf("want 3 statements, got %d:\n%s", len(st), got)
	}
	if strings.TrimSpace(st[0]) != "DROP TABLE IF EXISTS pg_temp.b_snap" {
		t.Errorf("drop: %q", st[0])
	}
	if !strings.HasPrefix(strings.TrimSpace(st[1]), "CREATE TEMP TABLE b_snap ON COMMIT DROP AS\n\tWITH a AS (") ||
		!strings.HasSuffix(st[1], "SELECT * FROM b") || strings.Contains(st[1], "UPDATE t") {
		t.Errorf("read:\n%s", st[1])
	}
	if !strings.HasPrefix(strings.TrimSpace(st[2]), "WITH b AS (SELECT * FROM b_snap)\n\tUPDATE t SET v = b.v") {
		t.Errorf("apply:\n%s", st[2])
	}
	// the DML text is carried verbatim
	if !strings.HasSuffix(got, "UPDATE t SET v = b.v\n\t  FROM b\n\t WHERE t.k = b.k") {
		t.Errorf("DML not verbatim:\n%s", got)
	}
}

func TestSplitRejectsBadShapes(t *testing.T) {
	for name, c := range map[string]struct {
		spec Spec
		stmt string
	}{
		"no WITH":       {Spec{Temp: "x", Tail: "SELECT 1", Feeds: []string{"a"}}, "UPDATE t SET v = 1"},
		"two DML":       {Spec{Temp: "x", Tail: "SELECT 1", Feeds: []string{"a"}}, "WITH a AS (SELECT 1)\nUPDATE t SET v=1;\nUPDATE t SET v=2"},
		"unknown feed":  {Spec{Temp: "x", Tail: "SELECT * FROM a", Feeds: []string{"zz"}}, sample},
		"bad temp":      {Spec{Temp: "x; DROP", Tail: "SELECT 1", Feeds: []string{"a"}}, sample},
		"missing tail":  {Spec{Temp: "x", Feeds: []string{"a"}}, sample},
		"missing feeds": {Spec{Temp: "x", Tail: "SELECT 1"}, sample},
	} {
		if _, err := c.spec.Split(c.stmt); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}
