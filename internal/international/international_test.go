package international

import (
	"context"
	"testing"

	"tcpquality/internal/probe"
)

func TestTaskCount(t *testing.T) {
	if TaskCount() != len(SiteTargets)+len(CDNTargets) {
		t.Errorf("TaskCount mismatch")
	}
	if TaskCount() != len(AllTargets()) {
		t.Error("AllTargets length mismatch")
	}
}

func TestTargetsHaveCategories(t *testing.T) {
	for _, tg := range SiteTargets {
		if tg.Category != "网站" || tg.Domain == "" {
			t.Errorf("bad site target %+v", tg)
		}
	}
	for _, tg := range CDNTargets {
		if tg.Category != "CDN" || tg.Domain == "" {
			t.Errorf("bad cdn target %+v", tg)
		}
	}
}

// fakeProber lets us exercise RunAll ordering without real network access.
type fakeProber struct{}

func (fakeProber) ProbeTarget(ctx context.Context, prov, isp, host, ip string, port int) probe.Result {
	return probe.Result{Status: probe.StatusOK, Rcvd: 1, Sent: 1, AvgRTT: 5}
}

func TestRunAllOrderingAndProgress(t *testing.T) {
	// Domains won't resolve deterministically here; verify indices/progress only.
	count := 0
	results := RunAll(context.Background(), fakeProber{}, 4, func() { count++ })
	if len(results) != TaskCount() {
		t.Fatalf("results len = %d, want %d", len(results), TaskCount())
	}
	if count != TaskCount() {
		t.Errorf("progress callbacks = %d, want %d", count, TaskCount())
	}
	for i, r := range results {
		if r.Index != i+1 {
			t.Errorf("result[%d].Index = %d", i, r.Index)
		}
	}
}
