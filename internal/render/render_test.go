package render

import (
	"strings"
	"testing"

	"tcpquality/internal/probe"
)

func TestDisplayWidth(t *testing.T) {
	cases := map[string]int{
		"":       0,
		"abc":    3,
		"北京":     4,
		"黑龙江":    6,
		"内蒙古":    6,
		"三网概览":   8,
		"教育网概览":  10,
		"✓":      1,
		"CN2GIA": 6,
	}
	for s, want := range cases {
		if got := DisplayWidth(s); got != want {
			t.Errorf("DisplayWidth(%q) = %d, want %d", s, got, want)
		}
	}
}

func TestJustify(t *testing.T) {
	if got := RJust("北京", 10); DisplayWidth(got) != 10 {
		t.Errorf("RJust width = %d", DisplayWidth(got))
	}
	if got := LJust("北京", 10); !strings.HasPrefix(got, "北京") || DisplayWidth(got) != 10 {
		t.Errorf("LJust = %q", got)
	}
	if got := Center("x", 5); DisplayWidth(got) != 5 {
		t.Errorf("Center width = %d", DisplayWidth(got))
	}
}

func TestBar(t *testing.T) {
	if got := Bar(0, 0); !strings.Contains(got, "0/1") {
		t.Errorf("Bar(0,0) = %q", got)
	}
	got := Bar(5, 10)
	if !strings.Contains(got, "5/10 (50%)") {
		t.Errorf("Bar(5,10) = %q", got)
	}
	if strings.Count(got, "#") != 20 {
		t.Errorf("Bar(5,10) fill count = %d, want 20", strings.Count(got, "#"))
	}
	// Overflow clamps.
	if !strings.Contains(Bar(15, 10), "10/10 (100%)") {
		t.Error("Bar overflow should clamp")
	}
}

func TestStatCounts(t *testing.T) {
	results := []probe.Result{
		{Status: probe.StatusOK, LossPct: 0},
		{Status: probe.StatusOK, LossPct: 10},
		{Status: probe.StatusOK, LossPct: 50},
		{Status: probe.StatusFail},
	}
	z, y, h := StatCounts(results)
	if z != 1 || y != 1 || h != 2 {
		t.Errorf("StatCounts = %d,%d,%d want 1,1,2", z, y, h)
	}
}

func TestFamilyResultsContent(t *testing.T) {
	results := []probe.Result{
		{Status: probe.StatusOK, Province: "北京", ISP: "电信", LossPct: 0, AvgRTT: 30},
		{Status: probe.StatusOK, Province: "北京", ISP: "联通", LossPct: 5, AvgRTT: 40},
		{Status: probe.StatusFail, Province: "北京", ISP: "移动", LossPct: 100},
	}
	label := func(prov, isp string) string {
		if isp == "电信" {
			return "CN2GIA"
		}
		return ""
	}
	out := FamilyResults("IPv4", results, label)
	for _, want := range []string{"IPv4", "统计摘要", "三网概览", "北京", "CN2GIA", "failed"} {
		if !strings.Contains(out, want) {
			t.Errorf("FamilyResults missing %q\n%s", want, out)
		}
	}
}

func TestLatencyText(t *testing.T) {
	if got := latencyText(123.7, 0); got != "124ms" {
		t.Errorf("latencyText = %q", got)
	}
	if got := latencyText(50, 100); got != "-1ms" {
		t.Errorf("latencyText loss100 = %q", got)
	}
}
