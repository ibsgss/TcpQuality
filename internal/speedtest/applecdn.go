package speedtest

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strconv"
	"time"
)

// transferStats is one AppleCDN transfer's outcome.
type transferStats struct {
	Bytes     int64
	Elapsed   time.Duration
	ConnectMs string
	TLSMs     string
}

// speed returns the transfer rate in Mbps, or "failed".
func (t transferStats) speed() string {
	if t.Elapsed <= 0 {
		return "failed"
	}
	return calcMbpsFromRate(float64(t.Bytes) / t.Elapsed.Seconds())
}

// appleClient builds an HTTP client pinned to one address family.
func appleClient(network string) *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	return &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
				return dialer.DialContext(ctx, network, addr)
			},
			TLSHandshakeTimeout: 5 * time.Second,
			DisableCompression:  true,
		},
		// Redirects are followed (curl -L); the per-request context bounds the
		// total time instead of a client timeout so partial transfers still
		// report the bytes they moved.
	}
}

// traceTimings records connect and TLS-handshake completion times relative to
// the start of the request, matching curl's time_connect / time_appconnect.
type traceTimings struct {
	start         time.Time
	connect       time.Duration
	tls           time.Duration
	firstByte     time.Duration
	haveConnect   bool
	haveTLS       bool
	haveFirstByte bool
}

func (t *traceTimings) clientTrace() *httptrace.ClientTrace {
	return &httptrace.ClientTrace{
		ConnectDone: func(_, _ string, err error) {
			if err == nil && !t.haveConnect {
				t.connect, t.haveConnect = time.Since(t.start), true
			}
		},
		TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
			if err == nil && !t.haveTLS {
				t.tls, t.haveTLS = time.Since(t.start), true
			}
		},
		GotFirstResponseByte: func() {
			if !t.haveFirstByte {
				t.firstByte, t.haveFirstByte = time.Since(t.start), true
			}
		},
	}
}

// connectMs and latencyMs mirror curl's time_connect and time_appconnect, with
// time_starttransfer as the fallback when TLS timing is unavailable.
func (t *traceTimings) connectMs() string { return msFromSeconds(t.connect.Seconds()) }

func (t *traceTimings) latencyMs() string {
	if ms := msFromSeconds(t.tls.Seconds()); ms != "-" {
		return ms
	}
	return msFromSeconds(t.firstByte.Seconds())
}

func appleRequest(ctx context.Context, method, url string, body io.Reader) (*http.Request, *traceTimings, error) {
	tt := &traceTimings{start: time.Now()}
	req, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, tt.clientTrace()), method, url, body)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("User-Agent", appleUserAgent)
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Accept-Language", "zh-CN,zh-Hans;q=0.9")
	req.Header.Set("Accept-Encoding", "identity")
	return req, tt, nil
}

// appleDownload streams the AppleCDN large object for at most timeout seconds
// and reports the achieved rate.
func appleDownload(ctx context.Context, network, url string, timeout time.Duration) transferStats {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, tt, err := appleRequest(ctx, http.MethodGet, url, nil)
	if err != nil {
		return transferStats{ConnectMs: "-", TLSMs: "-"}
	}
	resp, err := appleClient(network).Do(req)
	if err != nil {
		return transferStats{ConnectMs: tt.connectMs(), TLSMs: tt.latencyMs()}
	}
	defer resp.Body.Close()

	// Time only the payload transfer, so connection setup does not depress the
	// measured rate.
	transferStart := time.Now()
	n, _ := io.Copy(io.Discard, resp.Body)
	return transferStats{
		Bytes:     n,
		Elapsed:   time.Since(transferStart),
		ConnectMs: tt.connectMs(),
		TLSMs:     tt.latencyMs(),
	}
}

// zeroReader yields up to Max bytes of zeros and counts what was consumed.
type zeroReader struct {
	Max  int64
	sent int64
	ctx  context.Context
}

func (z *zeroReader) Read(p []byte) (int, error) {
	if z.ctx != nil && z.ctx.Err() != nil {
		return 0, z.ctx.Err()
	}
	if z.sent >= z.Max {
		return 0, io.EOF
	}
	n := int64(len(p))
	if remaining := z.Max - z.sent; n > remaining {
		n = remaining
	}
	clear(p[:n])
	z.sent += n
	return int(n), nil
}

// appleUpload streams zeros to the AppleCDN sink for at most timeout seconds
// and reports the achieved rate.
func appleUpload(ctx context.Context, network, url string, maxMB int, timeout time.Duration) transferStats {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	body := &zeroReader{Max: int64(maxMB) * 1024 * 1024, ctx: ctx}
	req, tt, err := appleRequest(ctx, http.MethodPut, url, body)
	if err != nil {
		return transferStats{ConnectMs: "-", TLSMs: "-"}
	}
	req.Header.Set("Upload-Draft-Interop-Version", "6")
	req.Header.Set("Upload-Complete", "?1")
	req.ContentLength = body.Max

	start := time.Now()
	resp, err := appleClient(network).Do(req)
	if resp != nil {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		resp.Body.Close()
	}
	// A deadline cut-off is expected: the bytes already written are the
	// measurement, exactly as curl reports size_upload on exit code 28.
	elapsed := time.Since(start)
	if err != nil && body.sent == 0 {
		return transferStats{ConnectMs: tt.connectMs(), TLSMs: tt.latencyMs()}
	}
	return transferStats{
		Bytes:     body.sent,
		Elapsed:   elapsed,
		ConnectMs: tt.connectMs(),
		TLSMs:     tt.latencyMs(),
	}
}

// ipv6Available reports whether the host has a route to the public IPv6
// internet, mirroring `ip -6 route get`.
func ipv6Available() bool {
	c, err := net.DialTimeout("udp6", net.JoinHostPort(appleIPv6ProbeAddress, "80"), 2*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// collectAppleCDN runs the AppleCDN reference test over IPv4 and IPv6.
func collectAppleCDN(ctx context.Context, opts Options, retrans func() int) Row {
	row := Row{Label: AppleLabel, Apple: true}
	timeout := time.Duration(opts.Timeout) * time.Second
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	maxMB := opts.AppleMaxUpMB
	if maxMB <= 0 {
		maxMB = appleDefaultMaxUpMB
	}

	for _, f := range []struct {
		name    string
		network string
	}{{"Apple IPv4", "tcp4"}, {"Apple IPv6", "tcp6"}} {
		if f.network == "tcp6" && !ipv6Available() {
			row.Entries = append(row.Entries, newSkippedResult(appleHost, f.name))
			continue
		}
		before := retrans()
		dl := appleDownload(ctx, f.network, opts.AppleDownloadURL, timeout)
		dlRetrans := retrans() - before
		if dlRetrans < 0 {
			dlRetrans = 0
		}
		ul := appleUpload(ctx, f.network, opts.AppleUploadURL, maxMB, timeout)

		e := CarrierResult{
			Upload:            ul.speed(),
			Retrans:           strconv.Itoa(dlRetrans),
			Download:          dl.speed(),
			ServerID:          appleHost,
			City:              f.name,
			UploadConnectMs:   ul.ConnectMs,
			UploadTLSMs:       ul.TLSMs,
			DownloadConnectMs: dl.ConnectMs,
			DownloadTLSMs:     dl.TLSMs,
		}
		if e.Failed() {
			e.Retrans = "failed"
		}
		row.Entries = append(row.Entries, e)
	}
	return row
}
