package nodes

import (
	"strings"
	"testing"
)

const sampleTSV = "type\tfamily\tprov\tisp\thost\tip\tport\ttarget\tbackup_host\tbackup_ip\tbackup_port\tbackup_target\n" +
	"cdn\t4\t北京\t电信\tbj.example.com\t1.2.3.4\t80\t\tbj-bak.example.com\t5.6.7.8\t\t\n" +
	"cdn\t6\t上海\t联通\tsh.example.com\t2400:9380::1\t\t\t\t\t\t\n" +
	"cernet\t4\t广东\t教育网\tgd.edu.cn\t202.112.0.1\t443\t\t\t\t\t\n" +
	"cernet2\t6\t江苏\t教育网\tjs.edu.cn\t2001:da8::1\t\t\t\t\t\t\n" +
	"tos\t4\t北京\t电信\t\t42.81.80.86\t\t\t\t\t\t\n" +
	"tos\t4\t天津\tCU\t\t221.194.175.109\t\t\t\t\t\t\n" +
	"junk\t4\t\t\t\t\t\t\t\t\t\t\n" +
	"cdn\t4\t河北\t移动\tnoip.example.com\t\t80\t\t\t\t\t\n"

func TestParse(t *testing.T) {
	set, err := Parse(strings.NewReader(sampleTSV))
	if err != nil {
		t.Fatal(err)
	}
	if len(set.CDN4) != 1 {
		t.Fatalf("CDN4 count = %d, want 1", len(set.CDN4))
	}
	n := set.CDN4[0]
	if n.Province != "北京" || n.ISP != "电信" || n.IP != "1.2.3.4" || n.Port != "80" {
		t.Errorf("CDN4[0] parsed wrong: %+v", n)
	}
	if n.BackupIP != "5.6.7.8" || n.BackupPort != "80" {
		t.Errorf("CDN4[0] backup wrong: %+v", n)
	}
	if len(set.CDN6) != 1 || set.CDN6[0].Port != "80" {
		t.Errorf("CDN6 parse wrong: %+v", set.CDN6)
	}
	if len(set.CERNET) != 1 || set.CERNET[0].ISP != "教育网" || set.CERNET[0].BackupPort != "443" {
		t.Errorf("CERNET parse wrong: %+v", set.CERNET)
	}
	if len(set.CERNET2) != 1 || set.CERNET2[0].Port != "80" {
		t.Errorf("CERNET2 parse wrong: %+v", set.CERNET2)
	}
	if len(set.TOS) != 2 {
		t.Fatalf("TOS count = %d, want 2", len(set.TOS))
	}
	if set.TOS[0].ISP != "电信" || set.TOS[0].City != "北京" {
		t.Errorf("TOS[0] wrong: %+v", set.TOS[0])
	}
	if set.TOS[1].ISP != "联通" {
		t.Errorf("TOS[1] carrier normalization wrong: %+v", set.TOS[1])
	}
}

func TestParseSkipsNoIP(t *testing.T) {
	set, _ := Parse(strings.NewReader(sampleTSV))
	for _, n := range set.CDN4 {
		if n.IP == "" {
			t.Error("node with empty IP should be skipped")
		}
	}
}

func TestBuildURL(t *testing.T) {
	if got := buildURL("https://x/getNodes", "v4"); got != "https://x/getNodes?format=tsv&scope=v4" {
		t.Errorf("buildURL = %q", got)
	}
	if got := buildURL("https://x/getNodes?a=1", "all"); got != "https://x/getNodes?a=1&format=tsv&scope=all" {
		t.Errorf("buildURL with query = %q", got)
	}
}

func TestSetCDN(t *testing.T) {
	set, _ := Parse(strings.NewReader(sampleTSV))
	if len(set.CDN("6")) != 1 || len(set.CDN("4")) != 1 {
		t.Error("CDN accessor returned wrong family")
	}
}
