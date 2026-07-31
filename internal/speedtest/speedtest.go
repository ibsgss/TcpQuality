// Package speedtest runs the single-thread download/upload speedtest against
// the three Chinese carriers in each supported TOS region (via the tosutil
// backend) plus an AppleCDN reference test, and renders/serializes the results.
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

// AppleLabel is the row label for the AppleCDN reference test.
const AppleLabel = "AppleCDN"

// Group is one geographic test group; every group runs unthrottled.
type Group struct {
	Label  string // 北京 / 上海 / 广东
	Region string // cn-beijing / cn-shanghai / cn-guangzhou
}

// allGroups is the default group set when no province filter narrows it.
var allGroups = []Group{
	{"北京", "cn-beijing"},
	{"上海", "cn-shanghai"},
	{"广东", "cn-guangzhou"},
}

// Groups returns the test groups for the active province filter. Provinces
// without a speedtest region are ignored; when none of the selected provinces
// is supported every group runs, mirroring speedtest_group_specs.
func Groups(selectedProvinces []string) []Group {
	if len(selectedProvinces) == 0 {
		return allGroups
	}
	selected := map[string]bool{}
	for _, p := range selectedProvinces {
		selected[p] = true
	}
	var out []Group
	for _, g := range allGroups {
		if selected[g.Label] {
			out = append(out, g)
		}
	}
	if len(out) == 0 {
		return allGroups
	}
	return out
}

// RegionTitle maps a TOS region to its display province.
func RegionTitle(region string) string {
	switch region {
	case "cn-shanghai":
		return "上海"
	case "cn-guangzhou":
		return "广东"
	default:
		return "北京"
	}
}

// CarrierResult holds one endpoint's measured values. Speed fields are decimal
// strings in Mbps, the literal "failed", or "-" when the test was skipped.
// Timing fields are integer milliseconds as strings, or "-".
type CarrierResult struct {
	Upload   string
	Retrans  string
	Download string
	ServerID string
	City     string

	UploadConnectMs   string
	UploadTLSMs       string
	DownloadConnectMs string
	DownloadTLSMs     string
}

// newFailedResult returns an all-failed result carrying the endpoint identity.
func newFailedResult(serverID, city string) CarrierResult {
	return CarrierResult{
		Upload: "failed", Retrans: "failed", Download: "failed",
		ServerID: serverID, City: city,
		UploadConnectMs: "-", UploadTLSMs: "-", DownloadConnectMs: "-", DownloadTLSMs: "-",
	}
}

// newSkippedResult returns a placeholder for a test that never ran.
func newSkippedResult(serverID, city string) CarrierResult {
	return CarrierResult{
		Upload: "-", Retrans: "-", Download: "-",
		ServerID: serverID, City: city,
		UploadConnectMs: "-", UploadTLSMs: "-", DownloadConnectMs: "-", DownloadTLSMs: "-",
	}
}

// Failed reports whether both directions failed.
func (c CarrierResult) Failed() bool {
	return !valid(c.Upload) && !valid(c.Download)
}

// Skipped reports whether the endpoint was never tested.
func (c CarrierResult) Skipped() bool {
	return c.Upload == "-" && c.Download == "-"
}

func valid(v string) bool { return v != "failed" && v != "" && v != "-" }

// Row is one group's results: three carriers, or two AppleCDN families.
type Row struct {
	Label   string
	Apple   bool
	Entries []CarrierResult
}

// TCPConfig captures the kernel TCP tuning that shaped the measurement.
type TCPConfig struct {
	CongestionControl string
	Qdisc             string
	Rmem              string
	Wmem              string
	RecvWindowBytes   string
	SendWindowBytes   string
	WindowScaling     string
	ModerateRcvbuf    string
}

// Results is the full speedtest outcome.
type Results struct {
	Rows      []Row
	TCPConfig TCPConfig

	// RankEligible reports whether the anti-cheat byte counters corroborated
	// every measurement; when false the rank session must be discarded.
	RankEligible bool
	// RankDisabledReason explains a false RankEligible.
	RankDisabledReason string
}

