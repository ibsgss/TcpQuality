//go:build linux

package route

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"syscall"
	"time"
)

const (
	maxHops    = 30
	hopTimeout = 2 * time.Second
	hopTries   = 2
)

// Trace performs a native traceroute to destIP using TCP SYN or UDP probes with
// increasing TTL, correlating ICMP time-exceeded / unreachable replies by the
// embedded probe port. psize is the desired total IPv4 payload size hint (used
// for TCP large-packet route probing).
func Trace(ctx context.Context, family, protocol, destIP string, port, psize int) (*TraceResult, error) {
	dst := net.ParseIP(destIP)
	if dst == nil {
		return nil, fmt.Errorf("无效目标 IP: %s", destIP)
	}
	v6 := family == "6"
	if protocol != "udp" {
		protocol = "tcp" // treat nexttrace/tcp large-packet as TCP
	}

	tr := &TraceResult{DestIP: destIP}

	// ICMP receive socket.
	icmpProto := syscall.IPPROTO_ICMP
	domain := syscall.AF_INET
	if v6 {
		icmpProto = syscall.IPPROTO_ICMPV6
		domain = syscall.AF_INET6
	}
	icmpFD, err := syscall.Socket(domain, syscall.SOCK_RAW, icmpProto)
	if err != nil {
		return nil, fmt.Errorf("创建 ICMP socket 失败（需要 root）: %w", err)
	}
	defer syscall.Close(icmpFD)

	// Probe send socket + optional TCP reply socket.
	var sendFD, tcpRecvFD int
	if protocol == "tcp" {
		sendFD, err = syscall.Socket(domain, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
		if err != nil {
			return nil, err
		}
		defer syscall.Close(sendFD)
		tcpRecvFD, err = syscall.Socket(domain, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
		if err != nil {
			return nil, err
		}
		defer syscall.Close(tcpRecvFD)
		if v6 {
			_ = syscall.SetsockoptInt(sendFD, syscall.IPPROTO_IPV6, 0x7 /*IPV6_CHECKSUM*/, 16)
		}
	} else {
		sendFD, err = syscall.Socket(domain, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
		if err != nil {
			return nil, err
		}
		defer syscall.Close(sendFD)
	}

	base := uint16(33000 + rand.Intn(2000))
	srcIP := chooseSource(family, destIP, port)

	for ttl := 1; ttl <= maxHops; ttl++ {
		setTTL(sendFD, v6, ttl)
		hop := Hop{TTL: ttl}
		reached := false
		for try := 0; try < hopTries; try++ {
			id := base + uint16(ttl)
			if err := sendProbe(sendFD, protocol, v6, srcIP, dst, port, id, psize); err != nil {
				break
			}
			ip, done, ok := awaitReply(icmpFD, tcpRecvFD, protocol, v6, destIP, port, id)
			if ok {
				hop.IP = ip
				hop.Responded = true
				reached = done
				break
			}
		}
		tr.Hops = append(tr.Hops, hop)
		if reached {
			tr.Reached = true
			break
		}
		select {
		case <-ctx.Done():
			return tr, ctx.Err()
		default:
		}
	}
	if len(tr.Hops) == 0 {
		return tr, errors.New("traceroute 无结果")
	}
	return tr, nil
}

func chooseSource(family, destIP string, port int) net.IP {
	network := "udp4"
	if family == "6" {
		network = "udp6"
	}
	c, err := net.Dial(network, net.JoinHostPort(destIP, fmt.Sprintf("%d", port)))
	if err != nil {
		return nil
	}
	defer c.Close()
	if ua, ok := c.LocalAddr().(*net.UDPAddr); ok {
		return ua.IP
	}
	return nil
}

func setTTL(fd int, v6 bool, ttl int) {
	if v6 {
		_ = syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl)
		return
	}
	_ = syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_TTL, ttl)
}

// sendProbe sends one probe. For TCP, id is the source port; for UDP, id is the
// destination port. This lets us match the embedded header in ICMP replies.
func sendProbe(fd int, protocol string, v6 bool, srcIP net.IP, dst net.IP, port int, id uint16, psize int) error {
	if protocol == "tcp" {
		header := 40
		if v6 {
			header = 60
		}
		payload := 0
		if psize > header {
			payload = psize - header
		}
		pkt := buildTCPSyn(id, uint16(port), rand.Uint32(), srcIP, dst, payload, v6)
		return sendto(fd, pkt, v6, dst)
	}
	// UDP DGRAM: destination port varies with TTL via id.
	payload := []byte("tcpquality")
	return sendto(fd, payload, v6, dst, int(id))
}

func sendto(fd int, pkt []byte, v6 bool, dst net.IP, port ...int) error {
	p := 0
	if len(port) > 0 {
		p = port[0]
	}
	if v6 {
		var a [16]byte
		copy(a[:], dst.To16())
		return syscall.Sendto(fd, pkt, 0, &syscall.SockaddrInet6{Addr: a, Port: p})
	}
	var a [4]byte
	copy(a[:], dst.To4())
	return syscall.Sendto(fd, pkt, 0, &syscall.SockaddrInet4{Addr: a, Port: p})
}

// buildTCPSyn crafts a TCP SYN segment for traceroute (route-package local copy
// of the probe-package helper, to keep the packages independent).
func buildTCPSyn(srcPort, dstPort uint16, seq uint32, srcIP, dstIP net.IP, payloadLen int, v6 bool) []byte {
	pkt := make([]byte, 20+payloadLen)
	binary.BigEndian.PutUint16(pkt[0:2], srcPort)
	binary.BigEndian.PutUint16(pkt[2:4], dstPort)
	binary.BigEndian.PutUint32(pkt[4:8], seq)
	pkt[12] = 5 << 4
	pkt[13] = 0x02
	binary.BigEndian.PutUint16(pkt[14:16], 64240)
	if !v6 {
		var src, dst [4]byte
		if srcIP != nil {
			copy(src[:], srcIP.To4())
		}
		if dstIP != nil {
			copy(dst[:], dstIP.To4())
		}
		binary.BigEndian.PutUint16(pkt[16:18], tcpChecksumV4(src, dst, pkt))
	}
	return pkt
}

func tcpChecksumV4(src, dst [4]byte, tcp []byte) uint16 {
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
	pseudo[9] = 6
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(tcp)))
	add(pseudo)
	add(tcp)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

