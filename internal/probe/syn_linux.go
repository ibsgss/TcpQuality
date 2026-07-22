//go:build linux

package probe

import (
	"fmt"
	"math/rand"
	"net"
	"sync"
	"syscall"
	"time"
)

// probeTimeout is the per-SYN wait for a reply before it counts as loss,
// matching nping's default 1s RTT timeout.
const probeTimeout = time.Second

// rawSender crafts and sends TCP SYNs on a raw socket and demultiplexes replies
// by our (unique) source port through a background receiver goroutine.
type rawSender struct {
	family string
	sendFD int
	recvFD int

	mu       sync.Mutex
	waiters  map[uint16]chan time.Time
	portNext uint32
	srcCache map[string]net.IP // dstIP -> chosen source IP (v4 checksum)

	closed chan struct{}
	rng    *rand.Rand
	rngMu  sync.Mutex
}

func newSender(family string) (synSender, error) {
	domain := syscall.AF_INET
	if family == "6" {
		domain = syscall.AF_INET6
	}
	sendFD, err := syscall.Socket(domain, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		return nil, fmt.Errorf("创建发送 raw socket 失败（需要 root）: %w", err)
	}
	recvFD, err := syscall.Socket(domain, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		syscall.Close(sendFD)
		return nil, fmt.Errorf("创建接收 raw socket 失败: %w", err)
	}
	if family == "6" {
		// Ask the kernel to compute the TCP checksum (offset 16 in the header).
		if err := syscall.SetsockoptInt(sendFD, syscall.IPPROTO_IPV6, ipv6Checksum, 16); err != nil {
			syscall.Close(sendFD)
			syscall.Close(recvFD)
			return nil, fmt.Errorf("设置 IPV6_CHECKSUM 失败: %w", err)
		}
	}
	s := &rawSender{
		family:   family,
		sendFD:   sendFD,
		recvFD:   recvFD,
		waiters:  make(map[uint16]chan time.Time),
		portNext: uint32(20000 + rand.Intn(1000)),
		srcCache: make(map[string]net.IP),
		closed:   make(chan struct{}),
		rng:      rand.New(rand.NewSource(rand.Int63())),
	}
	go s.receiveLoop()
	return s, nil
}

const ipv6Checksum = 0x7 // IPV6_CHECKSUM

func (s *rawSender) Close() error {
	select {
	case <-s.closed:
	default:
		close(s.closed)
	}
	syscall.Close(s.recvFD) // unblocks receiveLoop
	syscall.Close(s.sendFD)
	return nil
}

// allocPort returns a source port not currently registered and registers a
// reply channel for it.
func (s *rawSender) allocPort() (uint16, chan time.Time) {
	ch := make(chan time.Time, 1)
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		s.portNext++
		if s.portNext > 60000 {
			s.portNext = 20000
		}
		p := uint16(s.portNext)
		if _, exists := s.waiters[p]; !exists {
			s.waiters[p] = ch
			return p, ch
		}
	}
}

func (s *rawSender) freePort(p uint16) {
	s.mu.Lock()
	delete(s.waiters, p)
	s.mu.Unlock()
}

func (s *rawSender) sourceIP(dstIP string, dstPort int) net.IP {
	s.mu.Lock()
	if ip, ok := s.srcCache[dstIP]; ok {
		s.mu.Unlock()
		return ip
	}
	s.mu.Unlock()
	network := "udp4"
	if s.family == "6" {
		network = "udp6"
	}
	var src net.IP
	if c, err := net.Dial(network, net.JoinHostPort(dstIP, fmt.Sprintf("%d", dstPort))); err == nil {
		if ua, ok := c.LocalAddr().(*net.UDPAddr); ok {
			src = ua.IP
		}
		c.Close()
	}
	s.mu.Lock()
	s.srcCache[dstIP] = src
	s.mu.Unlock()
	return src
}

func (s *rawSender) randUint32() uint32 {
	s.rngMu.Lock()
	defer s.rngMu.Unlock()
	return s.rng.Uint32()
}

// ProbeOnce sends one SYN and waits for a reply.
func (s *rawSender) ProbeOnce(ip string, port, size int) (float64, bool, error) {
	dst := net.ParseIP(ip)
	if dst == nil {
		return 0, false, fmt.Errorf("无效目标 IP: %s", ip)
	}
	payloadLen := 0
	header := 40
	if s.family == "6" {
		header = 60
	}
	if size > header {
		payloadLen = size - header
	}

	srcPort, ch := s.allocPort()
	defer s.freePort(srcPort)

	seq := s.randUint32()
	var pkt []byte
	var sa syscall.Sockaddr
	if s.family == "6" {
		pkt = buildTCPSyn(srcPort, uint16(port), seq, nil, nil, payloadLen, true)
		var a [16]byte
		copy(a[:], dst.To16())
		sa = &syscall.SockaddrInet6{Addr: a}
	} else {
		src := s.sourceIP(ip, port)
		pkt = buildTCPSyn(srcPort, uint16(port), seq, src, dst, payloadLen, false)
		var a [4]byte
		copy(a[:], dst.To4())
		sa = &syscall.SockaddrInet4{Addr: a}
	}

	start := time.Now()
	if err := syscall.Sendto(s.sendFD, pkt, 0, sa); err != nil {
		return 0, false, fmt.Errorf("发送 SYN 失败: %w", err)
	}

	select {
	case t := <-ch:
		return float64(t.Sub(start).Microseconds()) / 1000.0, true, nil
	case <-time.After(probeTimeout):
		return 0, false, nil
	case <-s.closed:
		return 0, false, nil
	}
}

// receiveLoop reads inbound TCP packets and dispatches them to the waiter keyed
// by the TCP destination port (our probe's source port).
func (s *rawSender) receiveLoop() {
	buf := make([]byte, 65535)
	for {
		n, _, err := syscall.Recvfrom(s.recvFD, buf, 0)
		if err != nil {
			select {
			case <-s.closed:
				return
			default:
				continue
			}
		}
		dstPort, ok := extractReplyPort(buf[:n], s.family)
		if !ok {
			continue
		}
		now := time.Now()
		s.mu.Lock()
		ch := s.waiters[dstPort]
		s.mu.Unlock()
		if ch != nil {
			select {
			case ch <- now:
			default:
			}
		}
	}
}
