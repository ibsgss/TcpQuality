package probe

import (
	"encoding/binary"
	"net"
)

const protoTCP = 6

// extractReplyPort returns the TCP destination port of an inbound reply. For
// IPv4 the buffer includes the IP header; for IPv6 it starts at the TCP header.
func extractReplyPort(buf []byte, family string) (uint16, bool) {
	tcp := buf
	if family != "6" {
		if len(buf) < 20 {
			return 0, false
		}
		ihl := int(buf[0]&0x0f) * 4
		if ihl < 20 || len(buf) < ihl+20 {
			return 0, false
		}
		if buf[9] != protoTCP {
			return 0, false
		}
		tcp = buf[ihl:]
	}
	if len(tcp) < 20 {
		return 0, false
	}
	// Any TCP packet arriving at our ephemeral source port (SYN-ACK or RST)
	// counts as the peer having answered.
	return binary.BigEndian.Uint16(tcp[2:4]), true
}

// buildTCPSyn constructs a TCP SYN segment (+ payload). When v6 is true the
// checksum is left zero for the kernel to fill; otherwise it is computed with an
// IPv4 pseudo-header.
func buildTCPSyn(srcPort, dstPort uint16, seq uint32, srcIP, dstIP net.IP, payloadLen int, v6 bool) []byte {
	const tcpHeaderLen = 20
	pkt := make([]byte, tcpHeaderLen+payloadLen)
	binary.BigEndian.PutUint16(pkt[0:2], srcPort)
	binary.BigEndian.PutUint16(pkt[2:4], dstPort)
	binary.BigEndian.PutUint32(pkt[4:8], seq)
	// ack (8:12) = 0
	pkt[12] = 5 << 4                              // data offset = 5 words, no options
	pkt[13] = 0x02                                // SYN
	binary.BigEndian.PutUint16(pkt[14:16], 64240) // window
	// checksum (16:18) filled below; urgent (18:20) = 0

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

// tcpChecksumV4 computes the TCP checksum over the IPv4 pseudo-header + segment.
func tcpChecksumV4(src, dst [4]byte, tcp []byte) uint16 {
	var sum uint32
	addBytes := func(b []byte) {
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
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(tcp)))
	addBytes(pseudo)
	addBytes(tcp)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}
