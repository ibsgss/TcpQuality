package route

import (
	"regexp"
	"strings"
)

var (
	reCN2245 = regexp.MustCompile(`^59\.43\.245\.`)
	re5943   = regexp.MustCompile(`^59\.43\.`)
)

// trace holds an ordered hop list (1-indexed, index 0 is a dummy) used to
// reproduce the awk classifier in route_label_from_ip_trace.
type trace struct {
	ips       []string // ips[1..maxHop]
	asns      []string // asns[1..maxHop]
	maxHop    int
	allASN    map[string]bool
	asnMap    map[string]string
	destIP    string
	targetISP string
}

// Classify returns the backbone route label for a set of ordered, unique public
// hop IPs. asnByIP maps hop IP -> ASN (from Team Cymru); missing entries fall
// back to inferASNFromIP. destIP is the final target IP; targetISP is 电信/联通/移动
// (or "" for education/other).
func Classify(hopIPs []string, asnByIP map[string]string, destIP, targetISP string) string {
	t := &trace{
		ips:       []string{""},
		asns:      []string{""},
		allASN:    map[string]bool{},
		asnMap:    asnByIP,
		destIP:    destIP,
		targetISP: targetISP,
	}
	seen := map[string]bool{}
	for _, ip := range hopIPs {
		if ip == "" || seen[ip] {
			continue
		}
		seen[ip] = true
		asn := asnByIP[ip]
		if asn == "" {
			asn = inferASNFromIP(ip)
		}
		t.ips = append(t.ips, ip)
		t.asns = append(t.asns, asn)
		t.maxHop++
		t.addASN(asn)
	}
	return t.classify()
}

func (t *trace) addASN(asn string) {
	if asn != "" {
		t.allASN[asn] = true
	}
}

func (t *trace) hasASN(v string) bool { return t.allASN[v] }

func (t *trace) asnByIP(ip string) string {
	// Used for dest-IP resolution: prefer the Cymru map, then inference.
	if asn := t.asnMap[ip]; asn != "" {
		return asn
	}
	return inferASNFromIP(ip)
}

func (t *trace) unicomDomesticLabelFromHop(first int) string {
	has4837 := false
	for h := first + 1; h <= t.maxHop; h++ {
		if h < 1 {
			continue
		}
		if t.asns[h] == "9929" || hasAnyPrefix(t.ips[h], "210.14.", "210.51.", "210.78.", "218.105.") {
			return "9929"
		}
		if t.asns[h] == "4837" || t.asns[h] == "4808" || isUnicomAccessASN(t.asns[h]) ||
			strings.HasPrefix(t.ips[h], "219.158.") || strings.HasPrefix(t.ips[h], "2408:") {
			has4837 = true
		}
	}
	if has4837 {
		return "4837"
	}
	return ""
}

func (t *trace) unicomRouteComboLabel() string {
	firstUnicom := 0
	for h := 1; h <= t.maxHop; h++ {
		if t.asns[h] == "10099" && is10099EntryIP(t.ips[h]) {
			domestic := t.unicomDomesticLabelFromHop(h)
			if domestic != "" {
				return "10099->" + domestic
			}
			return "10099"
		}
		if isUnicomBackboneASN(t.asns[h]) || isUnicomBackboneIP(t.ips[h]) {
			firstUnicom = h
			break
		}
	}
	return t.unicomDomesticLabelFromHop(firstUnicom - 1)
}

func (t *trace) hasCN2To163(first int) bool {
	if first <= 0 {
		return false
	}
	for h := first; h <= t.maxHop; h++ {
		if !reCN2245.MatchString(t.ips[h]) {
			continue
		}
		for n := h + 1; n <= t.maxHop; n++ {
			if re5943.MatchString(t.ips[n]) {
				continue
			}
			return is163IP(t.ips[n]) ||
				(t.targetISP == "电信" && (isTelecomAccessASN(t.asns[n]) || isTelecomAccessIP(t.ips[n])))
		}
	}
	return false
}

func (t *trace) isMainlandBackboneHop(asn, ip string) bool {
	switch {
	case asn == "10099":
		return is10099EntryIP(ip)
	case asn == "9929" || asn == "4837" || asn == "4808":
		return true
	case asn == "4809":
		return !isOverseaCN2IP(ip)
	case asn == "4134":
		return is163IP(ip) || (t.targetISP == "电信" && (isTelecomAccessASN(asn) || isTelecomAccessIP(ip)))
	case asn == "4847":
		return true
	case asn == "23764" || isCtgnetIP(ip):
		return !isCtgnetIP(ip) // is_ctgnet_transit_ip == is_ctgnet_ip
	case asn == "58807" || asn == "58453" || asn == "9808":
		return true
	case reCMI5604x.MatchString(asn):
		return true
	case t.targetISP == "移动" && (isMobileAccessASN(asn) || isMobileAccessIP(ip)):
		return true
	case asn == "23911" || asn == "23910" || asn == "4538" || asn == "7497":
		return true
	case is163IP(ip):
		return true
	case t.targetISP == "电信" && (isTelecomAccessASN(asn) || isTelecomAccessIP(ip)):
		return true
	}
	return false
}

