package rawtag

import (
	"strings"
	"testing"
)

func TestDecodeLink(t *testing.T) {
	l, ok := DecodeLink([]byte(`{"group":"G","endpoint":"L01","scan_ts":1700000000000,"tags":[],"link":{"ok":false,"err":"connection timed out","ms":5003}}`))
	if !ok || l.Endpoint != "L01" || l.OK || l.Err != "connection timed out" || l.LatencyMs != 5003 || l.ScanTS != 1700000000000 {
		t.Fatalf("got %+v ok=%v", l, ok)
	}
	if _, ok := DecodeLink([]byte(`{"endpoint":"L01","scan_ts":1,"tags":[{"metric":"/a","value":1}]}`)); ok {
		t.Fatal("no link field must decode as absent")
	}
	if _, ok := DecodeLink([]byte(`{"scan_ts":1,"link":{"ok":true}}`)); ok {
		t.Fatal("link without endpoint must be ignored")
	}
	long := strings.Repeat("x", 1000)
	l, _ = DecodeLink([]byte(`{"endpoint":"E","scan_ts":5,"link":{"ok":false,"err":"` + long + `"}}`))
	if len(l.Err) != maxLinkErr {
		t.Fatalf("err not capped: %d", len(l.Err))
	}
	// The tags decoder is unaffected by the extra field and accepts an empty tag list.
	tags, err := Decode([]byte(`{"endpoint":"L01","scan_ts":1,"tags":[],"link":{"ok":false}}`))
	if err != nil || len(tags) != 0 {
		t.Fatalf("Decode: %v %v", tags, err)
	}
}
