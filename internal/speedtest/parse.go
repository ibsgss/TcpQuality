package speedtest

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var reAvgRate = regexp.MustCompile(`Average .* rate:`)

// parseRateMbps extracts the average transfer rate from tosutil output and
// converts it to Mbps, mirroring speedtest_parse_rate_mbps. Returns "failed"
// when no rate line is present.
func parseRateMbps(output string) string {
	for _, line := range strings.Split(output, "\n") {
		if !reAvgRate.MatchString(line) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		last := fields[len(fields)-1]
		numStr := stripNonNumeric(last)
		value, err := strconv.ParseFloat(numStr, 64)
		if err != nil {
			continue
		}
		switch {
		case strings.Contains(last, "GB/s"):
			value *= 8000
		case strings.Contains(last, "MB/s"):
			value *= 8
		case strings.Contains(last, "KB/s"):
			value = value * 8 / 1000
		case strings.Contains(last, "B/s"):
			value = value * 8 / 1000000
		}
		return fmt.Sprintf("%.1f", value)
	}
	return "failed"
}

func stripNonNumeric(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= '0' && r <= '9') || r == '.' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// calcMbps converts a byte delta over a duration in seconds to Mbps.
func calcMbps(bytes int64, seconds float64) string {
	if seconds <= 0 || bytes < 0 {
		return "failed"
	}
	return fmt.Sprintf("%.1f", float64(bytes)*8/seconds/1000000)
}
