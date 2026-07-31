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
		if r.Header.Get("X-TcpQuality-Public-IPv4") != "1.2.3.4" {
			t.Errorf("missing public IPv4 header: %q", r.Header.Get("X-TcpQuality-Public-IPv4"))
		}
		if r.Header.Get("X-TcpQuality-Rank-Session") != "sess-1" ||
			r.Header.Get("X-TcpQuality-Rank-Token") != "tok-1" {
			t.Error("missing rank session headers")
		}
		if r.Header.Get("X-TcpQuality-Rank-Finished-At") == "" {
			t.Error("missing rank finished-at header")
		}
		w.WriteHeader(200)
		w.Write([]byte(`{"id":"abc","url":"https://x/r/abc","todayUses":5,"totalUses":100,` +
			`"rankUpdated":false,"rankRejectReason":"too_slow"}`))
	}))
	defer srv.Close()

	res, err := Upload(context.Background(), srv.URL, []byte("csv"), UploadOptions{
		ReportTime: "2026-01-01 00:00:00",
		PublicIPv4: "1.2.3.4",
		Session:    &RankSession{SessionID: "sess-1", Token: "tok-1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.ID != "abc" || res.URL != "https://x/r/abc" || res.TodayUses != 5 || res.TotalUses != 100 {
		t.Errorf("unexpected result: %+v", res)
	}
	if res.RankUpdated == nil || *res.RankUpdated || res.RankRejectReason != "too_slow" {
		t.Errorf("rank fields not parsed: %+v", res)
	}
}

func TestUploadWithoutSessionSendsDisabledReason(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-TcpQuality-Rank-Session") != "" {
			t.Error("no session should mean no session header")
		}
		if r.Header.Get("X-TcpQuality-Rank-Disabled-Reason") != ReasonIptablesUnavailable {
			t.Errorf("missing disabled reason: %q", r.Header.Get("X-TcpQuality-Rank-Disabled-Reason"))
		}
		w.Write([]byte(`{"url":"https://x/r/abc"}`))
	}))
	defer srv.Close()

	if _, err := Upload(context.Background(), srv.URL, []byte("csv"), UploadOptions{
		RankDisabledReason: ReasonIptablesUnavailable,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestRequestRankSession(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-TcpQuality-Public-IPv4") != "1.2.3.4" {
			t.Error("missing public IPv4 header")
		}
		w.Write([]byte(`{"sessionId":"s1","token":"t1","startedAt":"a","expiresAt":"b","sessionIp4":"1.2.3.4"}`))
	}))
	defer srv.Close()

	s, err := RequestRankSession(context.Background(), srv.URL, "1.2.3.4", "")
	if err != nil {
		t.Fatal(err)
	}
	if s.SessionID != "s1" || s.Token != "t1" || s.SessionIP4 != "1.2.3.4" {
		t.Errorf("unexpected session: %+v", s)
	}
}

func TestRequestRankSessionRejectsIncomplete(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"sessionId":"s1"}`))
	}))
	defer srv.Close()
	if _, err := RequestRankSession(context.Background(), srv.URL, "", ""); err == nil {
		t.Error("expected error when the token is missing")
	}
}

func TestUploadHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer srv.Close()
	if _, err := Upload(context.Background(), srv.URL, []byte("csv"), UploadOptions{ReportTime: "t"}); err == nil {
		t.Error("expected error on HTTP 500")
	}
}
