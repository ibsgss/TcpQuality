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
	}
	for in, want := range cases {
		if got := parseRateMbps(in); got != want {
			t.Errorf("parseRateMbps(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCalcMbps(t *testing.T) {
	if got := calcMbps(125000000, 10); got != "100.0" {
		t.Errorf("calcMbps = %q, want 100.0", got)
	}
	if got := calcMbps(100, 0); got != "failed" {
		t.Errorf("calcMbps zero-duration = %q", got)
	}
}

func TestFailedResults(t *testing.T) {
	r := FailedResults()
	if len(r.Rows) != len(Rates) {
		t.Fatalf("rows = %d, want %d", len(r.Rows), len(Rates))
	}
	if r.Rows[len(r.Rows)-1].Label != "不限" {
		t.Errorf("last label = %q, want 不限", r.Rows[len(r.Rows)-1].Label)
	}
	for _, row := range r.Rows {
		for _, c := range row.Carriers {
			if !c.Failed() {
				t.Error("expected failed carrier result")
			}
		}
	}
}

func TestSpeedColor(t *testing.T) {
	if speedColor("failed", "不限") != config.Red {
		t.Error("failed should be red")
	}
	if speedColor("200", "不限") != config.Green {
		t.Error("200 unlimited should be green")
	}
	if speedColor("10", "不限") != config.Red {
		t.Error("10 unlimited should be red")
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

func TestApplyNodes(t *testing.T) {
	o := DefaultOptions()
	sel := o.applyNodes([]nodes.SpeedtestNode{
		{ISP: "电信", IP: "1.1.1.1", City: "上海"},
	})
	if o.CTIP != "1.1.1.1" || sel[0].ID != "1.1.1.1" || sel[0].City != "上海" {
		t.Errorf("applyNodes telecom override failed: %+v %+v", o, sel)
	}
	// untouched carriers keep fallback
	if sel[1].City != "北京" {
		t.Errorf("unicom should keep fallback city, got %q", sel[1].City)
	}
}

func TestRenderAndCSV(t *testing.T) {
	r := FailedResults()
	r.Selected[0] = Selected{ID: "1.1.1.1", City: "北京"}
	out := r.Render()
	if !strings.Contains(out, "国内三网单线程测速") || !strings.Contains(out, "不限速") {
		t.Errorf("render missing expected content:\n%s", out)
	}
	var rows [][]string
	r.CSVRows(func(fields ...string) { rows = append(rows, fields) })
	if len(rows) != len(Rates)*len(Carriers) {
		t.Errorf("csv rows = %d, want %d", len(rows), len(Rates)*len(Carriers))
	}
}
