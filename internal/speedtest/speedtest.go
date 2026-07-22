// Package speedtest runs the staged single-thread download/upload speedtest
// against the three Chinese carriers (via the tosutil backend + tc/ifb rate
// limiting on Linux) and renders/serializes the results.
package speedtest

import (
	"fmt"
	"strconv"
	"strings"

	"tcpquality/internal/config"
	"tcpquality/internal/render"
)

// Carriers are the three mobile carriers in fixed display order.
var Carriers = []string{"电信", "联通", "移动"}

// Rates are the staged rate-limit tiers (Mbps values plus "unlimited").
var Rates = []string{"10", "200", "unlimited"}

// CarrierResult holds one carrier's measured values for a rate tier. Speed
// fields are decimal strings in Mbps or the literal "failed".
type CarrierResult struct {
	Upload   string
	Retrans  string
	Download string
}

// Failed reports whether both directions failed.
func (c CarrierResult) Failed() bool {
	return !valid(c.Upload) && !valid(c.Download)
}

func valid(v string) bool { return v != "failed" && v != "" }

// RateRow is one rate tier's results across the three carriers.
type RateRow struct {
	Label    string // 不限 / 10Mbps / 200Mbps
	Carriers [3]CarrierResult
}

// Selected records the chosen server id/city for a carrier.
type Selected struct {
	ID   string
	City string
}

// Results is the full speedtest outcome.
type Results struct {
	Rows     []RateRow
	Selected [3]Selected
}

// rateLabel converts a raw rate value to its display label.
func rateLabel(rate string) string {
	if rate == "unlimited" {
		return "不限"
	}
	return rate + "Mbps"
}

// FailedResults returns an all-failed Results for the standard rate tiers.
func FailedResults() *Results {
	r := &Results{}
	for _, rate := range Rates {
		row := RateRow{Label: rateLabel(rate)}
		for i := range row.Carriers {
			row.Carriers[i] = CarrierResult{"failed", "failed", "failed"}
		}
		r.Rows = append(r.Rows, row)
	}
	return r
}

// ---- rendering ----

func speedText(v string) string {
	if v == "failed" {
		return "failed"
	}
	return v + "Mbps"
}

func speedColor(value, label string) string {
	if value == "failed" {
		return config.Red
	}
	f, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return config.Red
	}
	if label == "不限" {
		switch {
		case f <= 20:
			return config.Red
		case f <= 150:
			return config.Yellow
		default:
			return config.Green
		}
	}
	target, _ := strconv.ParseFloat(strings.TrimSuffix(label, "Mbps"), 64)
	switch {
	case f >= target*0.8:
		return config.Green
	case f >= target*0.6:
		return config.Yellow
	default:
		return config.Red
	}
}

func retransColor(value string) string {
	if value == "failed" {
		return config.Red
	}
	n, err := strconv.Atoi(value)
	if err != nil || n > 999 {
		return config.Red
	}
	if n >= 100 {
		return config.Yellow
	}
	return config.Green
}

func carrierTitle(carrier string, sel Selected) string {
	if sel.ID != "" {
		return sel.City + carrier
	}
	return carrier + "失败"
}

func groupHeader(label string) string {
	title := "限速 " + label
	if label == "不限" {
		title = "不限速"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s\n", config.Cyan, render.Center(title, 54), config.NC)
	fmt.Fprintf(&b, "  %s%s%s  %s%s%s  %s%s%s  %s%s%s\n",
		config.Cyan, render.RJust("地区", 12), config.NC,
		config.Cyan, render.RJust("回程重传", 10), config.NC,
		config.Cyan, render.RJust("回程速度", 12), config.NC,
		config.Cyan, render.RJust("去程速度", 12), config.NC)
	return b.String()
}

// Render produces the full speedtest results block.
func (r *Results) Render() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s国内三网单线程测速%s\n\n", config.Bold, config.Cyan, config.NC)
	for _, row := range r.Rows {
		b.WriteString(groupHeader(row.Label))
		for i, cr := range row.Carriers {
			region := carrierTitle(Carriers[i], r.Selected[i])
			fmt.Fprintf(&b, "  %s%s%s  %s%s%s  %s%s%s  %s%s%s\n",
				config.Cyan, render.RJust(region, 12), config.NC,
				retransColor(cr.Retrans), render.RJust(cr.Retrans, 10), config.NC,
				speedColor(cr.Upload, row.Label), render.RJust(speedText(cr.Upload), 12), config.NC,
				speedColor(cr.Download, row.Label), render.RJust(speedText(cr.Download), 12), config.NC)
		}
		b.WriteString("\n")
	}
	return b.String()
}

// CSVRows appends speedtest rows to the given AddRow-like sink, mirroring
// append_speedtest_csv.
func (r *Results) CSVRows(add func(fields ...string)) {
	for _, row := range r.Rows {
		for i, cr := range row.Carriers {
			carrier := Carriers[i]
			city := r.Selected[i].City
			if cr.Upload == "failed" {
				add("国内三网单线程测速", row.Label, carrier, city, "", "", "FAIL", cr.Upload, cr.Retrans, cr.Download, "", "")
			} else {
				add("国内三网单线程测速", row.Label, carrier, city, r.Selected[i].ID, "", "OK", cr.Upload, cr.Retrans, cr.Download, "", "")
			}
		}
	}
}
