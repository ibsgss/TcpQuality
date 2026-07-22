// Package probe implements native raw TCP SYN loss/latency probing (Linux) plus
// the platform-independent aggregation and backup-retry logic that mirrors
// probe_target / test_one / combine_probe_results in the original script.
package probe

import (
	"context"
	"fmt"
	"math/rand"
	"strconv"

	"tcpquality/internal/iputil"
)

// Status is the outcome of a probe.
type Status string

const (
	StatusOK   Status = "OK"
	StatusFail Status = "FAIL"
	StatusSkip Status = "SKIP"
)

// Result is one node's aggregated probe outcome.
type Result struct {
	Status   Status
	Province string
	ISP      string
	Host     string
	IP       string
	Sent     int
	Rcvd     int
	LossPct  float64 // 0..100
	AvgRTT   float64 // milliseconds
	Detail   string  // failure reason token (e.g. NPING_ERROR), or "" on success
}

// Line renders the result in the pipe-delimited form used by the bash script:
// STATUS|prov|isp|host|ip|sent|rcvd|loss|lat
func (r Result) Line() string {
	ip := r.IP
	if r.Detail != "" && r.Status != StatusOK {
		ip = r.Detail
	}
	return fmt.Sprintf("%s|%s|%s|%s|%s|%d|%d|%.2f|%.3f",
		r.Status, r.Province, r.ISP, r.Host, ip, r.Sent, r.Rcvd, r.LossPct, r.AvgRTT)
}

// synSender sends a single SYN and reports whether a reply arrived and its RTT.
type synSender interface {
	// ProbeOnce sends one SYN whose total IP datagram size is `size` bytes
	// (0 means a standard, payload-free SYN) to ip:port. It returns the RTT in
	// milliseconds and whether any TCP reply (SYN-ACK or RST) came back.
	ProbeOnce(ip string, port, size int) (rttMs float64, replied bool, err error)
	Close() error
}

// Prober performs multi-packet probes for a single address family.
type Prober struct {
	family string
	sender synSender
	rng    *rand.Rand

	// Packets is the number of SYNs per target.
	Packets int
	// SizeOverride, when non-empty, forces every packet's total IP size.
	// "0" means a standard payload-free SYN; "" defers to the size pools.
	SizeOverride string
	// LargeMode enables the weighted big/small size distribution.
	LargeMode bool
	// Debug retains additional diagnostics (currently unused placeholder).
	Debug bool
}

// NewProber constructs a Prober for family "4" or "6". It fails on non-Linux
// platforms where raw sockets are unavailable.
func NewProber(family string) (*Prober, error) {
	s, err := newSender(family)
	if err != nil {
		return nil, err
	}
	return &Prober{
		family:  family,
		sender:  s,
		rng:     rand.New(rand.NewSource(rand.Int63())),
		Packets: 30,
	}, nil
}

// Close releases the underlying sockets.
func (p *Prober) Close() error {
	if p.sender == nil {
		return nil
	}
	return p.sender.Close()
}

func (p *Prober) headerSize() int {
	if p.family == "6" {
		return 60
	}
	return 40
}

// packetSize picks the total IP size for packet i (1-based) of a probe run,
// mirroring the selection logic inside probe_target.
func (p *Prober) packetSize(i, bigTarget int, bigUsed, smallUsed *int) int {
	if p.SizeOverride != "" {
		n, _ := strconv.Atoi(p.SizeOverride)
		return n
	}
	if p.LargeMode {
		remaining := p.Packets - i + 1
		bigRemaining := bigTarget - *bigUsed
		smallRemaining := p.Packets - bigTarget - *smallUsed
		if bigRemaining >= remaining || smallRemaining <= 0 || p.rng.Intn(remaining) < bigRemaining {
			*bigUsed++
			return sizeConst.big[p.rng.Intn(len(sizeConst.big))]
		}
		*smallUsed++
		return sizeConst.small[p.rng.Intn(len(sizeConst.small))]
	}
	return sizeConst.normal[p.rng.Intn(len(sizeConst.normal))]
}

// ProbeTarget sends Packets SYNs to a single endpoint and aggregates the result.
func (p *Prober) ProbeTarget(ctx context.Context, prov, isp, host, ip string, port int) Result {
	if p.family == "4" && ip != "" && !iputil.IsPublicIPv4(ip) {
		ip = ""
	}
	if ip == "" {
		return Result{Status: StatusFail, Province: prov, ISP: isp, Host: host,
			Sent: 0, Rcvd: 0, LossPct: 100, Detail: "GETNODES"}
	}

	bigTarget := 0
	if p.LargeMode {
		bigTarget = (p.Packets*3 + 3) / 4
	}
	bigUsed, smallUsed := 0, 0
	header := p.headerSize()

	sent, rcvd := 0, 0
	rttSum := 0.0
	for i := 1; i <= p.Packets; i++ {
		select {
		case <-ctx.Done():
			return Result{Status: StatusFail, Province: prov, ISP: isp, Host: host, IP: ip,
				Sent: sent, Rcvd: rcvd, LossPct: 100, Detail: "CANCELLED"}
		default:
		}
		size := p.packetSize(i, bigTarget, &bigUsed, &smallUsed)
		// Normalize sub-header sizes: payload only when size exceeds header.
		if size > 0 && size < header {
			size = header
		}
		rtt, replied, err := p.sender.ProbeOnce(ip, port, size)
		if err != nil {
			return Result{Status: StatusFail, Province: prov, ISP: isp, Host: host, IP: ip,
				Sent: 0, Rcvd: 0, LossPct: 100, Detail: "SYN_ERROR"}
		}
		sent++
		if replied {
			rcvd++
			rttSum += rtt
		}
	}

	loss := 100.0
	if sent > 0 {
		loss = float64(sent-rcvd) * 100 / float64(sent)
	}
	avg := 0.0
	if rcvd > 0 {
		avg = rttSum / float64(rcvd)
	}
	return Result{Status: StatusOK, Province: prov, ISP: isp, Host: host, IP: ip,
		Sent: sent, Rcvd: rcvd, LossPct: loss, AvgRTT: avg}
}

// sizeConst holds the size pools; defined here to avoid importing config and
// creating a cycle, kept in sync with config.PacketSizes et al.
var sizeConst = struct {
	normal []int
	small  []int
	big    []int
}{
	normal: []int{40, 80, 160, 320, 640, 1200},
	small:  []int{120, 240, 480},
	big:    []int{900, 950, 1000, 1050, 1100, 1150, 1200, 1200, 900},
}
