package route

import "testing"

func TestClassify(t *testing.T) {
	cases := []struct {
		name   string
		hops   []string
		asnMap map[string]string
		dest   string
		isp    string
		want   string
	}{
		{"CN2GIA", []string{"59.43.1.1"}, nil, "1.2.3.4", "电信", "CN2GIA"},
		{"CN2GT", []string{"59.43.245.1", "202.97.1.1"}, nil, "1.2.3.4", "电信", "CN2GT"},
		{"CTGGIA", []string{"59.43.1.1", "203.22.182.1"}, nil, "1.2.3.4", "电信", "CTGGIA"},
		{"163", []string{"202.97.1.1"}, nil, "1.2.3.4", "电信", "163"},
		{"4837", []string{"219.158.1.1"}, nil, "1.2.3.4", "联通", "4837"},
		{"9929", []string{"210.14.1.1"}, nil, "1.2.3.4", "联通", "9929"},
		{"10099->4837", []string{"103.214.1.1", "219.158.1.1"}, nil, "1.2.3.4", "联通", "10099->4837"},
		{"10099 alone", []string{"103.214.1.1"}, nil, "1.2.3.4", "联通", "10099"},
		{"CMI", []string{"223.120.1.1"}, nil, "1.2.3.4", "移动", "CMI"},
		{"CMIN2", []string{"1.1.1.1"}, map[string]string{"1.1.1.1": "58807"}, "1.2.3.4", "移动", "CMIN2"},
		{"CERNET", []string{"202.112.0.1"}, nil, "1.2.3.4", "", "CERNET"},
		{"CERNET2", []string{"2001:252::1"}, nil, "2001:252::9", "", "CERNET2"},
		{"CSTNET", []string{"159.226.1.1"}, nil, "1.2.3.4", "", "CSTNET"},
		{"Hidden", []string{"8.8.8.8"}, nil, "8.8.8.8", "电信", "Hidden"},
		{"empty", nil, nil, "", "电信", "Hidden"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Classify(tc.hops, tc.asnMap, tc.dest, tc.isp)
			if got != tc.want {
				t.Errorf("Classify(%v) = %q, want %q", tc.hops, got, tc.want)
			}
		})
	}
}

func TestClassifyDedupesHops(t *testing.T) {
	// Repeated hop IPs collapse to a single hop.
	got := Classify([]string{"202.97.1.1", "202.97.1.1", "202.97.1.1"}, nil, "1.2.3.4", "电信")
	if got != "163" {
		t.Errorf("dedup classify = %q, want 163", got)
	}
}

func TestInferASNFromIP(t *testing.T) {
	cases := map[string]string{
		"59.43.1.1":     "4809",
		"203.22.182.5":  "23764",
		"2400:9380::1":  "23764",
		"202.97.1.1":    "4134",
		"240e::1":       "4134",
		"219.158.1.1":   "4837",
		"2408::1":       "4837",
		"223.120.1.1":   "58453",
		"221.183.1.1":   "9808",
		"103.214.1.1":   "10099",
		"162.219.34.1":  "10099",
		"162.219.85.1":  "10099",
		"210.14.1.1":    "9929",
		"202.112.0.1":   "4538",
		"2001:252::1":   "23911",
		"2001:da8::1":   "23910",
		"159.226.1.1":   "7497",
		"8.8.8.8":       "",
		"162.219.100.1": "",
	}
	for ip, want := range cases {
		if got := inferASNFromIP(ip); got != want {
			t.Errorf("inferASNFromIP(%q) = %q, want %q", ip, got, want)
		}
	}
}
