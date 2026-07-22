package app

import (
	"context"

	"tcpquality/internal/config"
	"tcpquality/internal/international"
	"tcpquality/internal/iputil"
	"tcpquality/internal/nodes"
	"tcpquality/internal/probe"
	"tcpquality/internal/render"
	"tcpquality/internal/report"
	"tcpquality/internal/speedtest"
)

const largePacketRouteSize = 1200

func (a *App) newProber(family string, packets int, largeMode bool, sizeOverride string) (*probe.Prober, error) {
	p, err := probe.NewProber(family)
	if err != nil {
		return nil, err
	}
	p.Packets = packets
	p.LargeMode = largeMode
	p.SizeOverride = sizeOverride
	p.Debug = a.cfg.DebugMode
	return p, nil
}

// mainState captures which sections are active for this run.
type mainState struct {
	ipv4Enabled, ipv6Enabled bool
	normalCDN                bool
	testEdu                  bool
	largeEnabled             bool // large-packet section shown at all
	largeProbe               bool // large-packet probing actually runs
	firewallLimited          bool
}

func (a *App) runMainMode(ctx context.Context) error {
	a.stack = iputil.Detect(ctx)
	set, err := a.fetchNodes(ctx, a.cfg.NodeScope())
	if err != nil {
		return err
	}

	st := a.deriveState(set)
	if !st.ipv4Enabled && !st.ipv6Enabled {
		a.printf("%s[X] 没有可执行的探测任务%s\n", config.Red, config.NC)
		return nil
	}

	// ---- probe phase ----
	cdn4 := a.filterNodes(set.CDN4)
	cdn6 := a.filterNodes(set.CDN6)
	cernet := a.filterNodes(set.CERNET)
	cernet2 := a.filterNodes(set.CERNET2)

	var res struct {
		cdn4, cdn6, large4, cernet, cernet2 []probe.Result
	}

	total := 0
	if st.normalCDN && st.ipv4Enabled {
		total += len(cdn4)
	}
	if st.normalCDN && st.ipv6Enabled {
		total += len(cdn6)
	}
	if st.largeProbe {
		total += len(cdn4)
	}
	if st.testEdu && st.ipv4Enabled {
		total += len(cernet)
	}
	if st.testEdu && st.ipv6Enabled {
		total += len(cernet2)
	}
	a.printf("%s  检测范围: %s  探测节点: %d  每节点发包: %d  并行: %d%s\n\n",
		config.Dim, a.cfg.ProvinceFilterText(), total, a.cfg.Packets, a.cfg.Parallel, config.NC)

	pc := a.newProgress("延迟重传", total)
	if st.normalCDN && st.ipv4Enabled {
		res.cdn4 = a.probeFamily(ctx, "4", a.cfg.Packets, false, a.cfg.PacketSizeOverride, cdn4, 80, pc.inc)
	}
	if st.normalCDN && st.ipv6Enabled {
		res.cdn6 = a.probeFamily(ctx, "6", a.cfg.Packets, false, a.cfg.PacketSizeOverride, cdn6, 80, pc.inc)
	}
	if st.largeProbe {
		res.large4 = a.probeFamily(ctx, "4", a.cfg.Packets, true, "", cdn4, 80, pc.inc)
	} else if st.largeEnabled {
		res.large4 = skipResults(cdn4)
	}
	if st.testEdu && st.ipv4Enabled {
		res.cernet = a.probeFamily(ctx, "4", a.cfg.Packets, false, a.cfg.PacketSizeOverride, cernet, 443, pc.inc)
	}
	if st.testEdu && st.ipv6Enabled {
		res.cernet2 = a.probeFamily(ctx, "6", a.cfg.Packets, false, a.cfg.PacketSizeOverride, cernet2, 443, pc.inc)
	}
	pc.finish()

	// ---- route identification phase ----
	var labels4, labels6, labelsLarge, labelsEdu4, labelsEdu6 map[string]string
	routeTotal := a.routeTotal(st, cdn4, cdn6, cernet, cernet2)
	if routeTotal > 0 {
		rpc := a.newProgress("回程识别", routeTotal)
		if st.normalCDN && st.ipv4Enabled {
			labels4 = a.collectRouteLabels(ctx, "4", "tcp", cdn4, 44, rpc.inc)
		}
		if st.largeProbe {
			labelsLarge = a.collectRouteLabels(ctx, "4", "tcp", cdn4, largePacketRouteSize, rpc.inc)
		}
		if st.normalCDN && st.ipv6Enabled {
			labels6 = a.collectRouteLabels(ctx, "6", "tcp", cdn6, 44, rpc.inc)
		}
		if st.testEdu && st.ipv4Enabled {
			labelsEdu4 = a.collectRouteLabels(ctx, "4", "tcp", cernet, 44, rpc.inc)
		}
		if st.testEdu && st.ipv6Enabled {
			labelsEdu6 = a.collectRouteLabels(ctx, "6", "tcp", cernet2, 44, rpc.inc)
		}
		rpc.finish()
	}

	// ---- international phase ----
	var intlResults []international.Result
	if a.cfg.InternationalEnabled && st.ipv4Enabled {
		if a.cfg.CountExplicit {
			a.cfg.InternationalPackets = a.cfg.Packets
		}
		if p, err := a.newV4Prober(a.cfg.InternationalPackets); err == nil {
			ipc := a.newProgress("国际互联", international.TaskCount())
			intlResults = international.RunAll(ctx, p, a.cfg.Parallel, ipc.inc)
			ipc.finish()
			p.Close()
		}
	}

	// ---- speedtest phase ----
	var speedResults *speedtest.Results
	if a.cfg.SpeedtestEnabled {
		tos := a.loadTOSNodes(ctx)
		opts := speedtest.DefaultOptions()
		opts.Debug = a.cfg.DebugMode
		spc := a.newProgress("分段测速", len(speedtest.Rates)*len(speedtest.Carriers))
		r, err := speedtest.Run(ctx, opts, tos, func(done, tot int) { spc.total = tot; spc.setDone(done) })
		spc.finish()
		if err != nil {
			r = speedtest.FailedResults()
			a.printf("  %s[!] 测速失败: %v%s\n", config.Yellow, err, config.NC)
		}
		speedResults = r
	}

	// ---- render + CSV + upload ----
	a.renderMain(ctx, st, res, labels4, labels6, labelsLarge, labelsEdu4, labelsEdu6, intlResults, speedResults)
	return nil
}

