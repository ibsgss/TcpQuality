package speedtest

import (
	"os"
	"strconv"
	"strings"
)

// endpointWindowBytes is the TOS endpoint's advertised maximum window; the
// effective window is the smaller of it and the local socket buffer maximum.
const endpointWindowBytes = 16777216

// readSysctl reads a dotted sysctl key from /proc/sys, normalizing whitespace.
func readSysctl(key string) string {
	data, err := os.ReadFile("/proc/sys/" + strings.ReplaceAll(key, ".", "/"))
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(data)), " ")
}

// tcpWindowBytes takes the third field of a tcp_rmem/tcp_wmem triple (the
// maximum), or "-".
func tcpWindowBytes(values string) string {
	parts := strings.Fields(values)
	if len(parts) < 3 {
		return "-"
	}
	if _, err := strconv.Atoi(parts[2]); err != nil {
		return "-"
	}
	return parts[2]
}

// minWindowBytes returns the smaller of the local and endpoint window limits.
func minWindowBytes(local string, endpoint int) string {
	n, err := strconv.Atoi(local)
	if err != nil {
		return strconv.Itoa(endpoint)
	}
	if n < endpoint {
		return local
	}
	return strconv.Itoa(endpoint)
}

// readTCPConfig snapshots the kernel TCP tuning that shaped the measurement.
func readTCPConfig() TCPConfig {
	rmem := readSysctl("net.ipv4.tcp_rmem")
	wmem := readSysctl("net.ipv4.tcp_wmem")
	qdisc := readSysctl("net.core.default_qdisc")
	if qdisc == "" {
		qdisc = "-"
	}
	return TCPConfig{
		CongestionControl: readSysctl("net.ipv4.tcp_congestion_control"),
		Qdisc:             qdisc,
		Rmem:              rmem,
		Wmem:              wmem,
		RecvWindowBytes:   minWindowBytes(tcpWindowBytes(rmem), endpointWindowBytes),
		SendWindowBytes:   minWindowBytes(tcpWindowBytes(wmem), endpointWindowBytes),
		WindowScaling:     readSysctl("net.ipv4.tcp_window_scaling"),
		ModerateRcvbuf:    readSysctl("net.ipv4.tcp_moderate_rcvbuf"),
	}
}
