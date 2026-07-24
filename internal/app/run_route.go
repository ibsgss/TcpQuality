package app

import (
	"context"

	"tcpquality/internal/nodes"
	"tcpquality/internal/route"
)

// routeKey builds the (province, isp) lookup key used by the render summaries.
func routeKey(prov, isp string) string { return prov + "\x1f" + isp }

// collectRouteLabels traceroutes each node, batches a single Team Cymru lookup,
// then classifies every trace into a backbone label keyed by (province, isp).
func (a *App) collectRouteLabels(ctx context.Context, family, protocol string, list []nodes.Node, psize int, onDone func()) map[string]string {
	labels := map[string]string{}
	if len(list) == 0 {
		return labels
	}
	traces := make([]*route.TraceResult, len(list))
	runPool(len(list), a.cfg.Parallel, func(i int) {
		n := list[i]
		tr, _ := route.TraceWithRetry(ctx, family, protocol, n.IP, portOr(n.Port, 80), psize)
		traces[i] = tr
		if onDone != nil {
			onDone()
		}
	})

	asnMap, _ := route.QueryCymruASN(ctx, route.CollectHopIPs(traces))
	for i, n := range list {
		labels[routeKey(n.Province, n.ISP)] = route.LabelForTrace(traces[i], asnMap, n.ISP)
	}
	return labels
}

// labelFunc adapts a label map into a render.LabelFunc.
func labelFunc(labels map[string]string) func(prov, isp string) string {
	return func(prov, isp string) string {
		return labels[routeKey(prov, isp)]
	}
}
