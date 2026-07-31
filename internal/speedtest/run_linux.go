//go:build linux

package speedtest

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"tcpquality/internal/report"
)

const (
	hostsBeginTag = "# tcpquality-tos-speedtest begin"
	hostsEndTag   = "# tcpquality-tos-speedtest end"
	defaultHosts  = "127.0.0.1 localhost\n::1 localhost\n"
)

// runner holds mutable state for a single speedtest run.
type runner struct {
	opts  Options
	iface string

	// hostsSaved is the original /etc/hosts; hostsExisted records whether the
	// file was there at all, so a synthesized file is removed rather than
	// restored.
	hostsSaved   []byte
	hostsExisted bool

	// counterChain/counterHook name the live iptables accounting chain.
	counterChain string
	counterHook  string

	rankEligible bool
	rankReason   string
}

// Run performs the speedtest. onProgress(done,total) is called after each
// carrier probe pair and after the AppleCDN block.
func Run(ctx context.Context, opts Options, onProgress func(done, total int)) (*Results, error) {
	if os.Geteuid() != 0 {
		return nil, errors.New("测速需要 root 权限")
	}

	r := &runner{opts: opts, rankEligible: true}
	r.iface, _ = defaultIface() // best-effort; only used for the last-resort byte counter
	defer r.cleanup()

	if !hasCommand("iptables") {
		r.disableRank(report.ReasonIptablesUnavailable)
	}
	if err := ensureTosutil(ctx, &r.opts); err != nil {
		return nil, err
	}

	res := &Results{TCPConfig: readTCPConfig()}
	total := opts.StepCount()
	done := 0
	if onProgress != nil {
		onProgress(0, total)
	}

	for _, g := range opts.Groups {
		row := Row{Label: g.Label, Entries: make([]CarrierResult, len(Carriers))}
		for i, carrier := range Carriers {
			row.Entries[i] = r.runCarrier(ctx, g, carrier)
			done++
			if onProgress != nil {
				onProgress(done, total)
			}
		}
		res.Rows = append(res.Rows, row)
	}
	r.restoreHosts()

	if opts.AppleCDN {
		res.Rows = append(res.Rows, collectAppleCDN(ctx, opts, retransCount))
		done++
		if onProgress != nil {
			onProgress(done, total)
		}
	}

	res.RankEligible = r.rankEligible
	res.RankDisabledReason = r.rankReason
	return res, nil
}

// runCarrier measures one carrier in one region.
func (r *runner) runCarrier(ctx context.Context, g Group, carrier string) CarrierResult {
	candidate, ok := r.opts.PickCandidate(carrier, g.Region)
	city := candidate.City
	if city == "" {
		city = RegionTitle(g.Region)
	}
	if !ok || candidate.IP == "" {
		return newFailedResult("", "")
	}
	if err := r.forceHosts(candidate.IP, g.Region); err != nil {
		return newFailedResult(candidate.IP, city)
	}

	dl := r.runProbe(ctx, "download", g.Region, candidate.IP)
	ul := r.runProbe(ctx, "upload", g.Region, candidate.IP)

	res := CarrierResult{
		Upload:            ul.speed,
		Retrans:           strconv.Itoa(ul.retrans),
		Download:          dl.speed,
		ServerID:          candidate.IP,
		City:              city,
		UploadConnectMs:   ul.connectMs,
		UploadTLSMs:       ul.tlsMs,
		DownloadConnectMs: dl.connectMs,
		DownloadTLSMs:     dl.tlsMs,
	}
	if res.Failed() {
		res.Retrans = "failed"
	}
	return res
}

func hasCommand(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func (r *runner) disableRank(reason string) {
	r.rankEligible = false
	if r.rankReason == "" {
		r.rankReason = reason
	}
}

func defaultIface() (string, error) {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return "", fmt.Errorf("无法识别默认网络接口: %w", err)
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "dev" && i+1 < len(fields) {
			return fields[i+1], nil
		}
	}
	return "", errors.New("无法识别默认网络接口")
}

// tosutilWorks verifies a candidate binary actually runs; a truncated or
// wrong-architecture download otherwise fails silently at probe time.
func tosutilWorks(path string) bool {
	return exec.Command(path, "version").Run() == nil
}