// probeFamily builds a prober, probes the list, and closes the prober.
func (a *App) probeFamily(ctx context.Context, family string, packets int, largeMode bool, sizeOverride string, list []nodes.Node, defPort int, onDone func()) []probe.Result {
	p, err := a.newProber(family, packets, largeMode, sizeOverride)
	if err != nil {
		// Mark everything failed if we cannot open sockets.
		out := make([]probe.Result, len(list))
		for i, n := range list {
			out[i] = probe.Result{Status: probe.StatusFail, Province: n.Province, ISP: n.ISP, Host: n.Host, IP: n.IP, LossPct: 100, Detail: "SOCKET"}
			if onDone != nil {
				onDone()
			}
		}
		return out
	}
	defer p.Close()
	return a.probeNodes(ctx, p, list, defPort, onDone)
}

func skipResults(list []nodes.Node) []probe.Result {
	out := make([]probe.Result, len(list))
	for i, n := range list {
		out[i] = probe.Result{Status: probe.StatusSkip, Province: n.Province, ISP: n.ISP, Host: n.Host, IP: n.IP}
	}
	return out
}

func (a *App) routeTotal(st mainState, cdn4, cdn6, cernet, cernet2 []nodes.Node) int {
	total := 0
	if st.normalCDN && st.ipv4Enabled {
		total += len(cdn4)
	}
	if st.largeProbe {
		total += len(cdn4)
	}
	if st.normalCDN && st.ipv6Enabled {
		total += len(cdn6)
	}
	if st.testEdu && st.ipv4Enabled {
		total += len(cernet)
	}
	if st.testEdu && st.ipv6Enabled {
		total += len(cernet2)
	}
	return total
}

// deriveState reproduces the enable/skip decisions of main().
func (a *App) deriveState(set *nodes.Set) mainState {
	st := mainState{normalCDN: true}
	want4, want6 := true, true
	switch {
	case a.cfg.TestAll:
	case a.cfg.OnlyIPv4 && !a.cfg.OnlyIPv6:
		want6 = false
	case a.cfg.OnlyIPv6 && !a.cfg.OnlyIPv4:
		want4 = false
	}
	st.ipv4Enabled = want4 && a.stack.IPv4Work
	if want4 && a.stack.IPv4Work {
		a.printf("%s[√] 检测到可用 IPv4%s\n", config.Green, config.NC)
	} else if want4 {
		a.printf("%s[!] 未检测到可用 IPv4，已跳过 IPv4%s\n", config.Yellow, config.NC)
	}

	testCDN := true
	if a.cfg.TestCernet && !a.cfg.TestAll {
		testCDN = false
		st.normalCDN = false
		st.testEdu = true
		a.cfg.InternationalEnabled = false
	} else if a.cfg.TestCernet || a.cfg.TestAll {
		st.testEdu = true
	}
	if a.cfg.OnlyLarge {
		st.normalCDN = false
		st.testEdu = false
		a.cfg.InternationalEnabled = false
	}
	if !st.ipv4Enabled {
		a.cfg.InternationalEnabled = false
	}

	// Large-packet section (IPv4 CDN only).
	if st.ipv4Enabled && testCDN {
		st.largeEnabled = true
		if a.largePacketPrecheck(context.Background()) {
			st.largeProbe = true
		} else {
			st.firewallLimited = true
		}
	}

	st.ipv6Enabled = want6 && a.stack.IPv6Work
	if want6 && a.stack.IPv6Work {
		a.printf("%s[√] 检测到可用 IPv6%s\n", config.Green, config.NC)
	} else if want6 {
		a.printf("%s[!] 未检测到可用 IPv6，已跳过 IPv6%s\n", config.Yellow, config.NC)
	}
	return st
}

