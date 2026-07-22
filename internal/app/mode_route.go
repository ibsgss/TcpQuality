package app

import (
	"context"
	"fmt"

	"tcpquality/internal/config"
	"tcpquality/internal/nodes"
	"tcpquality/internal/render"
	"tcpquality/internal/route"
)

func (a *App) fetchNodes(ctx context.Context, scope string) (*nodes.Set, error) {
	return nodes.Fetch(ctx, a.cfg.GetNodesURL, scope)
}

func (a *App) runRouteMode(ctx context.Context) error {
	a.stack = iputilDetect(ctx)
	full, _ := nowReportTime()
	a.printf("  %s报告时间：%s%s\n\n", config.Dim, full, config.NC)

	if !a.cfg.OnlyIPv6 {
		if err := a.runRouteFamily(ctx, "4"); err != nil {
			a.printf("  %s[!] IPv4 线路识别失败: %v%s\n", config.Yellow, err, config.NC)
		}
	}
	if !a.cfg.OnlyIPv4 {
		if err := a.runRouteFamily(ctx, "6"); err != nil {
			a.printf("  %s[!] IPv6 线路识别失败: %v%s\n", config.Yellow, err, config.NC)
		}
	}
	return nil
}

func (a *App) runRouteFamily(ctx context.Context, family string) error {
	if family == "6" && !a.stack.IPv6Work {
		a.printf("%s[!] 未检测到可用 IPv6，已跳过 IPv6 线路识别%s\n", config.Yellow, config.NC)
		return nil
	}
	if family == "4" && !a.stack.IPv4Work {
		a.printf("%s[!] 未检测到可用 IPv4，已跳过 IPv4 线路识别%s\n", config.Yellow, config.NC)
		return nil
	}
	set, err := a.fetchNodes(ctx, "v"+family)
	if err != nil {
		return err
	}
	list := a.filterNodes(set.CDN(family))
	if len(list) == 0 {
		return fmt.Errorf("指定省份没有可执行的线路检测任务")
	}

	protocols := []string{a.cfg.RouteProtocol}
	if a.cfg.RouteProtocol == "both" {
		protocols = []string{"tcp", "udp"}
	}

	a.printf("%s  IPv%s 三网回程线路识别%s\n", config.Cyan, family, config.NC)
	a.printf("%s  检测范围: %s  线路检测节点: %d  协议: %s  并行: %d%s\n\n",
		config.Dim, a.cfg.ProvinceFilterText(), len(list)*len(protocols), a.cfg.RouteProtocol, a.cfg.Parallel, config.NC)

	pc := a.newProgress("回程识别", len(list)*len(protocols))
	var rows []render.RouteRow
	for _, proto := range protocols {
		traces := make([]*route.TraceResult, len(list))
		runPool(len(list), a.cfg.Parallel, func(i int) {
			tr, _ := route.TraceWithRetry(ctx, family, proto, list[i].IP, portOr(list[i].Port, 80), 44)
			traces[i] = tr
			pc.inc()
		})
		asnMap, _ := route.QueryCymruASN(ctx, route.CollectHopIPs(traces))
		for i, n := range list {
			label := route.LabelForTrace(traces[i], asnMap, n.ISP)
			status := "OK"
			if traces[i] == nil || len(traces[i].PublicHopIPs()) == 0 {
				status = "FAIL"
			}
			rows = append(rows, render.RouteRow{Province: n.Province, ISP: n.ISP, Protocol: proto, Status: status, Label: label})
		}
	}
	pc.finish()
	a.print("\n")
	a.print(render.RouteResults(rows))
	return nil
}
