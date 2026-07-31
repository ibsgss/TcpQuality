package app

import (
	"strings"
	"testing"

	"tcpquality/internal/config"
	"tcpquality/internal/nodes"
	"tcpquality/internal/probe"
)

func TestPortOr(t *testing.T) {
	if portOr("443", 80) != 443 {
		t.Error("valid port not parsed")
	}
	if portOr("", 80) != 80 {
		t.Error("empty should fall back")
	}
	if portOr("abc", 80) != 80 {
		t.Error("invalid should fall back")
	}
	if portOr("0", 80) != 80 {
		t.Error("zero should fall back")
	}
}

func TestRouteKeyAndLabelOr(t *testing.T) {
	labels := map[string]string{routeKey("北京", "电信"): "CN2GIA"}
	if labelOr(labels, "北京", "电信") != "CN2GIA" {
		t.Error("labelOr should return matching label")
	}
	if labelOr(labels, "上海", "移动") != "Hidden" {
		t.Error("missing label should be Hidden")
	}
	if labelOr(nil, "x", "y") != "Hidden" {
		t.Error("nil map should be Hidden")
	}
}

func TestFilterNodes(t *testing.T) {
	cfg := config.New()
	cfg.AddProvinceFilter("bj")
	a := New(cfg)
	list := []nodes.Node{
		{Province: "北京", ISP: "电信"},
		{Province: "上海", ISP: "联通"},
		{Province: "北京", ISP: "移动"},
	}
	got := a.filterNodes(list)
	if len(got) != 2 {
		t.Fatalf("filterNodes = %d, want 2", len(got))
	}
	for _, n := range got {
		if n.Province != "北京" {
			t.Errorf("unexpected province %q", n.Province)
		}
	}
}

func TestFilterNodesNoFilter(t *testing.T) {
	a := New(config.New())
	list := []nodes.Node{{Province: "北京"}, {Province: "上海"}}
	if len(a.filterNodes(list)) != 2 {
		t.Error("no filter should keep all nodes")
	}
}

func TestSkipResults(t *testing.T) {
	list := []nodes.Node{{Province: "北京", ISP: "电信", Host: "h", IP: "1.2.3.4"}}
	out := skipResults(list)
	if len(out) != 1 || out[0].Status != probe.StatusSkip {
		t.Errorf("skipResults wrong: %+v", out)
	}
}

func TestReportTime(t *testing.T) {
	full, short := nowReportTime()
	if !strings.Contains(full, "（北京时间）") {
		t.Errorf("full time missing suffix: %q", full)
	}
	if strings.Contains(short, "（") {
		t.Errorf("short time should not contain suffix: %q", short)
	}
	if !strings.Contains(short, "CST") {
		t.Errorf("short time missing CST: %q", short)
	}
}