func ensureTosutil(ctx context.Context, opts *Options) error {
	if opts.TosutilBin != "" && tosutilWorks(opts.TosutilBin) {
		return nil
	}
	if p, err := exec.LookPath("tosutil"); err == nil && tosutilWorks(p) {
		opts.TosutilBin = p
		return nil
	}
	if tosutilWorks("./tosutil") {
		opts.TosutilBin = "./tosutil"
		return nil
	}
	if opts.TosutilURL == "" {
		return errors.New("当前架构没有可用的 tosutil 官方二进制")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, opts.TosutilURL, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("下载 tosutil 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("下载 tosutil 失败 HTTP %d", resp.StatusCode)
	}
	dst := "/usr/local/bin/tosutil"
	f, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return fmt.Errorf("写入 tosutil 失败: %w", err)
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	f.Close()
	if !tosutilWorks(dst) {
		return errors.New("tosutil 安装失败")
	}
	opts.TosutilBin = dst
	return nil
}

func (r *runner) cleanup() {
	r.counterStop()
	r.restoreHosts()
}

// ---- /etc/hosts pinning ----

func (r *runner) forceHosts(ip, region string) error {
	if ip == "" {
		return errors.New("无 carrier IP")
	}
	if r.hostsSaved == nil {
		data, err := os.ReadFile("/etc/hosts")
		switch {
		case err == nil:
			r.hostsSaved, r.hostsExisted = data, true
		case os.IsNotExist(err):
			// Minimal container images ship without /etc/hosts; synthesize one
			// and drop it again on restore.
			r.hostsSaved, r.hostsExisted = []byte{}, false
		default:
			return err
		}
	}
	var b strings.Builder
	skip := false
	for _, line := range strings.Split(string(r.hostsSaved), "\n") {
		switch strings.TrimSpace(line) {
		case hostsBeginTag:
			skip = true
			continue
		case hostsEndTag:
			skip = false
			continue
		}
		if !skip {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	b.WriteString(hostsBeginTag + "\n")
	for _, h := range endpointHosts(region) {
		fmt.Fprintf(&b, "%s %s\n", ip, h)
	}
	b.WriteString(hostsEndTag + "\n")
	return os.WriteFile("/etc/hosts", []byte(b.String()), 0o644)
}

func (r *runner) restoreHosts() {
	if r.hostsSaved == nil {
		return
	}
	if r.hostsExisted {
		_ = os.WriteFile("/etc/hosts", r.hostsSaved, 0o644)
	} else {
		_ = os.WriteFile("/etc/hosts", []byte(defaultHosts), 0o644)
	}
	r.hostsSaved = nil
	r.hostsExisted = false
}

// ---- iptables byte counters (anti-cheat corroboration) ----

// counterStart installs a per-run accounting chain matching traffic to/from the
// measured server on port 443. Its byte counter is independent of tosutil, so a
// forged tosutil result cannot inflate the rank.
func (r *runner) counterStart(probeType, serverIP string) bool {
	r.counterStop()
	if serverIP == "" || !hasCommand("iptables") {
		return false
	}
	hook := "OUTPUT"
	if probeType == "download" {
		hook = "INPUT"
	}
	chain := fmt.Sprintf("TCPQ_TOS_%d_%d", os.Getpid(), rand.Intn(32768))

	if exec.Command("iptables", "-N", chain).Run() != nil {
		return false
	}
	if exec.Command("iptables", "-I", hook, "1", "-j", chain).Run() != nil {
		exec.Command("iptables", "-F", chain).Run()
		exec.Command("iptables", "-X", chain).Run()
		return false
	}
	r.counterChain, r.counterHook = chain, hook

	var rule []string
	if probeType == "download" {
		rule = []string{"-A", chain, "-p", "tcp", "-s", serverIP, "--sport", "443", "-j", "RETURN"}
	} else {
		rule = []string{"-A", chain, "-p", "tcp", "-d", serverIP, "--dport", "443", "-j", "RETURN"}
	}
	if exec.Command("iptables", rule...).Run() != nil {
		r.counterStop()
		return false
	}
	return true
}

func (r *runner) counterStop() {
	if r.counterChain != "" && r.counterHook != "" {
		exec.Command("iptables", "-D", r.counterHook, "-j", r.counterChain).Run()
		exec.Command("iptables", "-F", r.counterChain).Run()
		exec.Command("iptables", "-X", r.counterChain).Run()
	}
	r.counterChain, r.counterHook = "", ""
}

// counterBytes reads the accounting rule's byte count.
func (r *runner) counterBytes() (int64, bool) {
	if r.counterChain == "" {
		return 0, false
	}
	out, err := exec.Command("iptables", "-L", r.counterChain, "-v", "-x", "-n").Output()
	if err != nil {
		return 0, false
	}
	for i, line := range strings.Split(string(out), "\n") {
		if i < 2 {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[2] == "RETURN" {
			n, err := strconv.ParseInt(fields[1], 10, 64)
			if err != nil {
				return 0, false
			}
			return n, true
		}
	}
	return 0, false
}

// ---- tosutil probe ----

type probeOutcome struct {
	speed     string
	retrans   int
	connectMs string
	tlsMs     string
}

func failedProbe(connectMs, tlsMs string) probeOutcome {
	return probeOutcome{speed: "failed", connectMs: connectMs, tlsMs: tlsMs}
}

// runProbe runs one tosutil probe and returns the measured rate and timings.
func (r *runner) runProbe(ctx context.Context, probeType, region, serverIP string) probeOutcome {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, r.opts.TosutilBin, "probe",
		"-tr", region, "-pt", probeType, "-nt", r.opts.Network,
		"-ps", r.opts.Size, "-timeout", strconv.Itoa(r.opts.Timeout))
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return failedProbe("-", "-")
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	// Warm-up window before sampling counters, so TCP slow start is excluded.
	select {
	case <-waitCh:
		out := stdout.String() + "\n" + stderr.String()
		return failedProbe(parseCostMs(out, "Build connection cost"), parseCostMs(out, "Tls handshake cost"))
	case <-time.After(time.Duration(r.opts.Warmup) * time.Second):
	}

	counterOK := r.counterStart(probeType, serverIP)
	if !counterOK {
		r.disableRank(report.ReasonCounterUnavailable)
	}
	startBytes, haveStart := r.sampleBytes(counterOK, probeType)
	before := retransCount()
	startTime := time.Now()

	<-waitCh

	duration := time.Since(startTime).Seconds()
	endBytes, haveEnd := r.sampleBytes(counterOK, probeType)
	r.counterStop()
	after := retransCount()

	out := stdout.String() + "\n" + stderr.String()
	parsed := parseRateMbps(out)
	retrans := after - before
	if retrans < 0 {
		retrans = 0
	}

	// tosutil's own figure is the most accurate link-layer measurement, so it
	// always wins. The byte counters are only fallbacks — a counter that missed
	// the data flow must not turn a good run into 0 Mbps.
	speed := parsed
	if speed == "failed" && haveStart && haveEnd {
		speed = calcMbps(endBytes-startBytes, duration)
	}

	// Independently corroborate that traffic really happened; failure here only
	// costs rank eligibility, never the displayed speed.
	if counterOK {
		switch {
		case !haveStart || !haveEnd:
			r.disableRank(report.ReasonCounterReadFailed)
		case endBytes-startBytes <= 0:
			r.disableRank(report.ReasonCounterZero)
		}
	}

	return probeOutcome{
		speed:     speed,
		retrans:   retrans,
		connectMs: parseCostMs(out, "Build connection cost"),
		tlsMs:     parseCostMs(out, "Tls handshake cost"),
	}
}

// sampleBytes reads the iptables counter when available, else the interface
// counter.
func (r *runner) sampleBytes(counterOK bool, probeType string) (int64, bool) {
	if counterOK {
		return r.counterBytes()
	}
	return netBytes(r.iface, probeType)
}

func netBytes(iface, probeType string) (int64, bool) {
	if iface == "" {
		return 0, false
	}
	stat := "rx_bytes"
	if probeType == "upload" {
		stat = "tx_bytes"
	}
	data, err := os.ReadFile("/sys/class/net/" + iface + "/statistics/" + stat)
	if err != nil {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

func retransCount() int {
	out, err := exec.Command("nstat", "-az").Output()
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "TcpRetransSegs" {
			if n, err := strconv.Atoi(fields[1]); err == nil {
				return n
			}
		}
	}
	return 0
}
