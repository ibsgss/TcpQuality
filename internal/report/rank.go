package report

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"
)

// Rank ineligibility reasons, sent to the API as X-TcpQuality-Rank-Disabled-Reason.
const (
	ReasonSessionRequestFailed  = "rank_session_request_failed"
	ReasonIptablesUnavailable   = "iptables_unavailable"
	ReasonCounterUnavailable    = "target_counter_unavailable"
	ReasonCounterReadFailed     = "target_counter_read_failed"
	ReasonCounterZero           = "target_counter_zero"
	ReasonSpeedtestNotPerformed = "speedtest_not_performed"
)

// RankSession is the server-issued token proving a speedtest run happened
// within a bounded, server-observed window.
type RankSession struct {
	SessionID  string `json:"sessionId"`
	Token      string `json:"token"`
	StartedAt  string `json:"startedAt"`
	ExpiresAt  string `json:"expiresAt"`
	SessionIP4 string `json:"sessionIp4"`
}

// RequestRankSession opens a rank session before the speedtest starts. A failure
// is not fatal: the caller simply uploads without rank eligibility.
func RequestRankSession(ctx context.Context, apiURL, publicIPv4, publicIPv6 string) (*RankSession, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-TcpQuality-Public-IPv4", publicIPv4)
	req.Header.Set("X-TcpQuality-Public-IPv6", publicIPv6)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, errors.New("rank session HTTP " + resp.Status)
	}
	var s RankSession
	if err := json.Unmarshal(body, &s); err != nil {
		return nil, err
	}
	if s.SessionID == "" || s.Token == "" {
		return nil, errors.New("rank session 响应缺少凭证")
	}
	return &s, nil
}
