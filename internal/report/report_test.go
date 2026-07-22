package report

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBuilderBOMAndHeader(t *testing.T) {
	b := NewBuilder()
	out := b.Bytes()
	if !bytes.HasPrefix(out, []byte{0xEF, 0xBB, 0xBF}) {
		t.Error("CSV must start with UTF-8 BOM")
	}
	if !strings.Contains(string(out), csvHeader) {
		t.Error("CSV missing header")
	}
}

func TestBuilderAddProbe(t *testing.T) {
	b := NewBuilder()
	b.AddProbe("三网", "IPv4", "北京", "电信", "h", "1.2.3.4", "OK", 30, 29, 3.333, 12.3456, "CN2GIA")
	s := string(b.Bytes())
	if !strings.Contains(s, "三网,IPv4,北京,电信,h,1.2.3.4,OK,30,29,3.33,12.346,CN2GIA") {
		t.Errorf("row not formatted as expected:\n%s", s)
	}
}

func TestUpload(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "text/csv; charset=utf-8" {
			t.Errorf("bad content type: %s", r.Header.Get("Content-Type"))
		}
		if r.Header.Get("X-Report-Time") == "" {
			t.Error("missing report time header")
		}
		w.WriteHeader(200)
		w.Write([]byte(`{"url":"https://x/r/abc","todayUses":5,"totalUses":100}`))
	}))
	defer srv.Close()

	res, err := Upload(context.Background(), srv.URL, []byte("csv"), "2026-01-01 00:00:00")
	if err != nil {
		t.Fatal(err)
	}
	if res.URL != "https://x/r/abc" || res.TodayUses != 5 || res.TotalUses != 100 {
		t.Errorf("unexpected result: %+v", res)
	}
}

func TestUploadHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer srv.Close()
	if _, err := Upload(context.Background(), srv.URL, []byte("csv"), "t"); err == nil {
		t.Error("expected error on HTTP 500")
	}
}
