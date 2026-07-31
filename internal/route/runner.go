package route

import "context"

// LabelForTrace classifies a completed traceroute into a backbone route label.
func LabelForTrace(tr *TraceResult, asnMap map[string]string, targetISP string) string {
	if tr == nil {
		return "Hidden"
	}
	return Classify(tr.PublicHopIPs(), asnMap, tr.DestIP, targetISP)
}

// CollectHopIPs gathers the union of public hop IPs across many traces, for a
// single batched Team Cymru query.
func CollectHopIPs(traces []*TraceResult) []string {
	seen := map[string]bool{}
	var out []string
	for _, tr := range traces {
		if tr == nil {
			continue
		}
		for _, ip := range tr.PublicHopIPs() {
			if !seen[ip] {
				seen[ip] = true
				out = append(out, ip)
			}
		}
	}
	return out
}

// TraceWithRetry runs a traceroute and, for TCP/IPv4, repeats it once when the
// 10099 hidden-domestic heuristic fires (mirrors the retry in route_trace_one).
func TraceWithRetry(ctx context.Context, family, protocol, destIP string, port, psize int) (*TraceResult, error) {
	tr, err := Trace(ctx, family, protocol, destIP, port, psize)
	if err != nil {
		return tr, err
	}
	if family == "4" && protocol == "tcp" && Needs10099HiddenRetry(tr.Hops) {
		if retry, rErr := Trace(ctx, family, protocol, destIP, port, psize); rErr == nil {
			tr.Hops = append(tr.Hops, retry.Hops...)
		}
	}
	return tr, nil
}