// largePacketPrecheck probes a 1200B SYN to Cloudflare; success means the path
// is not firewall-limited for large packets.
func (a *App) largePacketPrecheck(ctx context.Context) bool {
	ip, ok := iputil.ResolveFirstPublicIPv4(ctx, config.LargePacketPrecheckDomain)
	if !ok {
		return false
	}
	p, err := a.newProber("4", config.LargePacketPrecheckPackets, false, "1200")
	if err != nil {
		return false
	}
	defer p.Close()
	r := p.ProbeTarget(ctx, "Cloudflare", "预检", config.LargePacketPrecheckDomain, ip, 443)
	return r.Status == probe.StatusOK && r.LossPct < 100
}

// renderMain builds the CSV, prints all result sections and uploads the report.
func (a *App) renderMain(ctx context.Context, st mainState, res struct {
	cdn4, cdn6, large4, cernet, cernet2 []probe.Result
}, labels4, labels6, labelsLarge, labelsEdu4, labelsEdu6 map[string]string,
	intlResults []international.Result, speedResults *speedtest.Results) {

	full, short := nowReportTime()
	b := report.NewBuilder()
	addProbeRows := func(network, ipver string, results []probe.Result, labels map[string]string) {
		for _, r := range results {
			label := labelOr(labels, r.Province, r.ISP)
			b.AddProbe(network, ipver, r.Province, r.ISP, r.Host, r.IP, string(r.Status), r.Sent, r.Rcvd, r.LossPct, r.AvgRTT, label)
		}
	}
	if st.normalCDN {
		addProbeRows("三网", "IPv4", res.cdn4, labels4)
		addProbeRows("三网", "IPv6", res.cdn6, labels6)
	}
	if st.largeEnabled {
		addProbeRows("IPv4大包", "IPv4", res.large4, labelsLarge)
	}
	if st.testEdu {
		addProbeRows("CERNET", "IPv4", res.cernet, labelsEdu4)
		addProbeRows("CERNET2", "IPv6", res.cernet2, labelsEdu6)
	}
	if a.cfg.InternationalEnabled {
		appendInternationalCSV(b, intlResults)
	}
	if speedResults != nil {
		speedResults.CSVRows(b.AddRow)
	}
	csvPath := report.DefaultPath()
	_ = b.WriteFile(csvPath)

	a.print("\033[2J\033[H")
	a.print(render.Header())
	a.printf("  %s报告时间：%s%s\n\n", config.Dim, full, config.NC)

	if st.normalCDN {
		if st.ipv4Enabled {
			a.print(render.FamilyResults("IPv4", res.cdn4, labelFunc(labels4)))
		}
		if st.ipv6Enabled {
			a.print(render.FamilyResults("IPv6", res.cdn6, labelFunc(labels6)))
		}
	}
	if st.largeEnabled {
		a.print(render.LargePacketResults("IPv4大包回程质量(beta)", res.large4, labelFunc(labelsLarge), st.firewallLimited))
	}
	if st.testEdu {
		if st.ipv4Enabled && st.ipv6Enabled {
			a.print(render.EducationCombined(res.cernet, res.cernet2, labelFunc(labelsEdu4), labelFunc(labelsEdu6)))
		} else if st.ipv4Enabled {
			a.print(render.EducationResults("CERNET-IPv4", res.cernet, labelFunc(labelsEdu4)))
		} else if st.ipv6Enabled {
			a.print(render.EducationResults("CERNET2-IPv6", res.cernet2, labelFunc(labelsEdu6)))
		}
	}
	if a.cfg.InternationalEnabled {
		a.print(render.InternationalResults(intlResults))
	}
	if speedResults != nil {
		a.print(speedResults.Render())
	}

	if a.cfg.UploadReport {
		a.uploadReport(ctx, b.Bytes(), short)
	}
	a.print("\n")
}

// labelOr returns the route label for (prov,isp) or "Hidden".
func labelOr(labels map[string]string, prov, isp string) string {
	if labels != nil {
		if l := labels[routeKey(prov, isp)]; l != "" {
			return l
		}
	}
	return "Hidden"
}
