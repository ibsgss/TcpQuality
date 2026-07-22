package config

import (
	"errors"
	"fmt"
	"strconv"
)

// ErrHelp is returned by ParseArgs when -h/--help is requested.
var ErrHelp = errors.New("help requested")

// ParseArgs mutates the Config according to argv (excluding the program name),
// mirroring parse_args in the original script. It returns ErrHelp for the help
// flag, or a descriptive error for invalid input.
func (c *Config) ParseArgs(args []string) error {
	i := 0
	next := func() (string, bool) {
		if i+1 < len(args) {
			return args[i+1], true
		}
		return "", false
	}
	for i = 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			return ErrHelp
		case "-c", "--count":
			v, ok := next()
			n, err := strconv.Atoi(v)
			if !ok || err != nil || n < 1 || n > MaxPackets {
				return fmt.Errorf("发包数必须是 1-%d 之间的整数", MaxPackets)
			}
			c.Packets = n
			c.CountExplicit = true
			i++
		case "-s", "--size":
			v, ok := next()
			n, err := strconv.Atoi(v)
			if !ok || err != nil || n < 0 || n > 65535 {
				return errors.New("包长必须是 0-65535 之间的整数（单位 B）")
			}
			c.PacketSizeOverride = strconv.Itoa(n)
			i++
		case "-p", "--parallel":
			v, ok := next()
			n, err := strconv.Atoi(v)
			if !ok || err != nil || n < 1 || n > MaxParallel {
				return errors.New("并行节点数必须是 1-31 之间的整数")
			}
			c.Parallel = n
			i++
		case "-v4", "--v4":
			c.OnlyIPv4 = true
		case "-v6", "--v6":
			c.OnlyIPv6 = true
		case "--only-large":
			c.OnlyLarge = true
		case "--cernet":
			c.TestCernet = true
		case "--all":
			c.TestAll = true
			c.SpeedtestEnabled = true
			c.InternationalEnabled = true
		case "--route":
			c.RouteMode = true
			c.UploadReport = false
		case "--route-protocol":
			v, ok := next()
			if !ok || (v != "tcp" && v != "udp" && v != "both") {
				return errors.New("--route-protocol 只支持 tcp、udp、both")
			}
			c.RouteProtocol = v
			i++
		case "--speedtest":
			c.SpeedtestEnabled = true
		case "--only-speedtest":
			c.SpeedtestEnabled = true
			c.SpeedtestOnly = true
		case "--intl":
			c.IntlRequested = true
			c.InternationalEnabled = true
			c.UploadReport = true
		case "--debug":
			c.DebugMode = true
		case "--province":
			v, ok := next()
			if !ok || !c.AddProvinceFilter(v) {
				return fmt.Errorf("不支持的省份代码: %s", v)
			}
			i++
		default:
			// -xx / -xxx shorthand province flags (e.g. -bj, -gd).
			if (len(arg) == 3 || len(arg) == 4) && arg[0] == '-' {
				if c.AddProvinceFilter(arg) {
					continue
				}
			}
			return fmt.Errorf("不支持的参数: %s", arg)
		}
	}

	c.applyDerived()
	return nil
}

// applyDerived reproduces the post-parse normalization in parse_args.
func (c *Config) applyDerived() {
	if c.OnlyLarge {
		c.OnlyIPv4 = true
		c.OnlyIPv6 = false
		c.TestCernet = false
		c.TestAll = false
		c.RouteMode = false
		c.SpeedtestEnabled = false
		c.SpeedtestOnly = false
		c.InternationalEnabled = false
		c.InternationalOnly = false
	}

	if c.IntlRequested &&
		!c.OnlyLarge && !c.OnlyIPv4 && !c.OnlyIPv6 &&
		!c.TestCernet && !c.TestAll && !c.RouteMode &&
		!c.SpeedtestEnabled && !c.HasProvinceFilter() {
		c.InternationalOnly = true
	}
}

// HelpText returns the CLI help message.
func HelpText() string {
	return fmt.Sprintf(`TcpQuality 节点 TCP 丢包探测脚本 (Go 版)

用法:
  tcpquality [选项]

选项:
  -h, --help        显示帮助信息并退出
  -c, --count NUM   设置每节点发包数，范围 1-%d，默认 %d
  -s, --size NUM    指定 IP 包总长度（单位 B），0 为标准无负载 SYN；默认 0
  -p, --parallel NUM
                     设置并行节点数，范围 1-%d，默认 %d
  -v4, --v4         仅探测 IPv4
  -v6, --v6         仅探测 IPv6
  --only-large      仅探测 IPv4大包回程质量(beta)
  --cernet          仅探测 CERNET IPv4 和 CERNET2 IPv6
  --all             探测 IPv4/IPv6、CERNET/CERNET2、国际互联和国内三网单线程测速
  --route           仅做三网回程线路识别，不执行 SYN 丢包探测、不上传报告
  --route-protocol PROTO
                    设置 --route 的 traceroute 协议: tcp、udp、both，默认 tcp
  --speedtest       追加国内三网单线程测速
  --only-speedtest  仅运行国内三网单线程测速
  --intl            单独使用时仅运行国际互联；与 -v4/-v6/--all 等组合时追加国际互联
  --province CODE   仅检测指定省份，可重复；也支持简写参数如 -bj、-sh、-gd
                     注意: 山西使用 -sx，陕西使用 -sn
  --debug           保留调试信息，便于排查线路识别问题

说明:
  发送裸 TCP SYN 包通常需要 root 权限；请切换到 root 用户后运行。
`, MaxPackets, DefaultPackets, MaxParallel, DefaultParallel)
}
