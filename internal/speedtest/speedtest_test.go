package speedtest

import (
	"strings"
	"testing"

	"tcpquality/internal/config"
	"tcpquality/internal/nodes"
)

func TestParseRateMbps(t *testing.T) {
	cases := map[string]string{
		"Average download rate: 12.5MB/s":          "100.0",
		"Average upload rate: 1.0GB/s":             "8000.0",
		"Average download rate: 500KB/s":           "4.0",
		"some noise\nAverage network rate: 250B/s": "0.0",
		"no rate here":                             "failed",
		// tosutil has shipped variations in case and spacing.
		"average Download Rate:  12.5 MB/s ": "100.0",
		// Units are compared case-insensitively, so "Mb/s" reads as MB/s.
		"AVERAGE RATE: 8Mb/s": "64.0",
	}
	for in, want := range cases {
		if got := parseRateMbps(in); got != want {
			t.Errorf("parseRateMbps(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseCostMs(t *testing.T) {
	out := "Build connection cost: 23 ms\nTls handshake cost: 47 ms\n"
	if got := parseCostMs(out, "Build connection cost"); got != "23" {
		t.Errorf("connect cost = %q, want 23", got)
	}
	if got := parseCostMs(out, "Tls handshake cost"); got != "47" {
		t.Errorf("tls cost = %q, want 47", got)
	}
	if got := parseCostMs(out, "Nothing"); got != "-" {
		t.Errorf("missing label = %q, want -", got)
	}
}

func TestCalcMbps(t *testing.T) {
	if got := calcMbps(125000000, 10); got != "100.0" {
		t.Errorf("calcMbps = %q, want 100.0", got)
	}
	if got := calcMbps(100, 0); got != "failed" {
		t.Errorf("calcMbps zero-duration = %q", got)
	}
	// Below the reportable floor counts as a failure, not a very slow link.
	if got := calcMbps(1000, 1000); got != "failed" {
		t.Errorf("calcMbps sub-floor = %q, want failed", got)
	}
}

func TestGroups(t *testing.T) {
	if got := Groups(nil); len(got) != 3 {
		t.Fatalf("default groups = %d, want 3", len(got))
	}
	got := Groups([]string{"上海"})
	if len(got) != 1 || got[0].Region != "cn-shanghai" {
		t.Errorf("province-filtered groups = %+v", got)
	}
	// A filter with no speedtest region falls back to all groups.
	if got := Groups([]string{"新疆"}); len(got) != 3 {
		t.Errorf("unsupported province should keep all groups, got %+v", got)
	}
}

func TestFailedResults(t *testing.T) {
	groups := Groups(nil)
	r := FailedResults(groups, true)
	if len(r.Rows) != len(groups)+1 {
		t.Fatalf("rows = %d, want %d", len(r.Rows), len(groups)+1)
	}
	if r.Rows[0].Label != "北京" {
		t.Errorf("first label = %q, want 北京", r.Rows[0].Label)
	}
	last := r.Rows[len(r.Rows)-1]
	if !last.Apple || last.Label != AppleLabel {
		t.Errorf("last row should be AppleCDN, got %+v", last)
	}
	for _, row := range r.Rows {
		for _, c := range row.Entries {
			if !c.Failed() {
				t.Error("expected failed result")
			}
		}
	}
	if r.RankEligible {
		t.Error("failed results must not be rank eligible")
	}
}

func TestSpeedColor(t *testing.T) {
	if speedColor("failed", "北京") != config.Red {
		t.Error("failed should be red")
	}
	if speedColor("-", "北京") != config.Dim {
		t.Error("skipped should be dim")
	}
	// Region groups are unthrottled, so they use the absolute thresholds.
	if speedColor("200", "北京") != config.Green {
		t.Error("200 unthrottled should be green")
	}
	if speedColor("10", "北京") != config.Red {
		t.Error("10 unthrottled should be red")
	}
	if speedColor("100", "上海") != config.Yellow {
		t.Error("100 unthrottled should be yellow")
	}
	if speedColor("9", "10Mbps") != config.Green { // 9 >= 10*0.8
		t.Error("9 of 10Mbps should be green")
	}
	if speedColor("7", "10Mbps") != config.Yellow { // 7 >= 6
		t.Error("7 of 10Mbps should be yellow")
	}
	if speedColor("3", "10Mbps") != config.Red {
		t.Error("3 of 10Mbps should be red")
	}
}

func TestLatencyTextAndColor(t *testing.T) {
	// The displayed latency is half the handshake cost.
	if got := latencyText("100"); got != "50ms" {
		t.Errorf("latencyText(100) = %q, want 50ms", got)
	}
	if got := latencyText("-"); got != "-" {
		t.Errorf("latencyText(-) = %q, want -", got)
	}
	if latencyColor("600") != config.Red {
		t.Error("300ms should be red")
	}
	if latencyColor("400") != config.Yellow {
		t.Error("200ms should be yellow")
	}
	if latencyColor("100") != config.Green {
		t.Error("50ms should be green")
	}
	if latencyColor("-") != config.Dim {
		t.Error("missing latency should be dim")
	}
}

func TestRetransColor(t *testing.T) {
	if retransColor("failed") != config.Red || retransColor("1500") != config.Red {
		t.Error("retrans red cases")
	}
	if retransColor("150") != config.Yellow {
		t.Error("retrans yellow")
	}
	if retransColor("50") != config.Green {
		t.Error("retrans green")
	}
}

func TestApplyNodesAndPickCandidate(t *testing.T) {
	o := DefaultOptions()
	o.ApplyNodes([]nodes.SpeedtestNode{
		{ISP: "电信", IP: "1.1.1.1", City: "上海", Region: "cn-shanghai"},
		{ISP: "电信", IP: "2.2.2.2", City: "北京", Region: "cn-beijing"},
	})
	c, ok := o.PickCandidate("电信", "cn-shanghai")
	if !ok || c.IP != "1.1.1.1" || c.City != "上海" {
		t.Errorf("shanghai telecom candidate = %+v ok=%v", c, ok)
	}
	if c, ok := o.PickCandidate("电信", "cn-guangzhou"); ok {
		t.Errorf("guangzhou telecom should be missing, got %+v", c)
	}
	// Carriers absent from the feed keep their built-in fallback.
	if c, ok := o.PickCandidate("联通", "cn-beijing"); !ok || c.IP != "221.194.175.109" {
		t.Errorf("unicom fallback = %+v ok=%v", c, ok)
	}
}

func TestRenderAndCSV(t *testing.T) {
	groups := Groups(nil)
	r := FailedResults(groups, true)
	r.Rows[0].Entries[0] = CarrierResult{
		Upload: "120.5", Retrans: "3", Download: "88.0",
		ServerID: "1.1.1.1", City: "北京",
		UploadConnectMs: "20", UploadTLSMs: "60",
		DownloadConnectMs: "21", DownloadTLSMs: "64",
	}
	out := r.Render()
	for _, want := range []string{"单线程测速", "北京", AppleLabel, "30ms", "代理速度"} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q:\n%s", want, out)
		}
	}

	var rows [][]string
	r.CSVRows(func(fields ...string) { rows = append(rows, fields) })
	// three carriers per group, two AppleCDN families, plus the TCP config row.
	want := len(groups)*len(Carriers) + 2 + 1
	if len(rows) != want {
		t.Fatalf("csv rows = %d, want %d", len(rows), want)
	}
	first := rows[0]
	if len(first) != 16 {
		t.Fatalf("csv row width = %d, want 16", len(first))
	}
	if first[0] != csvNetwork || first[1] != "北京" || first[2] != "电信" || first[6] != "OK" {
		t.Errorf("unexpected csv row: %v", first)
	}
	if first[12] != "20" || first[13] != "60" || first[14] != "21" || first[15] != "64" {
		t.Errorf("timing columns wrong: %v", first[12:])
	}
	if last := rows[len(rows)-1]; last[0] != "三网单线程配置" {
		t.Errorf("last row should be TCP config, got %v", last)
	}
}

func TestTCPWindowHelpers(t *testing.T) {
	if got := tcpWindowBytes("4096 131072 6291456"); got != "6291456" {
		t.Errorf("tcpWindowBytes = %q", got)
	}
	if got := tcpWindowBytes("bad"); got != "-" {
		t.Errorf("tcpWindowBytes(bad) = %q, want -", got)
	}
	if got := minWindowBytes("6291456", endpointWindowBytes); got != "6291456" {
		t.Errorf("minWindowBytes local-smaller = %q", got)
	}
	if got := minWindowBytes("99999999", endpointWindowBytes); got != "16777216" {
		t.Errorf("minWindowBytes endpoint-smaller = %q", got)
	}
}
