// Package config holds runtime configuration, constants, command-line parsing
// and province filtering for the TcpQuality Go port.
package config

import (
	"os"
	"strconv"
	"strings"
)

// Fixed limits and defaults mirroring the original script.
const (
	DefaultPackets       = 25
	MaxPackets           = 600
	DefaultParallel      = 16
	MaxParallel          = 31
	MaxAutoParallel      = 93
	InternationalPackets = 15

	LargePacketPrecheckDomain  = "www.cloudflare.com"
	LargePacketPrecheckPackets = 20
	LargePacketPrecheckSize    = 1200
	// LargePacketPrecheckMaxLoss is the loss percentage at or above which the
	// path is treated as firewall-limited for large packets.
	LargePacketPrecheckMaxLoss = 80.0

	DefaultGetNodesURL = "https://tcpquality.ibsgss.uk/getNodes"
	DefaultReportAPI   = "https://tcpquality.ibsgss.uk/generate"
)

// Packet size pools used when a size is not explicitly forced.
var (
	PacketSizes           = []int{40, 80, 160, 320, 640, 1200}
	LargePacketSmallSizes = []int{120, 240, 480}
	LargePacketBigSizes   = []int{900, 950, 1000, 1050, 1100, 1150, 1200, 1200, 900}
)

// Config captures every tunable the CLI exposes plus derived selection state.
type Config struct {
	Packets       int
	CountExplicit bool
	// PacketSizeOverride is the forced IP packet length in bytes. "0" means a
	// standard, payload-free SYN. An empty string means "not forced" (used
	// internally by the large-packet mode).
	PacketSizeOverride string
	Parallel           int
	// ParallelExplicit records whether -p/--parallel was given; when it was not,
	// ApplyAutoParallel derives the value from total system memory.
	ParallelExplicit bool

	OnlyIPv4   bool
	OnlyIPv6   bool
	OnlyLarge  bool
	TestCernet bool
	TestAll    bool
	// IncludeDefaultRoute (TCPQUALITY_INCLUDE_DEFAULT_ROUTE) keeps the normal
	// three-carrier CDN section alongside --cernet instead of replacing it.
	IncludeDefaultRoute bool

	RouteMode     bool
	RouteProtocol string

	SpeedtestEnabled bool
	SpeedtestOnly    bool

	InternationalEnabled bool
	InternationalOnly    bool
	IntlRequested        bool
	InternationalPackets int

	UploadReport bool
	// ReportUploadForcedOff records an explicit --no-rank-upload so later flags
	// (notably --intl) cannot re-enable uploading.
	ReportUploadForcedOff bool
	DebugMode             bool

	// selectedOrder preserves the order provinces were requested in; selected
	// is the membership set. Empty means "all provinces".
	selectedOrder []string
	selected      map[string]bool

	GetNodesURL    string
	ReportAPI      string
	RankSessionAPI string
}

// ReportAPIBase strips the trailing /generate from the report API, giving the
// base used for rank sessions and debug-bundle endpoints.
func (c *Config) ReportAPIBase() string {
	return strings.TrimSuffix(c.ReportAPI, "/generate")
}

// New returns a Config populated with the same defaults as the bash script.
func New() *Config {
	c := &Config{
		Packets:              DefaultPackets,
		PacketSizeOverride:   "0",
		Parallel:             DefaultParallel,
		RouteProtocol:        "tcp",
		InternationalPackets: InternationalPackets,
		UploadReport:         true,
		selected:             map[string]bool{},
		GetNodesURL:          DefaultGetNodesURL,
		ReportAPI:            DefaultReportAPI,
	}
	if v := os.Getenv("GET_NODES_URL"); v != "" {
		c.GetNodesURL = v
	}
	if v := os.Getenv("TCPQUALITY_REPORT_API"); v != "" {
		c.ReportAPI = v
	}
	c.RankSessionAPI = c.ReportAPIBase() + "/rank/session"
	if v := os.Getenv("TCPQUALITY_RANK_SESSION_API"); v != "" {
		c.RankSessionAPI = v
	}
	if v := os.Getenv("TCPQUALITY_INCLUDE_DEFAULT_ROUTE"); v == "1" {
		c.IncludeDefaultRoute = true
	}
	return c
}

// ApplyAutoParallel derives the parallelism from total system memory unless the
// user passed -p/--parallel, mirroring apply_auto_parallel.
func (c *Config) ApplyAutoParallel() {
	if c.ParallelExplicit {
		return
	}
	c.Parallel = AutoParallel(TotalMemoryMB())
}

// AutoParallel maps total memory (MiB) to a probe parallelism, clamped to
// [1, MaxAutoParallel]: roughly one worker per 48 MiB.
func AutoParallel(memMB int) int {
	if memMB <= 0 {
		memMB = 512
	}
	p := (memMB + 47) / 48
	if p < 1 {
		p = 1
	}
	if p > MaxAutoParallel {
		p = MaxAutoParallel
	}
	return p
}

// TotalMemoryMB reads MemTotal from /proc/meminfo, falling back to 512 when it
// is unavailable (non-Linux hosts included).
func TotalMemoryMB() int {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 512
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			break
		}
		kb, err := strconv.Atoi(fields[1])
		if err != nil || kb <= 0 {
			break
		}
		return kb / 1024
	}
	return 512
}

// AddProvinceFilter records a province (given by code or name). Returns false
// for an unknown code, matching add_province_filter.
func (c *Config) AddProvinceFilter(code string) bool {
	name, ok := ProvinceFromCode(code)
	if !ok {
		return false
	}
	if !c.selected[name] {
		c.selected[name] = true
		c.selectedOrder = append(c.selectedOrder, name)
	}
	return true
}

// ProvinceSelected reports whether a province passes the filter. When no
// provinces were selected every province passes.
func (c *Config) ProvinceSelected(province string) bool {
	if len(c.selected) == 0 {
		return true
	}
	return c.selected[province]
}

// SelectedProvinces returns the requested provinces in request order; empty
// means "all provinces".
func (c *Config) SelectedProvinces() []string { return c.selectedOrder }

// HasProvinceFilter reports whether any province filter is active.
func (c *Config) HasProvinceFilter() bool {
	return len(c.selected) > 0
}

// ProvinceFilterText renders the active filter for display ("全国" when empty).
func (c *Config) ProvinceFilterText() string {
	if len(c.selectedOrder) == 0 {
		return "全国"
	}
	return strings.Join(c.selectedOrder, "、")
}

// NodeScope returns the getNodes scope string implied by the current flags.
func (c *Config) NodeScope() string {
	switch {
	case c.TestAll, c.IncludeDefaultRoute && c.TestCernet:
		return "all"
	case c.TestCernet:
		return "cernet"
	case c.OnlyIPv4 && !c.OnlyIPv6:
		return "v4"
	case c.OnlyIPv6 && !c.OnlyIPv4:
		return "v6"
	default:
		return "cdn"
	}
}
