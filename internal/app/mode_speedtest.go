package app

import (
	"context"

	"tcpquality/internal/config"
	"tcpquality/internal/nodes"
	"tcpquality/internal/render"
	"tcpquality/internal/report"
	"tcpquality/internal/speedtest"
)

// loadTOSNodes fetches the tosutil entry IPs (best-effort).
func (a *App) loadTOSNodes(ctx context.Context) []nodes.SpeedtestNode {
	set, err := nodes.Fetch(ctx, a.cfg.GetNodesURL, "tos")
	if err != nil || set == nil {
		return nil
	}
	return set.TOS
}

// speedtestOptions builds the run options from config plus the remote node feed.
func (a *App) speedtestOptions(ctx context.Context) speedtest.Options {
	opts := speedtest.DefaultOptions()
	opts.Debug = a.cfg.DebugMode
	opts.Groups = speedtest.Groups(a.cfg.SelectedProvinces())
	opts.ApplyNodes(a.loadTOSNodes(ctx))
	return opts
}

// runSpeedtest opens a rank session, runs the test and returns the results plus
// the session to attach to the report upload (nil when not rank-eligible).
func (a *App) runSpeedtest(ctx context.Context, label string) (*speedtest.Results, *report.RankSession) {
	opts := a.speedtestOptions(ctx)

	// The rank session must be opened before any measurement so the server can
	// bound the window the results are claimed to come from.
	session, err := report.RequestRankSession(ctx, a.cfg.RankSessionAPI, a.stack.IPv4, a.stack.IPv6)
	if err != nil {
		session = nil
		a.rankDisabledReason = report.ReasonSessionRequestFailed
		if a.cfg.DebugMode {
			a.printf("  %s[debug] rank session 获取失败：%v，本次报告不会进入排名%s\n", config.Dim, err, config.NC)
		}
	}

	pc := a.newProgress(label, opts.StepCount())
	results, err := speedtest.Run(ctx, opts, func(done, total int) {
		pc.total = total
		pc.setDone(done)
	})
	pc.finish()
	if err != nil {
		results = speedtest.FailedResults(opts.Groups, opts.AppleCDN)
		a.printf("  %s[!] 测速失败: %v%s\n", config.Yellow, err, config.NC)
	}

	if !results.RankEligible {
		session = nil
		if results.RankDisabledReason != "" {
			a.rankDisabledReason = results.RankDisabledReason
		}
		if a.cfg.DebugMode && a.rankDisabledReason != "" {
			a.printf("  %s[debug] 排名凭证已清除：%s%s\n", config.Dim, a.rankDisabledReason, config.NC)
		}
	}
	return results, session
}

func (a *App) runSpeedtestMode(ctx context.Context) error {
	a.stack = iputilDetect(ctx)

	a.printf("%s%s单线程测速%s\n\n", config.Bold, config.Cyan, config.NC)
	results, session := a.runSpeedtest(ctx, "测速进度")

	full, short := nowReportTime()
	b := report.NewBuilder()
	results.CSVRows(b.AddRow)
	csvPath := report.DefaultPath()
	_ = b.WriteFile(csvPath)

	a.print("\033[2J\033[H")
	a.print(render.Header())
	a.printf("  %s报告时间：%s%s\n\n", config.Dim, full, config.NC)
	a.print(results.Render())

	if a.cfg.UploadReport {
		a.uploadReport(ctx, b.Bytes(), short, session)
	}
	a.print("\n")
	return nil
}
