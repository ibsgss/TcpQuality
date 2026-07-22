package route

import (
	"bufio"
	"context"
	"net"
	"sort"
	"strings"
	"time"
)

// QueryCymruASN performs a bulk Team Cymru whois lookup (whois.cymru.com:43) for
// the given IPs and returns an ip -> ASN map, mirroring query_cymru_asn +
// build_asn_map. Unresolvable input yields an empty (non-nil) map.
func QueryCymruASN(ctx context.Context, ips []string) (map[string]string, error) {
	result := map[string]string{}
	uniq := dedupeSorted(ips)
	if len(uniq) == 0 {
		return result, nil
	}

	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", "whois.cymru.com:43")
	if err != nil {
		return result, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(35 * time.Second))

	var req strings.Builder
	req.WriteString("begin\nverbose\n")
	for _, ip := range uniq {
		req.WriteString(ip)
		req.WriteByte('\n')
	}
	req.WriteString("end\n")
	if _, err := conn.Write([]byte(req.String())); err != nil {
		return result, err
	}

	sc := bufio.NewScanner(conn)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			first = false // skip the "Bulk mode; ..." banner row
			continue
		}
		asn, ip, ok := parseCymruLine(line)
		if ok {
			result[ip] = asn
		}
	}
	return result, nil
}

// parseCymruLine parses a verbose Team Cymru response row:
// "ASN | IP | BGP Prefix | CC | Registry | Allocated | AS Name".
func parseCymruLine(line string) (asn, ip string, ok bool) {
	fields := strings.Split(line, "|")
	if len(fields) < 2 {
		return "", "", false
	}
	asn = strings.TrimSpace(fields[0])
	ip = strings.TrimSpace(fields[1])
	if !isAllDigits(asn) || ip == "" {
		return "", "", false
	}
	return asn, ip, true
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func dedupeSorted(ips []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, ip := range ips {
		if ip == "" || seen[ip] {
			continue
		}
		seen[ip] = true
		out = append(out, ip)
	}
	sort.Strings(out)
	return out
}
