package route

import (
	"regexp"
	"strings"
)

// hasAnyPrefix reports whether s starts with any of the given prefixes.
func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// Ranged patterns that can't be expressed as simple prefixes.
var (
	re10099Entry     = regexp.MustCompile(`^162\.219\.(3[2-9]|85)\.`)
	reCernet4538     = regexp.MustCompile(`^(210\.2[6-9]\.|210\.3[0-9]\.|210\.4[0-7]\.|219\.22[4-9]\.|222\.(1[6-9]|2[0-3])\.|222\.19[2-9]\.|222\.20[0-7]\.)`)
	reCernet4538Pre  = regexp.MustCompile(`^202\.38\.19`)
	reCMI5604x       = regexp.MustCompile(`^5604[0-8]$`)
	reCernetPrefixes = []string{
		"59.64.", "101.4.", "101.76.", "111.114.", "113.54.", "115.24.", "115.156.",
		"183.172.", "202.112.", "202.113.", "202.114.", "202.115.", "202.116.",
		"202.117.", "202.118.", "202.119.", "202.120.", "202.194.", "202.196.",
		"202.197.", "202.198.", "202.200.", "202.201.", "202.202.", "202.207.",
	}
)

// inferASNFromIP mirrors infer_asn_from_ip: derive an ASN purely from the IP
// when Team Cymru has no answer. Returns "" when unknown.
func inferASNFromIP(ip string) string {
	switch {
	case strings.HasPrefix(ip, "59.43."):
		return "4809"
	case hasAnyPrefix(ip, "203.22.182.", "203.22.178.", "203.22.179.", "203.128.224.", "69.194."):
		return "23764"
	case strings.HasPrefix(ip, "2400:9380:"):
		return "23764"
	case hasAnyPrefix(ip, "202.97.", "202.96.", "219.141.", "219.142.", "106.37."):
		return "4134"
	case strings.HasPrefix(ip, "240e:"):
		return "4134"
	case strings.HasPrefix(ip, "219.158."):
		return "4837"
	case strings.HasPrefix(ip, "2408:"):
		return "4837"
	case hasAnyPrefix(ip, "223.120.", "223.119."):
		return "58453"
	case hasAnyPrefix(ip, "221.183.", "111.24.", "111.13."):
		return "9808"
	case is10099EntryIP(ip):
		return "10099"
	case hasAnyPrefix(ip, "210.14.", "210.51.", "210.78.", "218.105."):
		return "9929"
	case isCernet4538IP(ip):
		return "4538"
	case strings.HasPrefix(ip, "2001:252:"):
		return "23911"
	case hasAnyPrefix(ip, "2001:da8:", "2001:250:", "2402:f000:"):
		return "23910"
	case strings.HasPrefix(ip, "159.226."):
		return "7497"
	}
	return ""
}

func isCernet4538IP(ip string) bool {
	if hasAnyPrefix(ip, reCernetPrefixes...) {
		return true
	}
	return reCernet4538Pre.MatchString(ip) || reCernet4538.MatchString(ip)
}

func isCtgnetIP(ip string) bool {
	return hasAnyPrefix(ip, "203.22.182.", "203.22.178.", "203.22.179.", "203.128.224.", "69.194.") ||
		strings.HasPrefix(ip, "2400:9380:")
}

func is163IP(ip string) bool {
	return hasAnyPrefix(ip, "202.97.", "202.96.", "219.141.", "219.142.", "106.37.") ||
		strings.HasPrefix(ip, "240e:")
}

func isTelecomAccessASN(asn string) bool {
	switch asn {
	case "4134", "4811", "4812", "4847", "23724", "134756", "133776",
		"139201", "139203", "148969", "38283", "58540", "58563":
		return true
	}
	return false
}

func isTelecomAccessIP(ip string) bool {
	return hasAnyPrefix(ip,
		"1.202.", "27.129.", "36.110.", "36.112.", "58.213.", "101.95.", "101.226.",
		"106.227.", "111.74.", "117.21.", "117.68.", "124.127.", "140.249.", "180.102.",
		"183.47.", "219.148.", "220.181.")
}

func isMobileAccessASN(asn string) bool {
	return asn == "24547" || asn == "132510"
}

func isMobileAccessIP(ip string) bool {
	return hasAnyPrefix(ip, "111.63.", "183.201.", "183.203.")
}

func is10099EntryIP(ip string) bool {
	return hasAnyPrefix(ip, "103.214.", "103.228.68.", "103.239.176.", "118.26.151.",
		"202.77.23.", "203.160.75.") ||
		re10099Entry.MatchString(ip) ||
		strings.HasPrefix(ip, "2401:8a00:")
}

func isOverseaCN2IP(ip string) bool {
	return strings.HasPrefix(ip, "2605:9d80:")
}

func isUnicomBackboneIP(ip string) bool {
	return hasAnyPrefix(ip, "210.14.", "210.51.", "210.78.", "218.105.", "219.158.") ||
		strings.HasPrefix(ip, "2408:")
}

func isUnicomBackboneASN(asn string) bool {
	return asn == "9929" || asn == "4837" || asn == "4808"
}

func isUnicomAccessASN(asn string) bool {
	return asn == "136958" || asn == "140979"
}
