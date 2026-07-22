//go:build linux

package speedtest

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"tcpquality/internal/nodes"
)

const (
	ifbName       = "ifb_tqtest"
	hostsBeginTag = "# tcpquality-tos-speedtest begin"
	hostsEndTag   = "# tcpquality-tos-speedtest end"
)

// runner holds mutable state for a single speedtest run.
type runner struct {
	opts       Options
	iface      string
	createdIFB bool
	hostsSaved []byte
}

// Run performs the staged speedtest. onProgress(done,total) is called after each
// carrier probe pair completes.
func Run(ctx context.Context, opts Options, tos []nodes.SpeedtestNode, onProgress func(done, total int)) (*Results, error) {
	if os.Geteuid() != 0 {
		return nil, errors.New("测速需要 root 权限")
	}
	for _, cmd := range []string{"ip", "tc", "nstat", "modprobe"} {
		if _, err := exec.LookPath(cmd); err != nil {
			return nil, fmt.Errorf("缺少测速依赖: %s", cmd)
		}
	}

	res := &Results{}
	res.Selected = opts.applyNodes(tos)

	if err := ensureTosutil(ctx, &opts); err != nil {
		return nil, err
	}

	r := &runner{opts: opts}
	iface, err := defaultIface()
	if err != nil {
		return nil, err
	}
	r.iface = iface
	defer r.cleanup()

	total := len(Rates) * len(Carriers)
	done := 0
	if onProgress != nil {
		onProgress(0, total)
	}

	carrierIP := func(i int) string {
		switch Carriers[i] {
		case "电信":
			return opts.CTIP
		case "联通":
			return opts.CUIP
		default:
			return opts.CMIP
		}
	}

	for _, rate := range Rates {
		if err := r.applyLimit(rate); err != nil {
			return nil, fmt.Errorf("无法应用 %s 限速: %w", rate, err)
		}
		time.Sleep(2 * time.Second)
		row := RateRow{Label: rateLabel(rate)}
		for i := range Carriers {
			var cr CarrierResult
			if err := r.forceHosts(carrierIP(i)); err == nil {
				dl, _ := r.runProbe(ctx, "download")
				ul, ulRetrans := r.runProbe(ctx, "upload")
				cr = CarrierResult{Upload: ul, Retrans: strconv.Itoa(ulRetrans), Download: dl}
			} else {
				cr = CarrierResult{"failed", "0", "failed"}
			}
			r.restoreHosts()
			if cr.Failed() {
				cr = CarrierResult{"failed", "failed", "failed"}
			}
			row.Carriers[i] = cr
			done++
			if onProgress != nil {
				onProgress(done, total)
			}
		}
		res.Rows = append(res.Rows, row)
	}
	r.cleanup()
	return res, nil
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

func ensureTosutil(ctx context.Context, opts *Options) error {
	if opts.TosutilBin != "" {
		if _, err := os.Stat(opts.TosutilBin); err == nil {
			return nil
		}
	}
	if p, err := exec.LookPath("tosutil"); err == nil {
		opts.TosutilBin = p
		return nil
	}
	if _, err := os.Stat("./tosutil"); err == nil {
		opts.TosutilBin = "./tosutil"
		return nil
	}
	// Download the official binary.
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, opts.TosutilURL, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("下载 tosutil 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
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
	opts.TosutilBin = dst
	return nil
}

func run(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

func (r *runner) applyLimit(rate string) error {
	r.cleanupLimits()
	if rate == "unlimited" {
		return nil
	}
	if err := run("modprobe", "ifb"); err != nil {
		return err
	}
	if err := exec.Command("ip", "link", "show", ifbName).Run(); err != nil {
		if err := run("ip", "link", "add", ifbName, "type", "ifb"); err != nil {
			return err
		}
		r.createdIFB = true
	}
	if err := run("ip", "link", "set", ifbName, "up"); err != nil {
		return err
	}
	mbit := rate + "mbit"
	if err := run("tc", "qdisc", "add", "dev", r.iface, "root", "tbf", "rate", mbit, "burst", "1mb", "latency", "500ms"); err != nil {
		return err
	}
	if err := run("tc", "qdisc", "add", "dev", r.iface, "handle", "ffff:", "ingress"); err != nil {
		return err
	}
	if err := run("tc", "filter", "add", "dev", r.iface, "parent", "ffff:", "protocol", "all", "u32",
		"match", "u32", "0", "0", "action", "mirred", "egress", "redirect", "dev", ifbName); err != nil {
		return err
	}
	return run("tc", "qdisc", "add", "dev", ifbName, "root", "tbf", "rate", mbit, "burst", "1mb", "latency", "500ms")
}

func (r *runner) cleanupLimits() {
	if r.iface != "" {
		_ = run("tc", "qdisc", "del", "dev", r.iface, "root")
		_ = run("tc", "qdisc", "del", "dev", r.iface, "ingress")
	}
	_ = run("tc", "qdisc", "del", "dev", ifbName, "root")
	if r.createdIFB {
		_ = run("ip", "link", "set", ifbName, "down")
		_ = run("ip", "link", "delete", ifbName, "type", "ifb")
		r.createdIFB = false
	}
}

func (r *runner) cleanup() {
	r.cleanupLimits()
	r.restoreHosts()
}

func (r *runner) forceHosts(ip string) error {
	if ip == "" {
		return errors.New("无 carrier IP")
	}
	if r.hostsSaved == nil {
		data, err := os.ReadFile("/etc/hosts")
		if err != nil {
			return err
		}
		r.hostsSaved = data
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
	for _, h := range r.opts.endpointHosts() {
		fmt.Fprintf(&b, "%s %s\n", ip, h)
	}
	b.WriteString(hostsEndTag + "\n")
	return os.WriteFile("/etc/hosts", []byte(b.String()), 0o644)
}

func (r *runner) restoreHosts() {
	if r.hostsSaved == nil {
		return
	}
	_ = os.WriteFile("/etc/hosts", r.hostsSaved, 0o644)
	r.hostsSaved = nil
}

// runProbe runs one tosutil probe and returns the measured Mbps and retrans.
func (r *runner) runProbe(ctx context.Context, probeType string) (string, int) {
	var stdout bytes.Buffer
	cmd := exec.CommandContext(ctx, r.opts.TosutilBin, "probe",
		"-tr", r.opts.Region, "-pt", probeType, "-nt", r.opts.Network,
		"-ps", r.opts.Size, "-timeout", strconv.Itoa(r.opts.Timeout))
	cmd.Stdout = &stdout
	if err := cmd.Start(); err != nil {
		return "failed", 0
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	// Warm-up window before sampling counters.
	select {
	case err := <-waitCh:
		_ = err
		return "failed", 0 // exited during warmup
	case <-time.After(time.Duration(r.opts.Warmup) * time.Second):
	}

	startBytes, okStart := netBytes(r.iface, probeType)
	before := retransCount()
	startTime := time.Now()
	err := <-waitCh
	endTime := time.Now()
	endBytes, okEnd := netBytes(r.iface, probeType)
	after := retransCount()

	parsed := parseRateMbps(stdout.String())
	retrans := after - before
	if retrans < 0 {
		retrans = 0
	}

	result := parsed
	if okStart && okEnd {
		duration := endTime.Sub(startTime).Seconds()
		delta := endBytes - startBytes
		if r := calcMbps(delta, duration); r != "failed" {
			result = r
		}
	}
	if err != nil && parsed == "failed" {
		result = "failed"
	}
	if result == "" {
		result = "failed"
	}
	return result, retrans
}

func netBytes(iface, probeType string) (int64, bool) {
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
