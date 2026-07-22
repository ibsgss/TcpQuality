package render

import (
	"fmt"
	"strings"

	"tcpquality/internal/probe"
)

const (
	labelW       = 10
	routeW       = 11
	latencyW     = 6
	lossW        = 6
	summaryCellW = routeW + 1 + latencyW + 1 + lossW // 25
)

// LabelFunc resolves a backbone route label for a (province, isp) pair. An empty
// string means "no label" (the ISP name is used as a fallback).
type LabelFunc func(prov, isp string) string

// StatCounts tallies zero-loss / 1-20% / >20%(or failed) buckets.
func StatCounts(results []probe.Result) (zero, mid, high int) {
	for _, r := range results {
		if r.Status != probe.StatusOK {
			high++
			continue
		}
		v := int(r.LossPct)
		switch {
		case v == 0:
			zero++
		case v <= 20:
			mid++
		default:
			high++
		}
	}
	return
}

func formatSummaryCell(label, latency, loss, latColor, lossColor string) string {
	return white + RJust(label, routeW) + nc + " " +
		latColor + RJust(latency, latencyW) + nc + " " +
		lossColor + RJust(loss, lossW) + nc
}

func summaryCell(status probe.Status, loss, lat float64, label string) string {
	if label == "" {
		label = "Hidden"
	}
	switch status {
	case probe.StatusSkip:
		return formatSummaryCell(label, "-", "-", red, red)
	case probe.StatusOK:
		latency := latencyText(lat, loss)
		lossText := fmt.Sprintf("%d%%", compactLoss(loss))
		return formatSummaryCell(label, latency, lossText, latencyColorSummary(lat, loss), lossColorSummary(loss))
	default:
		return formatSummaryCell(label, "failed", "failed", red, red)
	}
}

func labelCell(text string) string { return LJust(text, labelW) }

func headerAlignLatency(text string) string {
	left := routeW + 1 + latencyW - DisplayWidth(text)
	right := summaryCellW - routeW - 1 - latencyW
	return spaces(left) + text + spaces(right)
}

// providerSummary renders the 三网概览 grid (电信/联通/移动 columns by province).
func providerSummary(results []probe.Result, label LabelFunc) string {
	var order []string
	seen := map[string]bool{}
	cells := map[string]string{} // prov\x1fisp -> rendered cell
	for _, r := range results {
		if !seen[r.Province] {
			seen[r.Province] = true
			order = append(order, r.Province)
		}
		lbl := r.ISP
		if label != nil {
			if l := label(r.Province, r.ISP); l != "" {
				lbl = l
			}
		}
		cells[r.Province+"\x1f"+r.ISP] = summaryCell(r.Status, r.LossPct, r.AvgRTT, lbl)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s%s  %s%s%s %s/ %s%s%s %s/ %s%s%s\n",
		bold, cyan, labelCell("三网概览"), nc,
		cyan, headerAlignLatency("电信"), nc, white,
		cyan, headerAlignLatency("联通"), nc, white,
		cyan, headerAlignLatency("移动"), nc)
	for _, prov := range order {
		fmt.Fprintf(&b, "  %s%s%s  %s %s/ %s %s/ %s\n",
			cyan, labelCell(prov), nc,
			cellOr(cells, prov, "电信"), white,
			cellOr(cells, prov, "联通"), white,
			cellOr(cells, prov, "移动"))
	}
	fmt.Fprintf(&b, "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n",
		dim, green, dim, yellow, dim, red, dim)
	return b.String()
}

func cellOr(cells map[string]string, prov, isp string) string {
	if c, ok := cells[prov+"\x1f"+isp]; ok {
		return c
	}
	return summaryCell(probe.StatusFail, 100, 0, "Hidden")
}

// FamilyResults renders the per-family statistics summary plus provider grid.
func FamilyResults(family string, results []probe.Result, label LabelFunc) string {
	z, y, h := StatCounts(results)
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s 统计摘要%s  ", bold, cyan, family, nc)
	fmt.Fprintf(&b, "%s零丢包:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n\n", green, z, nc, yellow, y, nc, red, h, nc)
	b.WriteString(providerSummary(results, label))
	return b.String()
}

// LargePacketResults renders the IPv4 large-packet backbone-quality summary.
func LargePacketResults(title string, results []probe.Result, label LabelFunc, firewallLimited bool) string {
	var z, y, h int
	for _, r := range results {
		switch {
		case r.Status == probe.StatusSkip, r.Status != probe.StatusOK:
			h++
		case int(r.LossPct) == 0:
			z++
		case int(r.LossPct) <= 20:
			y++
		default:
			h++
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s 统计摘要%s\n", bold, cyan, title, nc)
	fmt.Fprintf(&b, "  %s零重传:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n", green, z, nc, yellow, y, nc, red, h, nc)
	if firewallLimited {
		fmt.Fprintf(&b, "  %s由于服务商防火墙限制，延迟和丢包无法探测%s\n", red, nc)
	}
	b.WriteString("\n")
	b.WriteString(providerSummary(results, label))
	return b.String()
}

// EducationResults renders a single-generation CERNET province overview.
func EducationResults(title string, results []probe.Result, label LabelFunc) string {
	z, y, h := StatCounts(results)
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s 统计摘要%s  ", bold, cyan, title, nc)
	fmt.Fprintf(&b, "%s零丢包:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n\n", green, z, nc, yellow, y, nc, red, h, nc)
	fmt.Fprintf(&b, "  %s%s省份概览%s\n", bold, cyan, nc)
	for _, r := range results {
		lbl := ""
		if label != nil {
			lbl = label(r.Province, r.ISP)
		}
		if lbl == "" {
			lbl = title
		}
		var cell string
		if r.Status != probe.StatusOK {
			cell = white + RJust(lbl, routeW) + nc + " " + red + RJust("failed", latencyW) + nc + " " + red + RJust("failed", lossW) + nc
		} else {
			cell = white + RJust(lbl, routeW) + nc + " " +
				latencyColorSummary(r.AvgRTT, r.LossPct) + latencyText(r.AvgRTT, r.LossPct) + nc + " " +
				lossColorSummary(r.LossPct) + RJust(fmt.Sprintf("%d%%", compactLoss(r.LossPct)), lossW) + nc
		}
		provPad := "    "
		if r.Province == "黑龙江" || r.Province == "内蒙古" {
			provPad = "  "
		}
		fmt.Fprintf(&b, "  %s%s%s%s  %s\n", cyan, r.Province, nc, provPad, cell)
	}
	fmt.Fprintf(&b, "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n",
		dim, green, dim, yellow, dim, red, dim)
	return b.String()
}
