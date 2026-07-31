package route

import "tcpquality/internal/iputil"

// Hop is a single traceroute TTL result.
type Hop struct {
	TTL       int
	IP        string
	Responded bool
}

// TraceResult holds the ordered hops of a traceroute plus the known target.
type TraceResult struct {
	Hops    []Hop
	DestIP  string
	Reached bool
}

// PublicHopIPs returns the ordered, unique, globally routable hop IPs, which is
// exactly the input the classifier expects (mirrors extract_trace_ips).
func (tr *TraceResult) PublicHopIPs() []string {
	seen := map[string]bool{}
	var out []string
	for _, h := range tr.Hops {
		if h.IP == "" || seen[h.IP] {
			continue
		}
		if !iputil.IsPublicIPv4(h.IP) && !iputil.IsValidIPv6(h.IP) {
			continue
		}
		seen[h.IP] = true
		out = append(out, h.IP)
	}
	return out
}

// backbone-detection predicates used only by the 10099 hidden-segment retry.
func is10099Retry(ip string) bool { return is10099EntryIP(ip) }
func is4837Retry(ip string) bool  { return len(ip) >= 8 && ip[:8] == "219.158." }
func is9929Retry(ip string) bool {
	return hasAnyPrefix(ip, "210.14.", "210.51.", "210.78.", "218.105.")
}
func is163Retry(ip string) bool {
	return hasAnyPrefix(ip, "202.97.", "202.96.", "219.141.", "219.142.", "106.37.")
}

// Needs10099HiddenRetry reproduces route_needs_10099_hidden_tcp_retry: a TCP v4
// trace that enters via AS10099, later shows 163 but never a Unicom domestic
// backbone hop, with at least two hidden (timed-out) hops after the 10099 entry,
// warrants a second traceroute attempt.
func Needs10099HiddenRetry(hops []Hop) bool {
	var seen10099, after10099, seenUnicomDomestic, seen163 bool
	hiddenAfter := 0
	for _, h := range hops {
		hasIP := h.Responded && h.IP != "" && iputil.IsPublicIPv4(h.IP)
		if hasIP {
			ip := h.IP
			if is10099Retry(ip) {
				seen10099 = true
				after10099 = true
				continue
			}
			if !after10099 {
				continue
			}
			if is4837Retry(ip) || is9929Retry(ip) {
				seenUnicomDomestic = true
			}
			if is163Retry(ip) {
				seen163 = true
			}
			continue
		}
		// hidden hop (timeout)
		if after10099 && !seen163 {
			hiddenAfter++
		}
	}
	return seen10099 && seen163 && !seenUnicomDomestic && hiddenAfter >= 2
}
