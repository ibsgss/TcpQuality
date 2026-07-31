package speedtest

import (
	"os"
	"runtime"

	"tcpquality/internal/nodes"
)

// Candidate is one carrier endpoint in one TOS region.
type Candidate struct {
	IP     string
	City   string
	Region string
}

// Options configures a speedtest run.
type Options struct {
	Network string
	Size    string
	Timeout int // seconds
	Warmup  int // seconds

	// Groups selects which regions to test.
	Groups []Group

	// Candidates maps a carrier name to its known endpoints. It is seeded with
	// the built-in Beijing fallbacks and replaced wholesale once the getNodes
	// feed supplies entries.
	Candidates map[string][]Candidate

	TosutilURL string
	TosutilBin string // pre-set binary path; empty to auto-install

	// AppleCDN enables the AppleCDN reference test.
	AppleCDN         bool
	AppleMaxUpMB     int
	AppleDownloadURL string
	AppleUploadURL   string

	// Debug retains extra diagnostics.
	Debug bool
}

const (
	appleHost             = "mensura.cdn-apple.com"
	appleDefaultDownload  = "https://mensura.cdn-apple.com/api/v1/gm/large"
	appleDefaultUpload    = "https://mensura.cdn-apple.com/api/v1/gm/slurp"
	appleDefaultMaxUpMB   = 2048
	appleUserAgent        = "networkQuality/194.80.3 CFNetwork/3860.400.51 Darwin/25.3.0"
	appleIPv6ProbeAddress = "2620:149:a21:f000::133"
)

// envOr returns the environment override for key, or def.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// DefaultOptions returns the built-in speedtest configuration.
func DefaultOptions() Options {
	o := Options{
		Network:          envOr("TOS_NETWORK", "public"),
		Size:             envOr("TOS_PROBE_SIZE", "5GB"),
		Timeout:          15,
		Warmup:           5,
		Groups:           allGroups,
		TosutilBin:       os.Getenv("TOSUTIL_BIN"),
		TosutilURL:       TosutilURL(),
		AppleCDN:         os.Getenv("SPEEDTEST_APPLECDN_ENABLED") != "0",
		AppleMaxUpMB:     appleDefaultMaxUpMB,
		AppleDownloadURL: envOr("SPEEDTEST_APPLECDN_DOWNLOAD_URL", appleDefaultDownload),
		AppleUploadURL:   envOr("SPEEDTEST_APPLECDN_UPLOAD_URL", appleDefaultUpload),
	}
	o.Candidates = map[string][]Candidate{
		"电信": {{IP: envOr("TOS_CT_IP", "42.81.80.86"), City: "北京", Region: "cn-beijing"}},
		"联通": {{IP: envOr("TOS_CU_IP", "221.194.175.109"), City: "北京", Region: "cn-beijing"}},
		"移动": {{IP: envOr("TOS_CM_IP", "120.255.0.180"), City: "北京", Region: "cn-beijing"}},
	}
	return o
}

// TosutilURL returns the official tosutil download URL for this architecture,
// or "" when the architecture has no published build.
func TosutilURL() string {
	if v := os.Getenv("TOSUTIL_URL"); v != "" {
		return v
	}
	switch runtime.GOARCH {
	case "amd64", "arm64":
		return "https://m645b3e1bb36e-mrap.mrap.accesspoint.tos-global.volces.com/linux/" +
			runtime.GOARCH + "/tosutil"
	}
	return ""
}

// ApplyNodes replaces the built-in candidate lists with the getNodes feed when
// it carries any usable entry.
func (o *Options) ApplyNodes(tos []nodes.SpeedtestNode) {
	remote := map[string][]Candidate{}
	for _, n := range tos {
		if n.IP == "" {
			continue
		}
		city := n.City
		if city == "" {
			city = "北京"
		}
		region := n.Region
		if region == "" {
			region = "cn-beijing"
		}
		remote[n.ISP] = append(remote[n.ISP], Candidate{IP: n.IP, City: city, Region: region})
	}
	for carrier, list := range remote {
		o.Candidates[carrier] = list
	}
}

// PickCandidate returns the carrier's first endpoint in the given region, or
// false when the carrier has no endpoint there.
func (o *Options) PickCandidate(carrier, region string) (Candidate, bool) {
	for _, c := range o.Candidates[carrier] {
		if c.IP != "" && c.Region == region {
			return c, true
		}
	}
	return Candidate{}, false
}

// StepCount is the number of progress steps a run of these options will report.
func (o *Options) StepCount() int {
	n := len(o.Groups) * len(Carriers)
	if o.AppleCDN {
		n++
	}
	return n
}

// endpointHosts returns the TOS hostnames whose resolution is pinned to the
// carrier IP for the duration of a probe in the given region.
func endpointHosts(region string) []string {
	return []string{
		"tos-" + region + ".volces.com",
		"tos7-public." + region + ".tos.volces.com",
	}
}
