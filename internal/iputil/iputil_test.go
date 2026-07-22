package iputil

import "testing"

func TestIsPublicIPv4(t *testing.T) {
	public := []string{"1.1.1.1", "8.8.8.8", "203.0.114.1", "202.97.1.1", "100.63.0.1", "100.128.0.1"}
	private := []string{
		"0.0.0.1", "10.0.0.1", "127.0.0.1", "224.0.0.1", "240.0.0.1",
		"100.64.0.1", "100.127.255.1", "169.254.1.1", "172.16.0.1", "172.31.255.1",
		"192.168.1.1", "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.19.0.1",
		"198.51.100.1", "203.0.113.1", "not-an-ip", "1.2.3", "256.1.1.1", "::1",
	}
	for _, ip := range public {
		if !IsPublicIPv4(ip) {
			t.Errorf("IsPublicIPv4(%q) = false, want true", ip)
		}
	}
	for _, ip := range private {
		if IsPublicIPv4(ip) {
			t.Errorf("IsPublicIPv4(%q) = true, want false", ip)
		}
	}
}

func TestIsValidIPv6(t *testing.T) {
	valid := []string{"2400:9380::1", "2408:8000::1", "240e::1", "2001:4860:4860::8888"}
	invalid := []string{
		"::1", "fe80::1", "fc00::1", "fd00::1", "2001:db8::1",
		"::ffff:1.2.3.4", "2002::1", "1.2.3.4", "", "nonsense",
	}
	for _, ip := range valid {
		if !IsValidIPv6(ip) {
			t.Errorf("IsValidIPv6(%q) = false, want true", ip)
		}
	}
	for _, ip := range invalid {
		if IsValidIPv6(ip) {
			t.Errorf("IsValidIPv6(%q) = true, want false", ip)
		}
	}
}
