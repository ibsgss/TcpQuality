package app

import (
	"context"
	"fmt"

	"tcpquality/internal/config"
	"tcpquality/internal/international"
	"tcpquality/internal/probe"
	"tcpquality/internal/render"
	"tcpquality/internal/report"
)

// newV4Prober builds an IPv4 prober with the given packet count.
func (a *App) newV4Prober(packets int) (*probe.Prober, error) {
	p, err := probe.NewProber("4")
	if err != nil {
		return nil, err
	}
	p.Packets = packets
	p.SizeOverride = a.cfg.PacketSizeOverride
	p.Debug = a.cfg.DebugMode
	return p, nil
}

func (a *App) runInternationalMode(ctx context.Context) error {
	p, err := a.newV4Prober(a.cfg.InternationalPackets)
	if err != nil {
		return err
	}
	defer p.Close()

	a.printf("%s  国际互联目标: %d  每目标发包: %d  并行: %d  端口: 443/tcp%s\n\n",
		config.Dim, international.TaskCount(), a.cfg.InternationalPackets, a.cfg.Parallel, config.NC)

	pc := a.newProgress("国际互联", international.TaskCount())
	results := international.RunAll(ctx, p, a.cfg.Parallel, pc.inc)
	pc.finish()

	full, short := nowReportTime()
	b := report.NewBuilder()
	appendInternationalCSV(b, results)
	csvPath := report.DefaultPath()
	_ = b.WriteFile(csvPath)

	a.print("\033[2J\033[H")
	a.print(render.Header())
	a.printf("  %s报告时间：%s%s\n\n", config.Dim, full, config.NC)
	a.print(render.InternationalResults(results))

	if a.cfg.UploadReport {
		a.uploadReport(ctx, b.Bytes(), short)
	}
	a.print("\n")
	return nil
}

func appendInternationalCSV(b *report.Builder, results []international.Result) {
	for _, r := range results {
		status := string(r.Status)
		b.AddRow("国际互联", "IPv4", r.Name, r.Category, r.Domain, r.IP, status,
			fmt.Sprintf("%d", r.Sent), fmt.Sprintf("%d", r.Rcvd),
			fmt.Sprintf("%.2f", r.LossPct), fmt.Sprintf("%.3f", r.AvgRTT), "TCP443")
	}
}

// uploadReport posts the CSV and prints the resulting link or a warning.
func (a *App) uploadReport(ctx context.Context, csv []byte, reportTime string) {
	res, err := report.Upload(ctx, a.cfg.ReportAPI, csv, reportTime)
	if err != nil {
		a.printf("  %s[!] SVG 报告上传失败，本地 CSV 已保留%s\n", config.Yellow, config.NC)
		return
	}
	a.printf("  %s报告链接：%s%s%s\n", config.White, config.Underline, res.URL, config.NC)
	a.printf("  %s今日使用次数：%d；总使用次数：%d。感谢使用 ibsgss 网络质量检测脚本！%s\n",
		config.Dim, res.TodayUses, res.TotalUses, config.NC)
}
