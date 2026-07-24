// Package nodes fetches and parses the remote getNodes TSV feed that supplies
// probe targets (three-carrier CDN nodes, CERNET/CERNET2 nodes) and the tosutil
// speedtest entry IPs.
package nodes

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Node is a single probe target with an optional backup endpoint.
type Node struct {
	Province   string
	ISP        string
	Host       string
	IP         string
	Port       string
	BackupHost string
	BackupIP   string
	BackupPort string
}

// SpeedtestNode is a tosutil entry IP for one carrier.
type SpeedtestNode struct {
	ISP  string // 电信 / 联通 / 移动
	IP   string
	City string
}

// Set holds the parsed node lists grouped by scope/family.
type Set struct {
	CDN4    []Node
	CDN6    []Node
	CERNET  []Node // IPv4 education backbone
	CERNET2 []Node // IPv6 education backbone
	TOS     []SpeedtestNode
}

// Empty reports whether no probe nodes were parsed.
func (s *Set) Empty() bool {
	return len(s.CDN4) == 0 && len(s.CDN6) == 0 && len(s.CERNET) == 0 && len(s.CERNET2) == 0
}

// CDN returns the CDN node list for the given family ("4" or "6").
func (s *Set) CDN(family string) []Node {
	if family == "6" {
		return s.CDN6
	}
	return s.CDN4
}

func firstNonEmpty(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// Parse reads the TSV feed and returns the parsed Set. The header row (first
// column "type") is skipped and rows without an IP are ignored.
func Parse(r io.Reader) (*Set, error) {
	set := &Set{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		// Pad to the full 12 expected columns.
		for len(f) < 12 {
			f = append(f, "")
		}
		typ, family := f[0], f[1]
		prov, isp, host, ip, port := f[2], f[3], f[4], f[5], f[6]
		backupHost, backupIP, backupPort := f[8], f[9], f[10]
		if typ == "type" {
			continue
		}
		if ip == "" {
			continue
		}
		port = firstNonEmpty(port, "80")

		switch typ + ":" + family {
		case "cdn:4":
			set.CDN4 = append(set.CDN4, Node{prov, isp, host, ip, port, backupHost, backupIP, firstNonEmpty(backupPort, "80")})
		case "cdn:6":
			set.CDN6 = append(set.CDN6, Node{prov, isp, host, ip, port, backupHost, backupIP, firstNonEmpty(backupPort, "80")})
		case "cernet:4":
			set.CERNET = append(set.CERNET, Node{prov, "教育网", host, ip, port, backupHost, backupIP, firstNonEmpty(backupPort, "443")})
		case "cernet2:6":
			set.CERNET2 = append(set.CERNET2, Node{prov, "教育网", host, ip, port, backupHost, backupIP, firstNonEmpty(backupPort, "443")})
		}

		if family == "4" {
			switch typ {
			case "tos", "tosutil", "speedtest":
				if carrier, ok := normalizeCarrier(isp); ok {
					set.TOS = append(set.TOS, SpeedtestNode{ISP: carrier, IP: ip, City: firstNonEmpty(prov, "北京")})
				}
			}
		}
	}
	return set, sc.Err()
}

// normalizeCarrier maps assorted carrier aliases to the canonical Chinese name.
func normalizeCarrier(isp string) (string, bool) {
	switch isp {
	case "电信", "CT", "ChinaTelecom", "chinatelecom":
		return "电信", true
	case "联通", "CU", "ChinaUnicom", "chinaunicom":
		return "联通", true
	case "移动", "CM", "ChinaMobile", "chinamobile":
		return "移动", true
	}
	return "", false
}

// buildURL appends the format/scope query parameters to the base getNodes URL.
func buildURL(base, scope string) string {
	sep := "?"
	if strings.Contains(base, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%sformat=tsv&scope=%s", base, sep, scope)
}

// Fetch downloads and parses the node feed for the given scope. It returns an
// error when the feed cannot be retrieved or yields no usable nodes.
func Fetch(ctx context.Context, baseURL, scope string) (*Set, error) {
	url := buildURL(baseURL, scope)
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("getNodes HTTP %d", resp.StatusCode)
	}
	set, err := Parse(resp.Body)
	if err != nil {
		return nil, err
	}
	if set.Empty() && scope != "tos" {
		return nil, fmt.Errorf("getNodes 返回空节点列表 (scope=%s)", scope)
	}
	return set, nil
}
