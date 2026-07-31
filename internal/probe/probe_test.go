package probe

import (
	"math"
	"net"
	"testing"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

func TestResultLine(t *testing.T) {
	r := Result{Status: StatusOK, Province: "北京", ISP: "电信", Host: "h", IP: "1.2.3.4",
		Sent: 30, Rcvd: 29, LossPct: 3.33, AvgRTT: 12.345}
	want := "OK|北京|电信|h|1.2.3.4|30|29|3.33|12.345"
	if got := r.Line(); got != want {
		t.Errorf("Line() = %q, want %q", got, want)
	}
	f := Result{Status: StatusFail, Province: "北京", ISP: "电信", Host: "h", LossPct: 100, Detail: "GETNODES"}
	if got := f.Line(); got != "FAIL|北京|电信|h|GETNODES|0|0|100.00|0.000" {
		t.Errorf("fail Line() = %q", got)
	}
}

func TestShouldProbeBackup(t *testing.T) {
	if ShouldProbeBackup(Result{Status: StatusOK, LossPct: 10}) {
		t.Error("loss 10 should not trigger backup")
	}
	if !ShouldProbeBackup(Result{Status: StatusOK, LossPct: 16}) {
		t.Error("loss 16 should trigger backup")
	}
	if !ShouldProbeBackup(Result{Status: StatusFail}) {
		t.Error("failed primary should trigger backup")
	}
}

func TestCombine(t *testing.T) {
	p := Result{Status: StatusOK, Province: "京", ISP: "电信", Host: "h", IP: "1.1.1.1", Sent: 30, Rcvd: 24, LossPct: 20, AvgRTT: 30}
	b := Result{Status: StatusOK, Sent: 30, Rcvd: 30, LossPct: 0, AvgRTT: 50}
	c := Combine(p, b)
	if c.Sent != 60 || c.Rcvd != 54 {
		t.Errorf("combine sent/rcvd = %d/%d", c.Sent, c.Rcvd)
	}
	if !approx(c.LossPct, 10) || !approx(c.AvgRTT, 40) {
		t.Errorf("combine loss/rtt = %v/%v", c.LossPct, c.AvgRTT)
	}
	if c.Province != "京" || c.IP != "1.1.1.1" {
		t.Error("combine should keep primary identity")
	}
	// latency picking: only primary has rtt
	c2 := Combine(
		Result{Status: StatusOK, AvgRTT: 20},
		Result{Status: StatusOK, AvgRTT: 0})
	if !approx(c2.AvgRTT, 20) {
		t.Errorf("combine rtt fallback = %v", c2.AvgRTT)
	}
	// non-OK backup returns backup
	if Combine(p, Result{Status: StatusFail}).Status != StatusFail {
		t.Error("combine with failed backup should return backup")
	}
}

func TestDecideWithBackup(t *testing.T) {
	primaryFail := Result{Status: StatusFail, LossPct: 100}
	backupOK := Result{Status: StatusOK, LossPct: 0, IP: "b"}
	if got := DecideWithBackup(primaryFail, backupOK); got.IP != "b" {
		t.Error("failed primary should yield backup")
	}
	// primary loss 100 -> backup
	if got := DecideWithBackup(Result{Status: StatusOK, LossPct: 100}, backupOK); got.IP != "b" {
		t.Error("primary loss 100 should yield backup")
	}
	// primary partial, backup OK zero loss -> backup
	if got := DecideWithBackup(Result{Status: StatusOK, LossPct: 50, IP: "p"}, backupOK); got.IP != "b" {
		t.Error("backup zero-loss should win")
	}
	// primary partial, backup OK with loss -> combine
	got := DecideWithBackup(
		Result{Status: StatusOK, LossPct: 50, Sent: 10, Rcvd: 5, IP: "p"},
		Result{Status: StatusOK, LossPct: 20, Sent: 10, Rcvd: 8})
	if got.Sent != 20 {
		t.Error("partial primary + lossy backup should combine")
	}
	// primary partial, backup failed -> primary
	if got := DecideWithBackup(Result{Status: StatusOK, LossPct: 50, IP: "p"}, Result{Status: StatusFail}); got.IP != "p" {
		t.Error("failed backup should fall back to primary")
	}
}

func TestTCPChecksumV4(t *testing.T) {
	// The checksum, when re-summed over pseudo-header + segment, must yield the
	// ones-complement all-ones (verification property).
	src := [4]byte{192, 0, 2, 1}
	dst := [4]byte{198, 51, 100, 2}
	pkt := buildTCPSyn(40000, 443, 0x12345678, net.IPv4(192, 0, 2, 1), net.IPv4(198, 51, 100, 2), 20, false)
	if len(pkt) != 40 {
		t.Fatalf("packet len = %d, want 40", len(pkt))
	}
	if got := verifyChecksum(src, dst, pkt); got != 0xffff {
		t.Errorf("checksum verification = %#x, want 0xffff", got)
	}
	// SYN flag present
	if pkt[13] != 0x02 {
		t.Errorf("flags = %#x, want SYN", pkt[13])
	}
}

// verifyChecksum re-sums the pseudo-header and segment (with checksum in place),
// which should collapse to all-ones for a valid checksum.
func verifyChecksum(src, dst [4]byte, tcp []byte) uint16 {
	var sum uint32
	add := func(b []byte) {
		for i := 0; i+1 < len(b); i += 2 {
			sum += uint32(b[i])<<8 | uint32(b[i+1])
		}
		if len(b)%2 == 1 {
			sum += uint32(b[len(b)-1]) << 8
		}
	}
	pseudo := make([]byte, 12)
	copy(pseudo[0:4], src[:])
	copy(pseudo[4:8], dst[:])
	pseudo[9] = protoTCP
	pseudo[10] = byte(len(tcp) >> 8)
	pseudo[11] = byte(len(tcp))
	add(pseudo)
	add(tcp)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return uint16(sum)
}

func TestExtractReplyPortV4(t *testing.T) {
	// Minimal IPv4 + TCP: IHL=5, proto=6, dst port 40001.
	buf := make([]byte, 40)
	buf[0] = 0x45
	buf[9] = protoTCP
	buf[20+2] = 0x9c // 40001 >> 8
	buf[20+3] = 0x41
	port, ok := extractReplyPort(buf, "4")
	if !ok || port != 40001 {
		t.Errorf("extract v4 = %d,%v", port, ok)
	}
	buf[9] = 17 // UDP
	if _, ok := extractReplyPort(buf, "4"); ok {
		t.Error("non-TCP should be rejected")
	}
}

func TestExtractReplyPortV6(t *testing.T) {
	tcp := make([]byte, 20)
	tcp[2] = 0x9c
	tcp[3] = 0x41
	port, ok := extractReplyPort(tcp, "6")
	if !ok || port != 40001 {
		t.Errorf("extract v6 = %d,%v", port, ok)
	}
}

func TestPacketSizeOverride(t *testing.T) {
	p := &Prober{family: "4", Packets: 5, SizeOverride: "200"}
	bu, su := 0, 0
	if got := p.packetSize(1, 0, &bu, &su); got != 200 {
		t.Errorf("override size = %d, want 200", got)
	}
}
