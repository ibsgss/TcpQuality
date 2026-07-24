// Package iputil provides public-IP validation and public IPv4/IPv6 stack
// detection, mirroring the is_public_ipv4 / is_valid_ipv6 / get_public_ip*
// helpers of the original script.
package iputil

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"strings"
	"time"
)

// IsPublicIPv4 reports whether s is a syntactically valid, globally routable
// IPv4 address, excluding the same private/special ranges as the bash script.
func IsPublicIPv4(s string) bool {
	ip := net.ParseIP(s)
	if ip == nil {
		return false
	}
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	a, b, c := int(v4[0]), int(v4[1]), int(v4[2])
	switch {
	case a == 0 || a == 10 || a == 127 || a >= 224:
		return false
	case a == 100 && b >= 64 && b <= 127:
		return false
	case a == 169 && b == 254:
		return false
	case a == 172 && b >= 16 && b <= 31:
		return false
	case a == 192 && b == 168:
		return false
	case a == 192 && b == 0 && c == 0:
		return false
	case a == 192 && b == 0 && c == 2:
		return false
	case a == 198 && (b == 18 || b == 19):
		return false
	case a == 198 && b == 51 && c == 100:
		return false
	case a == 203 && b == 0 && c == 113:
		return false
	}
	return true
}

// IsValidIPv6 mirrors is_valid_ipv6: a colon-bearing address that is not
// loopback, link-local, ULA, documentation, v4-mapped, or 6to4.
func IsValidIPv6(s string) bool {
	if !strings.Contains(s, ":") {
		return false
	}
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() != nil {
		return false
	}
	low := strings.ToLower(s)
	switch {
	case low == "::1":
		return false
	case strings.HasPrefix(low, "fe80:"):
		return false
	case strings.HasPrefix(low, "fc00:"), strings.HasPrefix(low, "fd00:"):
		return false
	case strings.HasPrefix(low, "2001:db8:"):
		return false
	case strings.HasPrefix(low, "::ffff:"):
		return false
	case strings.HasPrefix(low, "2002:"):
		return false
	}
	return true
}

// Stack captures detected public addresses for each family.
type Stack struct {
	IPv4     string
	IPv6     string
	IPv4Work bool
	IPv6Work bool
}

var ipAPIs = []string{
	"https://ip.sb",
	"https://icanhazip.com",
	"https://api64.ipify.org",
	"https://ifconfig.co",
	"https://ident.me",
}

// Detect probes public IPv4 and IPv6 concurrently and returns a populated Stack.
func Detect(ctx context.Context) Stack {
	var s Stack
	done := make(chan struct{}, 2)
	go func() {
		if ip, ok := detectFamily(ctx, "tcp4", IsPublicIPv4); ok {
			s.IPv4, s.IPv4Work = ip, true
		}
		done <- struct{}{}
	}()
	go func() {
		if ip, ok := detectFamily(ctx, "tcp6", IsValidIPv6); ok {
			s.IPv6, s.IPv6Work = ip, true
		}
		done <- struct{}{}
	}()
	<-done
	<-done
	return s
}

// detectFamily queries the IP-echo APIs over the given network until one
// returns an address that satisfies valid.
func detectFamily(ctx context.Context, network string, valid func(string) bool) (string, bool) {
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	client := &http.Client{
		Timeout: 8 * time.Second,
		Transport: &http.Transport{
			DialContext: func(c context.Context, _, addr string) (net.Conn, error) {
				return dialer.DialContext(c, network, addr)
			},
		},
	}
	for _, api := range ipAPIs {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, api, nil)
		if err != nil {
			continue
		}
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(resp.Body)
		var line string
		if sc.Scan() {
			line = strings.TrimSpace(sc.Text())
		}
		resp.Body.Close()
		if valid(line) {
			return line, true
		}
	}
	return "", false
}

// ResolveFirstPublicIPv4 returns the first globally routable A record for host.
func ResolveFirstPublicIPv4(ctx context.Context, host string) (string, bool) {
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return "", false
	}
	for _, a := range addrs {
		if v4 := a.IP.To4(); v4 != nil && IsPublicIPv4(v4.String()) {
			return v4.String(), true
		}
	}
	return "", false
}
