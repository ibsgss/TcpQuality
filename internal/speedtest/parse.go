package speedtest

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	// reRateLine matches the "... rate:" prefix case-insensitively; tosutil has
	// varied the wording and capitalization across releases.
	reRateLine = regexp.MustCompile(`(?i)rate:\s*`)
	// reRateToken matches a "12.3MB/s"-style token with the whitespace removed.
	reRateToken = regexp.MustCompile(`(?i)[0-9]+(\.[0-9]+)?[gmk]?b/s`)
	// reCostValue matches the first (possibly negative) integer after a colon.
	reCostValue = regexp.MustCompile(`-?[0-9]+`)
)

// parseRateMbps extracts the average transfer rate from tosutil output and
// converts it to Mbps, mirroring speedtest_parse_rate_mbps. Returns "failed"
// when no rate line is present.
func parseRateMbps(output string) string {
	for _, line := range strings.Split(output, "\n") {
		lower := strings.ToLower(line)
		if !strings.Contains(lower, "average") || !strings.Contains(lower, "rate:") {
			continue
		}
		loc := reRateLine.FindStringIndex(line)
		if loc == nil {
			continue
		}
		compact := strings.Join(strings.Fields(line[loc[1]:]), "")

		var numStr, unit string
		if token := reRateToken.FindString(compact); token != "" {
			numStr = stripNonNumeric(token)
			unit = stripNumeric(token)
		} else {
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			last := fields[len(fields)-1]
			numStr, unit = stripNonNumeric(last), stripNumeric(last)
		}
		value, err := strconv.ParseFloat(numStr, 64)
		if err != nil {
			continue
		}
		switch strings.ToUpper(unit) {
		case "GB/S":
			value *= 8000
		case "MB/S":
			value *= 8
		case "KB/S":
			value = value * 8 / 1000
		case "B/S":
			value = value * 8 / 1000000
		default:
			continue
		}
		return fmt.Sprintf("%.1f", value)
	}
	return "failed"
}

// parseCostMs extracts the millisecond value from a "<label>: 123ms" line.
// Returns "-" when the label is absent.
func parseCostMs(output, label string) string {
	label = strings.ToLower(label)
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(strings.ToLower(line), label) {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			continue
		}
		if v := reCostValue.FindString(line[idx+1:]); v != "" {
			return v
		}
	}
	return "-"
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

// stripNumeric keeps only the unit characters of a rate token.
func stripNumeric(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= '0' && r <= '9') || r == '.' || r == ' ' || r == '\t' {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// minReportableMbps is the floor below which a measurement is treated as a
// failure rather than a very slow link.
const minReportableMbps = 0.05

// calcMbps converts a byte delta over a duration in seconds to Mbps.
func calcMbps(bytes int64, seconds float64) string {
	if seconds <= 0 || bytes <= 0 {
		return "failed"
	}
	mbps := float64(bytes) * 8 / seconds / 1000000
	if mbps < minReportableMbps {
		return "failed"
	}
	return fmt.Sprintf("%.1f", mbps)
}

// calcMbpsFromRate converts a bytes-per-second rate to Mbps.
func calcMbpsFromRate(bytesPerSecond float64) string {
	if bytesPerSecond <= 0 {
		return "failed"
	}
	mbps := bytesPerSecond * 8 / 1000000
	if mbps < minReportableMbps {
		return "failed"
	}
	return fmt.Sprintf("%.1f", mbps)
}

// msFromSeconds renders a duration in seconds as integer milliseconds, or "-".
func msFromSeconds(seconds float64) string {
	if seconds <= 0 {
		return "-"
	}
	return strconv.Itoa(int(seconds*1000 + 0.5))
}
