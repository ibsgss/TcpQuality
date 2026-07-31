package config

import (
	"errors"
	"testing"
)

func TestProvinceFromCode(t *testing.T) {
	cases := []struct {
		in   string
		want string
		ok   bool
	}{
		{"bj", "北京", true},
		{"-bj", "北京", true},
		{"-GD", "广东", true},
		{"sx", "山西", true},
		{"sn", "陕西", true},
		{"上海", "上海", true},
		{"内蒙古", "内蒙古", true},
		{"zz", "", false},
		{"", "", false},
	}
	for _, tc := range cases {
		got, ok := ProvinceFromCode(tc.in)
		if got != tc.want || ok != tc.ok {
			t.Errorf("ProvinceFromCode(%q) = (%q,%v), want (%q,%v)", tc.in, got, ok, tc.want, tc.ok)
		}
	}
}

func TestProvinceFilter(t *testing.T) {
	c := New()
	if !c.ProvinceSelected("北京") {
		t.Fatal("empty filter should select everything")
	}
	if got := c.ProvinceFilterText(); got != "全国" {
		t.Fatalf("empty filter text = %q, want 全国", got)
	}
	if !c.AddProvinceFilter("-bj") || !c.AddProvinceFilter("上海") {
		t.Fatal("failed to add valid province filters")
	}
	// duplicate should not double-add
	c.AddProvinceFilter("北京")
	if !c.ProvinceSelected("北京") || c.ProvinceSelected("广东") {
		t.Fatal("filter membership incorrect")
	}
	if got := c.ProvinceFilterText(); got != "北京、上海" {
		t.Fatalf("filter text = %q, want 北京、上海", got)
	}
}

func TestParseArgsBasic(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"-c", "100", "-p", "8", "-v4", "-bj"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.Packets != 100 || !c.CountExplicit {
		t.Errorf("Packets=%d CountExplicit=%v", c.Packets, c.CountExplicit)
	}
	if c.Parallel != 8 {
		t.Errorf("Parallel=%d", c.Parallel)
	}
	if !c.OnlyIPv4 || !c.ProvinceSelected("北京") || c.ProvinceSelected("广东") {
		t.Errorf("flags not applied: %+v", c)
	}
}

func TestParseArgsAll(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--all"}); err != nil {
		t.Fatal(err)
	}
	if !c.TestAll || !c.SpeedtestEnabled || !c.InternationalEnabled {
		t.Errorf("--all did not enable expected features: %+v", c)
	}
	if c.NodeScope() != "all" {
		t.Errorf("scope=%q want all", c.NodeScope())
	}
}

func TestParseArgsOnlyLargeNormalization(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--only-large", "--speedtest", "--all"}); err != nil {
		t.Fatal(err)
	}
	if !c.OnlyLarge || c.OnlyIPv6 || c.TestAll || c.SpeedtestEnabled || c.InternationalEnabled {
		t.Errorf("--only-large normalization wrong: %+v", c)
	}
	if !c.OnlyIPv4 {
		t.Error("--only-large should force OnlyIPv4")
	}
}

func TestParseArgsIntlOnly(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--intl"}); err != nil {
		t.Fatal(err)
	}
	if !c.InternationalOnly {
		t.Error("bare --intl should set InternationalOnly")
	}

	c2 := New()
	if err := c2.ParseArgs([]string{"--intl", "-v4"}); err != nil {
		t.Fatal(err)
	}
	if c2.InternationalOnly {
		t.Error("--intl with -v4 must not set InternationalOnly")
	}
	if !c2.InternationalEnabled {
		t.Error("--intl should still enable international")
	}
}

func TestParseArgsErrors(t *testing.T) {
	cases := [][]string{
		{"-c", "0"},
		{"-c", "9999"},
		{"-c"},
		{"-p", "50"},
		{"-s", "70000"},
		{"--route-protocol", "icmp"},
		{"--province", "zz"},
		{"--bogus"},
	}
	for _, args := range cases {
		c := New()
		if err := c.ParseArgs(args); err == nil {
			t.Errorf("ParseArgs(%v) expected error, got nil", args)
		}
	}
}

func TestParseArgsNoRankUpload(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--no-rank-upload"}); err != nil {
		t.Fatal(err)
	}
	if c.UploadReport || !c.ReportUploadForcedOff {
		t.Errorf("--no-rank-upload did not disable uploading: %+v", c)
	}

	// --intl must not resurrect uploading once it has been forced off.
	c2 := New()
	if err := c2.ParseArgs([]string{"--no-rank-upload", "--intl", "-v4"}); err != nil {
		t.Fatal(err)
	}
	if c2.UploadReport {
		t.Error("--intl should not re-enable uploading after --no-rank-upload")
	}
}

func TestAutoParallel(t *testing.T) {
	cases := map[int]int{
		0:     11, // unknown memory falls back to 512 MiB
		48:    1,
		512:   11,
		1024:  22,
		4096:  86,
		8192:  MaxAutoParallel,
		65536: MaxAutoParallel,
	}
	for mem, want := range cases {
		if got := AutoParallel(mem); got != want {
			t.Errorf("AutoParallel(%d) = %d, want %d", mem, got, want)
		}
	}
}

func TestApplyAutoParallelRespectsExplicitFlag(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"-p", "8"}); err != nil {
		t.Fatal(err)
	}
	c.ApplyAutoParallel()
	if c.Parallel != 8 {
		t.Errorf("explicit -p was overridden: %d", c.Parallel)
	}

	c2 := New()
	if err := c2.ParseArgs(nil); err != nil {
		t.Fatal(err)
	}
	c2.ApplyAutoParallel()
	if c2.ParallelExplicit {
		t.Error("ParallelExplicit should stay false without -p")
	}
	if c2.Parallel < 1 || c2.Parallel > MaxAutoParallel {
		t.Errorf("auto parallel out of range: %d", c2.Parallel)
	}
}

func TestIncludeDefaultRouteScope(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--cernet"}); err != nil {
		t.Fatal(err)
	}
	if got := c.NodeScope(); got != "cernet" {
		t.Errorf("scope = %q, want cernet", got)
	}
	c.IncludeDefaultRoute = true
	if got := c.NodeScope(); got != "all" {
		t.Errorf("scope with default route = %q, want all", got)
	}
}

func TestReportAPIBase(t *testing.T) {
	c := New()
	if got := c.ReportAPIBase(); got != "https://tcpquality.ibsgss.uk" {
		t.Errorf("ReportAPIBase = %q", got)
	}
	if c.RankSessionAPI != "https://tcpquality.ibsgss.uk/rank/session" {
		t.Errorf("RankSessionAPI = %q", c.RankSessionAPI)
	}
}

func TestParseArgsHelp(t *testing.T) {
	c := New()
	if err := c.ParseArgs([]string{"--help"}); !errors.Is(err, ErrHelp) {
		t.Errorf("--help err = %v, want ErrHelp", err)
	}
}