// FailedResults returns an all-failed Results for the given groups.
func FailedResults(groups []Group, applecdn bool) *Results {
	r := &Results{RankEligible: false, RankDisabledReason: "speedtest_not_performed"}
	for _, g := range groups {
		row := Row{Label: g.Label, Entries: make([]CarrierResult, len(Carriers))}
		for i := range row.Entries {
			row.Entries[i] = newFailedResult("", "")
		}
		r.Rows = append(r.Rows, row)
	}
	if applecdn {
		r.Rows = append(r.Rows, Row{
			Label: AppleLabel,
			Apple: true,
			Entries: []CarrierResult{
				newFailedResult(appleHost, "Apple IPv4"),
				newFailedResult(appleHost, "Apple IPv6"),
			},
		})
	}
	return r
}

// ---- rendering ----

func speedText(v string) string {
	switch v {
	case "failed":
		return "failed"
	case "-", "":
		return "-"
	}
	return v + "Mbps"
}

// speedColor picks the color for a speed. Unthrottled groups (every group with
// a non-"NMbps" label) use absolute thresholds; throttled labels compare against
// the target rate.
func speedColor(value, label string) string {
	if value == "-" {
		return config.Dim
	}
	if value == "failed" {
		return config.Red
	}
	f, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return config.Red
	}
	if label == "不限" || !strings.HasSuffix(label, "Mbps") {
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
	if value == "-" {
		return config.Dim
	}
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

// halfLatency renders half of a handshake cost, which approximates one-way
// latency (mirrors speedtest_latency_text).
func halfLatency(value string) (int, bool) {
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 {
		return 0, false
	}
	return int(float64(n)/2 + 0.5), true
}

func latencyText(value string) string {
	ms, ok := halfLatency(value)
	if !ok {
		return "-"
	}
	return fmt.Sprintf("%dms", ms)
}

func latencyColor(value string) string {
	if value == "-" {
		return config.Dim
	}
	ms, ok := halfLatency(value)
	if !ok {
		return config.Red
	}
	switch {
	case ms > 240:
		return config.Red
	case ms > 150:
		return config.Yellow
	default:
		return config.Green
	}
}

const groupHeaderWidth = 82

func headerCells(cells ...[2]string) string {
	var b strings.Builder
	for i, c := range cells {
		if i > 0 {
			b.WriteString("  ")
		}
		w, _ := strconv.Atoi(c[1])
		fmt.Fprintf(&b, "%s%s%s", config.Cyan, render.RJust(c[0], w), config.NC)
	}
	return b.String()
}

func groupHeader(label string) string {
	title := label
	switch {
	case label == "不限":
		title = "不限速"
	case strings.HasSuffix(label, "Mbps"):
		title = "限速 " + label
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s\n", config.Cyan, render.Center(title, groupHeaderWidth), config.NC)
	fmt.Fprintf(&b, "  %s\n", headerCells(
		[2]string{"地区", "12"}, [2]string{"回程重传", "10"},
		[2]string{"回程速度", "12"}, [2]string{"去程速度", "12"},
		[2]string{"回程延迟", "10"}, [2]string{"去程延迟", "10"}))
	return b.String()
}

func appleHeader() string {
	var b strings.Builder
	fmt.Fprintf(&b, "  %s%s%s\n", config.Cyan, render.Center(AppleLabel, groupHeaderWidth), config.NC)
	fmt.Fprintf(&b, "  %s\n", headerCells(
		[2]string{"名称", "12"}, [2]string{"下载重传", "10"},
		[2]string{"下载速度", "12"}, [2]string{"上传速度", "12"},
		[2]string{"下载延迟", "10"}, [2]string{"上传延迟", "10"}))
	return b.String()
}

// cell renders one colored, right-justified column.
func cell(color, text string, width int) string {
	return color + render.RJust(text, width) + config.NC
}

// carrierTitle names the row: the measured city plus the carrier, or a failure
// marker when no endpoint could be selected.
func carrierTitle(carrier string, r CarrierResult) string {
	if r.City == "" {
		return carrier + "失败"
	}
	return r.City + carrier
}

// Render produces the full speedtest results block.
func (r *Results) Render() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s单线程测速%s\n\n", config.Bold, config.Cyan, config.NC)
	for _, row := range r.Rows {
		if row.Apple {
			b.WriteString(appleHeader())
			for _, e := range row.Entries {
				name := e.City
				if name == "" {
					name = AppleLabel
				}
				fmt.Fprintf(&b, "  %s  %s  %s  %s  %s  %s\n",
					cell(config.Cyan, name, 12),
					cell(retransColor(e.Retrans), e.Retrans, 10),
					cell(speedColor(e.Download, row.Label), speedText(e.Download), 12),
					cell(speedColor(e.Upload, row.Label), speedText(e.Upload), 12),
					cell(latencyColor(e.DownloadTLSMs), latencyText(e.DownloadTLSMs), 10),
					cell(latencyColor(e.UploadTLSMs), latencyText(e.UploadTLSMs), 10))
			}
			b.WriteString("\n")
			continue
		}
		b.WriteString(groupHeader(row.Label))
		for i, e := range row.Entries {
			carrier := "?"
			if i < len(Carriers) {
				carrier = Carriers[i]
			}
			fmt.Fprintf(&b, "  %s  %s  %s  %s  %s  %s\n",
				cell(config.Cyan, carrierTitle(carrier, e), 12),
				cell(retransColor(e.Retrans), e.Retrans, 10),
				cell(speedColor(e.Upload, row.Label), speedText(e.Upload), 12),
				cell(speedColor(e.Download, row.Label), speedText(e.Download), 12),
				cell(latencyColor(e.UploadTLSMs), latencyText(e.UploadTLSMs), 10),
				cell(latencyColor(e.DownloadTLSMs), latencyText(e.DownloadTLSMs), 10))
		}
		b.WriteString("\n")
	}
	fmt.Fprintf(&b, "  %s注：代理速度由回程速度+下载速度的短板决定。%s\n", config.Dim, config.NC)
	return b.String()
}

// csvNetwork is the 网络 column value for speedtest rows.
const csvNetwork = "三网单线程速度"

func dashOr(v string) string {
	if v == "" {
		return "-"
	}
	return v
}

// CSVRows appends speedtest rows to the given AddRow-like sink, mirroring
// append_speedtest_csv.
func (r *Results) CSVRows(add func(fields ...string)) {
	for _, row := range r.Rows {
		for i, e := range row.Entries {
			name := e.City
			if row.Apple {
				if name == "" {
					name = AppleLabel
				}
			} else if i < len(Carriers) {
				name = Carriers[i]
			}
			city := e.City
			if row.Apple && city == "" {
				city = AppleLabel
			}

			status, serverID := "OK", e.ServerID
			switch {
			case e.Skipped():
				status = "SKIP"
				if serverID == "" {
					serverID = appleHost
				}
			case e.Upload == "failed" || e.Download == "failed":
				status, serverID = "FAIL", ""
			}
			add(csvNetwork, row.Label, name, city, serverID, "", status,
				e.Upload, e.Retrans, e.Download, "", "",
				dashOr(e.UploadConnectMs), dashOr(e.UploadTLSMs),
				dashOr(e.DownloadConnectMs), dashOr(e.DownloadTLSMs))
		}
	}
	r.appendTCPConfigCSV(add)
}

// appendTCPConfigCSV records the kernel TCP tuning alongside the measurements.
func (r *Results) appendTCPConfigCSV(add func(fields ...string)) {
	c := r.TCPConfig
	add("三网单线程配置", "TCP", c.CongestionControl, c.Qdisc, "", "", "OK",
		c.Rmem, c.Wmem, c.RecvWindowBytes, c.SendWindowBytes,
		c.WindowScaling, c.ModerateRcvbuf, "")
}