func (t *trace) labelFromMainlandHop(hop int, asn, ip string) string {
	switch {
	case asn == "10099":
		return "10099"
	case asn == "9929":
		return "9929"
	case asn == "4837" || asn == "4808":
		return "4837"
	case asn == "4134" && is163IP(ip):
		return "163"
	case asn == "4847" || is163IP(ip):
		return "163"
	case t.targetISP == "电信" && (isTelecomAccessASN(asn) || isTelecomAccessIP(ip)):
		return "163"
	case asn == "23764" || isCtgnetIP(ip):
		return ""
	case asn == "4809":
		if t.hasCN2To163(hop) {
			return "CN2GT"
		}
		for h := hop; h <= t.maxHop; h++ {
			if t.asns[h] == "23764" || isCtgnetIP(t.ips[h]) {
				return "CTGGIA"
			}
		}
		return "CN2GIA"
	case asn == "58807":
		return "CMIN2"
	case asn == "58453" || asn == "9808" || reCMI5604x.MatchString(asn):
		return "CMI"
	case t.targetISP == "移动" && (isMobileAccessASN(asn) || isMobileAccessIP(ip)):
		return "CMI"
	case asn == "23911" || asn == "23910":
		return "CERNET2"
	case asn == "4538":
		return "CERNET"
	case asn == "7497":
		return "CSTNET"
	}
	return ""
}

func isLocalProbeASN(asn string) bool { return asn == "" || asn == "749" }

func (t *trace) isTargetISPHop(asn, ip string) bool {
	switch t.targetISP {
	case "电信":
		return is163IP(ip) || isTelecomAccessASN(asn) || isTelecomAccessIP(ip)
	case "联通":
		return isUnicomBackboneASN(asn) || isUnicomBackboneIP(ip) || isUnicomAccessASN(asn)
	case "移动":
		return asn == "58807" || asn == "58453" || asn == "9808" || reCMI5604x.MatchString(asn) ||
			isMobileAccessASN(asn) || isMobileAccessIP(ip)
	}
	return false
}

func (t *trace) visibleHopsMatchTargetISP() bool {
	if t.maxHop <= 0 {
		return false
	}
	for h := 1; h <= t.maxHop; h++ {
		if isLocalProbeASN(t.asns[h]) {
			continue
		}
		if t.isTargetISPHop(t.asns[h], t.ips[h]) {
			continue
		}
		return false
	}
	return true
}

func (t *trace) labelFromTargetIP() string {
	if t.destIP == "" || !t.visibleHopsMatchTargetISP() {
		return ""
	}
	asn := t.asnByIP(t.destIP)
	switch {
	case t.targetISP == "电信" && (is163IP(t.destIP) || isTelecomAccessASN(asn) || isTelecomAccessIP(t.destIP)):
		return "163"
	case t.targetISP == "联通" && (isUnicomBackboneASN(asn) || isUnicomBackboneIP(t.destIP) || isUnicomAccessASN(asn)):
		return t.unicomRouteComboLabel()
	case t.targetISP == "移动" && (asn == "58807" || asn == "58453" || asn == "9808" ||
		reCMI5604x.MatchString(asn) || isMobileAccessASN(asn) || isMobileAccessIP(t.destIP)):
		return "CMI"
	}
	return ""
}

func (t *trace) classify() string {
	firstCN2, hasCTGNet, hasCN2 := 0, false, false
	for hop := 1; hop <= t.maxHop; hop++ {
		if t.asns[hop] == "23764" || isCtgnetIP(t.ips[hop]) {
			hasCTGNet = true
		}
		if re5943.MatchString(t.ips[hop]) {
			hasCN2 = true
			if firstCN2 == 0 {
				firstCN2 = hop
			}
		}
	}
	if hasCN2 {
		if t.hasCN2To163(firstCN2) {
			return "CN2GT"
		}
		if hasCTGNet {
			return "CTGGIA"
		}
		return "CN2GIA"
	}
	if label := t.unicomRouteComboLabel(); label != "" {
		return label
	}
	for hop := 1; hop <= t.maxHop; hop++ {
		if !t.isMainlandBackboneHop(t.asns[hop], t.ips[hop]) {
			continue
		}
		if label := t.labelFromMainlandHop(hop, t.asns[hop], t.ips[hop]); label != "" {
			return label
		}
	}
	switch {
	case t.hasASN("58807"):
		return "CMIN2"
	case t.hasASN("23911"):
		return "CERNET2"
	case t.hasASN("9929"):
		return "9929"
	case t.hasASN("4837") || t.hasASN("4808"):
		return "4837"
	case t.hasASN("4847"):
		return "163"
	case t.hasASN("58453") || t.hasASN("9808") || t.hasASN("56040") || t.hasASN("56041") ||
		t.hasASN("56042") || t.hasASN("56044") || t.hasASN("56045") || t.hasASN("56046") ||
		t.hasASN("56047") || t.hasASN("56048"):
		return "CMI"
	case hasCTGNet || t.hasASN("23764"):
		return "CTGGIA"
	case t.hasASN("23910"):
		return "CERNET2"
	case t.hasASN("4538"):
		return "CERNET"
	case t.hasASN("7497"):
		return "CSTNET"
	}
	if label := t.labelFromTargetIP(); label != "" {
		return label
	}
	return "Hidden"
}
