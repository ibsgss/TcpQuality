package render

import (
	"fmt"
	"strings"

	"tcpquality/internal/probe"
)

const eduCellW = routeW + 1 + latencyW + 1 + lossW // 25

func eduLabelCell(text string) string { return LJust(text, labelW) }

func eduCell(status probe.Status, loss, lat float64, label, fallback string) string {
	if label == "" {
		label = fallback
	}
	if status != probe.StatusOK {
		return white + RJust(label, routeW) + nc + " " + red + RJust("failed", latencyW) + nc + " " + red + RJust("failed", lossW) + nc
	}
	latency := latencyText(lat, loss)
	lossText := fmt.Sprintf("%d%%", compactLoss(loss))
	return white + RJust(label, routeW) + nc + " " +
		latencyColorSummary(lat, loss) + RJust(latency, latencyW) + nc + " " +
		lossColorSummary(loss) + RJust(lossText, lossW) + nc
}

// EducationCombined renders CERNET-IPv4 and CERNET2-IPv6 side by side.
func EducationCombined(v4, v6 []probe.Result, labelV4, labelV6 LabelFunc) string {
	z := [3]int{}
	y := [3]int{}
	h := [3]int{}
	count := func(gen int, results []probe.Result) {
		for _, r := range results {
			switch {
			case r.Status != probe.StatusOK:
				h[gen]++
			case int(r.LossPct) == 0:
				z[gen]++
			case int(r.LossPct) <= 20:
				y[gen]++
			default:
				h[gen]++
			}
		}
	}
	count(1, v4)
	count(2, v6)

	var order []string
	seen := map[string]bool{}
	cell := map[string]string{} // prov\x1fgen
	fill := func(gen int, results []probe.Result, label LabelFunc) {
		for _, r := range results {
			if !seen[r.Province] {
				seen[r.Province] = true
				order = append(order, r.Province)
			}
			lbl := ""
			if label != nil {
				lbl = label(r.Province, r.ISP)
			}
			cell[fmt.Sprintf("%s\x1f%d", r.Province, gen)] = eduCell(r.Status, r.LossPct, r.AvgRTT, lbl, "Hidden")
		}
	}
	fill(1, v4, labelV4)
	fill(2, v6, labelV6)

	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s教育网 CERNET-IPv4 和 CERNET2-IPv6 统计摘要%s\n", bold, cyan, nc)
	fmt.Fprintf(&b, "  CERNET-IPv4  %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n", green, z[1], nc, yellow, y[1], nc, red, h[1], nc)
	fmt.Fprintf(&b, "  CERNET2-IPv6 %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n\n", green, z[2], nc, yellow, y[2], nc, red, h[2], nc)
	fmt.Fprintf(&b, "  %s%s%s%s  %s%s%s %s/ %s%s%s\n", bold, cyan, eduLabelCell("教育网概览"), nc,
		cyan, Center("CERNET-IPv4", eduCellW), nc, white, cyan, Center("CERNET2-IPv6", eduCellW), nc)
	for _, prov := range order {
		fmt.Fprintf(&b, "  %s%s%s  %s %s/ %s\n", cyan, eduLabelCell(prov), nc,
			cellOrEdu(cell, prov, 1), white, cellOrEdu(cell, prov, 2))
	}
	fmt.Fprintf(&b, "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n",
		dim, green, dim, yellow, dim, red, dim)
	return b.String()
}

func cellOrEdu(cell map[string]string, prov string, gen int) string {
	if c, ok := cell[fmt.Sprintf("%s\x1f%d", prov, gen)]; ok {
		return c
	}
	return eduCell(probe.StatusFail, 100, 0, "", "Hidden")
}
