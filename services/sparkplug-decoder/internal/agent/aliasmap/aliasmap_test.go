package aliasmap

import "testing"

func TestAlias_StabilityAndIsNew(t *testing.T) {
	tb := New()

	a1, new1 := tb.Alias("CPACK/L5/Speed")
	if a1 != 1 || !new1 {
		t.Fatalf("first alloc: got (%d, %v), want (1, true)", a1, new1)
	}
	a2, new2 := tb.Alias("CPACK/L5/Count")
	if a2 != 2 || !new2 {
		t.Fatalf("second alloc: got (%d, %v), want (2, true)", a2, new2)
	}

	// Stability: same name ⇒ same alias, isNew=false.
	again, isNew := tb.Alias("CPACK/L5/Speed")
	if again != 1 || isNew {
		t.Fatalf("re-alloc same name: got (%d, %v), want (1, false)", again, isNew)
	}

	// Monotonic: a fresh name gets the next number.
	a3, new3 := tb.Alias("CPACK/L5/State")
	if a3 != 3 || !new3 {
		t.Fatalf("third alloc: got (%d, %v), want (3, true)", a3, new3)
	}
}

func TestHas_DoesNotAllocate(t *testing.T) {
	tb := New()
	if tb.Has("nope") {
		t.Fatal("Has on unseen name should be false")
	}
	if tb.Len() != 0 {
		t.Fatalf("Has must not allocate; Len=%d, want 0", tb.Len())
	}
	tb.Alias("seen")
	if !tb.Has("seen") {
		t.Fatal("Has after Alias should be true")
	}
}