// awaitReply waits up to hopTimeout for an ICMP time-exceeded / unreachable that
// matches our probe id, or a direct TCP reply from the destination. It returns
// the hop IP, whether the destination was reached, and whether anything matched.
func awaitReply(icmpFD, tcpRecvFD int, protocol string, v6 bool, destIP string, port int, id uint16) (string, bool, bool) {
	deadline := time.Now().Add(hopTimeout)
	buf := make([]byte, 1500)
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			return "", false, false
		}
		var rset syscall.FdSet
		maxFD := icmpFD
		fdSet(&rset, icmpFD)
		if protocol == "tcp" && tcpRecvFD > 0 {
			fdSet(&rset, tcpRecvFD)
			if tcpRecvFD > maxFD {
				maxFD = tcpRecvFD
			}
		}
		tv := syscall.NsecToTimeval(remain.Nanoseconds())
		n, err := syscall.Select(maxFD+1, &rset, nil, nil, &tv)
		if err != nil || n <= 0 {
			return "", false, false
		}
		if protocol == "tcp" && tcpRecvFD > 0 && fdIsSet(&rset, tcpRecvFD) {
			if hop, ok := readTCPReply(tcpRecvFD, buf, v6, destIP, id); ok {
				return hop, true, true
			}
		}
		if fdIsSet(&rset, icmpFD) {
			if hop, reached, ok := readICMP(icmpFD, buf, protocol, v6, destIP, id); ok {
				return hop, reached, true
			}
		}
	}
}

func readTCPReply(fd int, buf []byte, v6 bool, destIP string, id uint16) (string, bool) {
	n, from, err := syscall.Recvfrom(fd, buf, 0)
	if err != nil || n < 20 {
		return "", false
	}
	peer := sockaddrIP(from)
	tcp := buf[:n]
	if !v6 {
		ihl := int(buf[0]&0x0f) * 4
		if n < ihl+20 {
			return "", false
		}
		tcp = buf[ihl:n]
	}
	dstPort := binary.BigEndian.Uint16(tcp[2:4])
	if dstPort == id && peer == destIP {
		return destIP, true
	}
	return "", false
}

func readICMP(fd int, buf []byte, protocol string, v6 bool, destIP string, id uint16) (string, bool, bool) {
	n, from, err := syscall.Recvfrom(fd, buf, 0)
	if err != nil || n <= 0 {
		return "", false, false
	}
	if v6 {
		return parseICMPv6(buf[:n], sockaddrIP(from), protocol, destIP, id)
	}
	return parseICMPv4(buf[:n], protocol, destIP, id)
}

func parseICMPv4(buf []byte, protocol, destIP string, id uint16) (string, bool, bool) {
	if len(buf) < 20 {
		return "", false, false
	}
	ihl := int(buf[0]&0x0f) * 4
	if len(buf) < ihl+8+20 {
		return "", false, false
	}
	icmpType := buf[ihl]
	hopIP := net.IP(buf[12:16]).String()
	if icmpType != 11 && icmpType != 3 { // time-exceeded / dest-unreachable
		return "", false, false
	}
	// embedded original IPv4 packet
	orig := buf[ihl+8:]
	if len(orig) < 20 {
		return "", false, false
	}
	origIHL := int(orig[0]&0x0f) * 4
	if len(orig) < origIHL+8 {
		return "", false, false
	}
	trans := orig[origIHL:]
	if !matchEmbedded(trans, protocol, id) {
		return "", false, false
	}
	reached := icmpType == 3 || hopIP == destIP
	return hopIP, reached, true
}

func parseICMPv6(buf []byte, peer, protocol, destIP string, id uint16) (string, bool, bool) {
	if len(buf) < 8+40+8 {
		return "", false, false
	}
	icmpType := buf[0]
	if icmpType != 3 && icmpType != 1 { // time-exceeded / dest-unreachable
		return "", false, false
	}
	trans := buf[8+40:]
	if !matchEmbedded(trans, protocol, id) {
		return "", false, false
	}
	reached := icmpType == 1 || peer == destIP
	return peer, reached, true
}

// matchEmbedded checks the embedded transport header of an ICMP error against
// our probe id (TCP source port or UDP destination port).
func matchEmbedded(trans []byte, protocol string, id uint16) bool {
	if len(trans) < 4 {
		return false
	}
	if protocol == "tcp" {
		return binary.BigEndian.Uint16(trans[0:2]) == id // source port
	}
	return binary.BigEndian.Uint16(trans[2:4]) == id // UDP destination port
}

func sockaddrIP(sa syscall.Sockaddr) string {
	switch a := sa.(type) {
	case *syscall.SockaddrInet4:
		return net.IP(a.Addr[:]).String()
	case *syscall.SockaddrInet6:
		return net.IP(a.Addr[:]).String()
	}
	return ""
}

func fdSet(set *syscall.FdSet, fd int) {
	set.Bits[fd/64] |= 1 << (uint(fd) % 64)
}

func fdIsSet(set *syscall.FdSet, fd int) bool {
	return set.Bits[fd/64]&(1<<(uint(fd)%64)) != 0
}
