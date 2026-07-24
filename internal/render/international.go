package render

import (
	"fmt"
	"strings"

	"tcpquality/internal/international"
	"tcpquality/internal/probe"
)

const (
	intlNameW      = 24
	intlDomainW    = 32
	intlReachableW = 4
	intlLatencyW   = 10
	intlLossW      = 8
)

func intlLatencyColor(category string, v float64, ok bool) string {
	if !ok {
		return red
	}
	if category == "CDN" {
		switch {
		case v > 10:
			return red
		case v > 2:
			return yellow
		default:
			return green
		}
	}
	switch {
	case v > 150:
		return red
	case v > 50:
		return yellow
	default:
		return green
	}
}

func intlLossColor(loss float64, ok bool) string {
	if !ok || loss >= 100 {
		return red
	}
	if loss > 0 {
		return yellow
	}
	return green
}

func intlRow(r international.Result) string {
	ok := r.Status == probe.StatusOK && r.LossPct < 100
	mark := "x"
	markColor := red
	if ok {
		mark = "✓"
		markColor = green
	}
	latency := "-1ms"
	if ok {
		latency = fmt.Sprintf("%.3fms", r.AvgRTT)
	}
	lossText := fmt.Sprintf("%d%%", compactLoss(r.LossPct))
	return fmt.Sprintf("  %s  %s  %s%s%s  %s%s%s  %s%s%s\n",
		LJust(r.Name, intlNameW), LJust(r.Domain, intlDomainW),
		markColor, LJust(mark, intlReachableW), nc,
		intlLatencyColor(r.Category, r.AvgRTT, ok), RJust(latency, intlLatencyW), nc,
		intlLossColor(r.LossPct, ok), RJust(lossText, intlLossW), nc)
}

func intlHeader(title string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s\n", bold, cyan+title, nc)
	fmt.Fprintf(&b, "  %s%s  %s  %s  %s  %s%s\n", cyan,
		LJust("服务", intlNameW), LJust("域名", intlDomainW),
		LJust("可达", intlReachableW), RJust("延迟", intlLatencyW), RJust("重传", intlLossW), nc)
	fmt.Fprintf(&b, "  %s  %s  %s  %s  %s\n",
		sep(intlNameW), sep(intlDomainW), sep(intlReachableW), sep(intlLatencyW), sep(intlLossW))
	return b.String()
}

// InternationalResults renders the site and CDN international-connectivity tables.
func InternationalResults(results []international.Result) string {
	var sites, cdns []international.Result
	for _, r := range results {
		if r.Category == "网站" {
			sites = append(sites, r)
		} else {
			cdns = append(cdns, r)
		}
	}
	var b strings.Builder
	if len(sites) > 0 {
		b.WriteString(intlHeader("IPv4 常用网站国际互联"))
		for _, r := range sites {
			b.WriteString(intlRow(r))
		}
		fmt.Fprintf(&b, "  %s颜色: %s0-50ms 正常%s  %s50-150ms 一般%s  %s>150ms 异常，或不可达%s\n\n",
			dim, green, dim, yellow, dim, red, dim)
	}
	if len(cdns) > 0 {
		b.WriteString(intlHeader("IPv4 常用 CDN 国际互联"))
		for _, r := range cdns {
			b.WriteString(intlRow(r))
		}
		fmt.Fprintf(&b, "  %s颜色: %s0-2ms 正常%s  %s2-10ms 一般%s  %s>10ms 异常，或不可达%s\n\n",
			dim, green, dim, yellow, dim, red, dim)
	}
	return b.String()
}
