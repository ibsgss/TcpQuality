// Package config holds runtime configuration, constants, command-line parsing
// and province filtering for the TcpQuality Go port.
package config

import (
	"os"
	"strings"
)

// Fixed limits and defaults mirroring the original script.
const (
	DefaultPackets       = 30
	MaxPackets           = 600
	DefaultParallel      = 16
	MaxParallel          = 31
	InternationalPackets = 15

	LargePacketPrecheckDomain  = "www.cloudflare.com"
	LargePacketPrecheckPackets = 20
	LargePacketPrecheckSize    = 1200

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

	OnlyIPv4   bool
	OnlyIPv6   bool
	OnlyLarge  bool
	TestCernet bool
	TestAll    bool

	RouteMode     bool
	RouteProtocol string

	SpeedtestEnabled bool
	SpeedtestOnly    bool

	InternationalEnabled bool
	InternationalOnly    bool
	IntlRequested        bool
	InternationalPackets int

	UploadReport bool
	DebugMode    bool

	// selectedOrder preserves the order provinces were requested in; selected
	// is the membership set. Empty means "all provinces".
	selectedOrder []string
	selected      map[string]bool

	GetNodesURL string
	ReportAPI   string
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
	return c
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
	case c.TestAll:
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
