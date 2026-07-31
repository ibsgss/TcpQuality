package render

import (
	"fmt"
	"strings"
)

// RouteRow is one node's route-identification outcome for the --route table.
type RouteRow struct {
	Province string
	ISP      string
	Protocol string
	Status   string // OK / LIMIT / FAIL / ...
	Label    string
}

func routeColor(status, label string) string {
	switch {
	case status == "LIMIT":
		return yellow
	case status != "OK":
		return red
	case label == "Hidden" || label == "NoData":
		return yellow
	default:
		return green
	}
}

// RouteResults renders the --route backbone-line grid, grouped by protocol then
// province with 电信/联通/移动 columns.
func RouteResults(rows []RouteRow) string {
	var protoOrder []string
	protoSeen := map[string]bool{}
	var provOrder []string
	provSeen := map[string]bool{}
	cells := map[string]string{} // proto\x1fprov\x1fisp -> cell
	limitCount := 0

	for _, r := range rows {
		proto := strings.ToUpper(r.Protocol)
		label := r.Label
		if r.Status == "LIMIT" {
			label = "LIMIT"
		}
		if r.Status == "FAIL" && label == "" {
			label = "FAIL"
		}
		if !protoSeen[proto] {
			protoSeen[proto] = true
			protoOrder = append(protoOrder, proto)
		}
		if !provSeen[r.Province] {
			provSeen[r.Province] = true
			provOrder = append(provOrder, r.Province)
		}
		cells[proto+"\x1f"+r.Province+"\x1f"+r.ISP] = routeColor(r.Status, label) + LJust(label, 11) + nc
		if r.Status == "LIMIT" {
			limitCount++
		}
	}

	var b strings.Builder
	for _, proto := range protoOrder {
		fmt.Fprintf(&b, "  %s%s%s 回程线路%s %s(-- 电信 -- | -- 联通 -- | -- 移动 --)%s\n",
			bold, cyan, proto, nc, dim, nc)
		for _, prov := range provOrder {
			provPad := "    "
			if prov == "黑龙江" || prov == "内蒙古" {
				provPad = "  "
			}
			fmt.Fprintf(&b, "  %s%s%s%s  %s  %s  %s\n", cyan, prov, nc, provPad,
				routeCellOr(cells, proto, prov, "电信"),
				routeCellOr(cells, proto, prov, "联通"),
				routeCellOr(cells, proto, prov, "移动"))
		}
		b.WriteString("\n")
	}
	if limitCount > 0 {
		fmt.Fprintf(&b, "  %s[!] 检测到 %d 次线路识别受限。%s\n\n", yellow, limitCount, nc)
	}
	return b.String()
}

func routeCellOr(cells map[string]string, proto, prov, isp string) string {
	if c, ok := cells[proto+"\x1f"+prov+"\x1f"+isp]; ok {
		return c
	}
	return routeColor("FAIL", "") + LJust("", 11) + nc
}
