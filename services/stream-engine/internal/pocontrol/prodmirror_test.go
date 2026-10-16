package pocontrol

import "testing"

func TestProdMirrorSkipsTenant(t *testing.T) {
	h := NewHandler(nil, nil)
	if h.SkipsEnterprise(5) {
		t.Fatal("no mirror configured: nothing skipped")
	}
	h.SetProdMirror([]int{5})
	if !h.SkipsEnterprise(5) || h.SkipsEnterprise(3) {
		t.Fatal("only the mirrored tenant is skipped")
	}
}
