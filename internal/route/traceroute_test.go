package route

import (
	"strings"
	"testing"
)

func TestPublicHopIPs(t *testing.T) {
	tr := &TraceResult{Hops: []Hop{
		{TTL: 1, IP: "192.168.1.1", Responded: true},
		{TTL: 2, IP: "", Responded: false},
		{TTL: 3, IP: "202.97.1.1", Responded: true},
		{TTL: 4, IP: "202.97.1.1", Responded: true}, // dup
		{TTL: 5, IP: "2408::1", Responded: true},
	}}
	got := tr.PublicHopIPs()
	want := []string{"202.97.1.1", "2408::1"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("PublicHopIPs = %v, want %v", got, want)
	}
}

func TestNeeds10099HiddenRetry(t *testing.T) {
	// 10099 entry, then two hidden hops, then 163, no unicom domestic -> retry.
	hops := []Hop{
		{IP: "103.214.1.1", Responded: true},
		{IP: "", Responded: false},
		{IP: "", Responded: false},
		{IP: "202.97.1.1", Responded: true},
	}
	if !Needs10099HiddenRetry(hops) {
		t.Error("expected retry needed")
	}

	// Same but with a unicom domestic hop -> no retry.
	hops2 := []Hop{
		{IP: "103.214.1.1", Responded: true},
		{IP: "", Responded: false},
		{IP: "", Responded: false},
		{IP: "219.158.1.1", Responded: true},
		{IP: "202.97.1.1", Responded: true},
	}
	if Needs10099HiddenRetry(hops2) {
		t.Error("unicom domestic present should suppress retry")
	}

	// Only one hidden hop -> no retry.
	hops3 := []Hop{
		{IP: "103.214.1.1", Responded: true},
		{IP: "", Responded: false},
		{IP: "202.97.1.1", Responded: true},
	}
	if Needs10099HiddenRetry(hops3) {
		t.Error("single hidden hop should not trigger retry")
	}
}

func TestLabelForTrace(t *testing.T) {
	tr := &TraceResult{
		DestIP: "1.2.3.4",
		Hops:   []Hop{{IP: "202.97.1.1", Responded: true}},
	}
	if got := LabelForTrace(tr, nil, "电信"); got != "163" {
		t.Errorf("LabelForTrace = %q, want 163", got)
	}
	if got := LabelForTrace(nil, nil, "电信"); got != "Hidden" {
		t.Errorf("nil trace = %q, want Hidden", got)
	}
}

func TestCollectHopIPs(t *testing.T) {
	traces := []*TraceResult{
		{Hops: []Hop{{IP: "202.97.1.1", Responded: true}}},
		{Hops: []Hop{{IP: "202.97.1.1", Responded: true}, {IP: "219.158.1.1", Responded: true}}},
		nil,
	}
	got := CollectHopIPs(traces)
	if len(got) != 2 {
		t.Errorf("CollectHopIPs = %v, want 2 unique", got)
	}
}

func TestParseCymruLine(t *testing.T) {
	asn, ip, ok := parseCymruLine("4134    | 202.97.1.1       | 202.97.0.0/16 | CN | apnic | 2000-01-01 | CHINANET")
	if !ok || asn != "4134" || ip != "202.97.1.1" {
		t.Errorf("parseCymruLine = %q,%q,%v", asn, ip, ok)
	}
	if _, _, ok := parseCymruLine("NA | 1.2.3.4 |"); ok {
		t.Error("non-numeric ASN should be rejected")
	}
}
