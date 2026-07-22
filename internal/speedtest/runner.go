package speedtest

import "tcpquality/internal/nodes"

// Options configures a speedtest run.
type Options struct {
	Region  string
	Network string
	Size    string
	Timeout int // seconds
	Warmup  int // seconds

	// Fallback carrier entry IPs (overridden by TOS nodes when present).
	CTIP, CUIP, CMIP string

	TosutilURL string
	TosutilBin string // pre-set binary path; empty to auto-install

	// Debug retains extra diagnostics.
	Debug bool
}

// DefaultOptions returns the built-in speedtest configuration.
func DefaultOptions() Options {
	return Options{
		Region:     "cn-beijing",
		Network:    "public",
		Size:       "5GB",
		Timeout:    15,
		Warmup:     5,
		CTIP:       "42.81.80.86",
		CUIP:       "221.194.175.109",
		CMIP:       "120.255.0.180",
		TosutilURL: "https://m645b3e1bb36e-mrap.mrap.accesspoint.tos-global.volces.com/linux/amd64/tosutil",
	}
}

// applyNodes overrides the fallback carrier IPs/cities from the TOS node feed.
func (o *Options) applyNodes(tos []nodes.SpeedtestNode) [3]Selected {
	sel := [3]Selected{}
	for i, c := range Carriers {
		switch c {
		case "电信":
			sel[i] = Selected{ID: o.CTIP, City: "北京"}
		case "联通":
			sel[i] = Selected{ID: o.CUIP, City: "北京"}
		case "移动":
			sel[i] = Selected{ID: o.CMIP, City: "北京"}
		}
	}
	for _, n := range tos {
		for i, c := range Carriers {
			if c != n.ISP {
				continue
			}
			switch c {
			case "电信":
				o.CTIP = n.IP
			case "联通":
				o.CUIP = n.IP
			case "移动":
				o.CMIP = n.IP
			}
			sel[i] = Selected{ID: n.IP, City: n.City}
		}
	}
	return sel
}

// endpointHosts returns the TOS hostnames whose resolution is pinned to the
// carrier IP for the duration of a probe.
func (o *Options) endpointHosts() []string {
	return []string{
		"tos-" + o.Region + ".volces.com",
		"tos7-public." + o.Region + ".tos.volces.com",
	}
}
