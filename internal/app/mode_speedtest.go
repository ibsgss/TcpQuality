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

func (a *App) runSpeedtestMode(ctx context.Context) error {
	tos := a.loadTOSNodes(ctx)
	opts := speedtest.DefaultOptions()
	opts.Debug = a.cfg.DebugMode

	a.printf("%s%s国内三网单线程测速%s\n\n", config.Bold, config.Cyan, config.NC)
	pc := a.newProgress("测速进度", len(speedtest.Rates)*len(speedtest.Carriers))
	results, err := speedtest.Run(ctx, opts, tos, func(done, total int) {
		pc.total = total
		pc.setDone(done)
	})
	pc.finish()
	if err != nil {
		results = speedtest.FailedResults()
		a.printf("  %s[!] 测速失败: %v%s\n", config.Yellow, err, config.NC)
	}

	full, short := nowReportTime()
	b := report.NewBuilder()
	results.CSVRows(b.AddRow)

	a.print("\033[2J\033[H")
	a.print(render.Header())
	a.printf("  %s报告时间：%s%s\n\n", config.Dim, full, config.NC)
	a.print(results.Render())

	if a.cfg.UploadReport {
		a.uploadReport(ctx, b.Bytes(), short)
	}
	a.print("\n")
	return nil
}
