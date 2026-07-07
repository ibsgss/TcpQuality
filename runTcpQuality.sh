#!/bin/bash
#
# TcpQuality 节点 TCP 丢包探测脚本
# 用法: bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
#
# 每节点发送 60 个裸 TCP SYN 包，无内核重传
# TUI 风格实时展示省份/运营商丢包率
#

set -e

# ===================== 颜色定义 =====================
RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[0;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';     MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  BOLD='\033[1m';        DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'
BG_RED='\033[41m';   BG_GREEN='\033[42m';   BG_YELLOW='\033[43m'

# ===================== 检测并安装 nping =====================
check_nping() {
  if command -v nping &>/dev/null; then
    return 0
  fi
  echo -e "${YELLOW}[!] nping 未安装，正在自动安装...${NC}"
  if command -v apt-get &>/dev/null; then
    if apt-get update -qq && apt-get install -y -qq nmap 2>/dev/null; then :; fi
  elif command -v dnf &>/dev/null; then
    if ! dnf install -y -q nmap 2>/dev/null; then
      echo -e "${YELLOW}[!] 默认软件源未提供 nmap，正在尝试启用 EPEL...${NC}"
      if dnf install -y -q epel-release 2>/dev/null && dnf install -y -q nmap 2>/dev/null; then :; fi
    fi
  elif command -v yum &>/dev/null; then
    if ! yum install -y -q nmap 2>/dev/null; then
      echo -e "${YELLOW}[!] 默认软件源未提供 nmap，正在尝试启用 EPEL...${NC}"
      if yum install -y -q epel-release 2>/dev/null && yum install -y -q nmap 2>/dev/null; then :; fi
    fi
  elif command -v apk &>/dev/null; then
    if ! apk add --no-cache nmap-nping 2>/dev/null; then
      if apk add --no-cache nmap 2>/dev/null; then :; fi
    fi
  elif command -v pacman &>/dev/null; then
    if pacman -Sy --noconfirm nmap 2>/dev/null; then :; fi
  elif command -v brew &>/dev/null; then
    if brew install nmap 2>/dev/null; then :; fi
  else
    echo -e "${RED}[X] 无法自动安装 nping，请手动安装 nmap 包${NC}"
    exit 1
  fi
  if command -v nping &>/dev/null; then
    echo -e "${GREEN}[√] nping 安装成功${NC}"
  else
    echo -e "${RED}[X] nping 安装失败${NC}"
    exit 1
  fi
}

# ===================== 检测并安装 dig =====================
check_dig() {
  if command -v dig &>/dev/null; then
    return 0
  fi
  echo -e "${YELLOW}[!] dig 未安装，正在自动安装...${NC}"
  if command -v apt-get &>/dev/null; then
    if apt-get update -qq && apt-get install -y -qq dnsutils 2>/dev/null; then :; fi
  elif command -v dnf &>/dev/null; then
    if dnf install -y -q bind-utils 2>/dev/null; then :; fi
  elif command -v yum &>/dev/null; then
    if yum install -y -q bind-utils 2>/dev/null; then :; fi
  elif command -v apk &>/dev/null; then
    if apk add --no-cache bind-tools 2>/dev/null; then :; fi
  elif command -v pacman &>/dev/null; then
    if pacman -Sy --noconfirm bind 2>/dev/null; then :; fi
  elif command -v brew &>/dev/null; then
    if brew install bind 2>/dev/null; then
      export PATH="$(brew --prefix bind)/bin:$PATH"
    fi
  else
    echo -e "${RED}[X] 无法自动安装 dig，请手动安装 dnsutils、bind-utils 或 bind${NC}"
    exit 1
  fi
  if command -v dig &>/dev/null; then
    echo -e "${GREEN}[√] dig 安装成功${NC}"
  else
    echo -e "${RED}[X] dig 安装失败${NC}"
    exit 1
  fi
}

# ===================== 节点数据 =====================
NODES=(
  "河北 联通 he-cu-v4.ip.zstaticcdn.com"
  "河北 移动 he-cm-v4.ip.zstaticcdn.com"
  "河北 电信 he-ct-v4.ip.zstaticcdn.com"
  "山西 联通 sx-cu-v4.ip.zstaticcdn.com"
  "山西 移动 sx-cm-v4.ip.zstaticcdn.com"
  "山西 电信 sx-ct-v4.ip.zstaticcdn.com"
  "辽宁 联通 ln-cu-v4.ip.zstaticcdn.com"
  "辽宁 移动 ln-cm-v4.ip.zstaticcdn.com"
  "辽宁 电信 ln-ct-v4.ip.zstaticcdn.com"
  "吉林 联通 jl-cu-v4.ip.zstaticcdn.com"
  "吉林 移动 jl-cm-v4.ip.zstaticcdn.com"
  "吉林 电信 jl-ct-v4.ip.zstaticcdn.com"
  "黑龙江 联通 hl-cu-v4.ip.zstaticcdn.com"
  "黑龙江 移动 hl-cm-v4.ip.zstaticcdn.com"
  "黑龙江 电信 hl-ct-v4.ip.zstaticcdn.com"
  "江苏 联通 js-cu-v4.ip.zstaticcdn.com"
  "江苏 移动 js-cm-v4.ip.zstaticcdn.com"
  "江苏 电信 js-ct-v4.ip.zstaticcdn.com"
  "浙江 联通 zj-cu-v4.ip.zstaticcdn.com"
  "浙江 移动 zj-cm-v4.ip.zstaticcdn.com"
  "浙江 电信 zj-ct-v4.ip.zstaticcdn.com"
  "安徽 联通 ah-cu-v4.ip.zstaticcdn.com"
  "安徽 移动 ah-cm-v4.ip.zstaticcdn.com"
  "安徽 电信 ah-ct-v4.ip.zstaticcdn.com"
  "福建 联通 fj-cu-v4.ip.zstaticcdn.com"
  "福建 移动 fj-cm-v4.ip.zstaticcdn.com"
  "福建 电信 fj-ct-v4.ip.zstaticcdn.com"
  "江西 联通 jx-cu-v4.ip.zstaticcdn.com"
  "江西 移动 jx-cm-v4.ip.zstaticcdn.com"
  "江西 电信 jx-ct-v4.ip.zstaticcdn.com"
  "山东 联通 sd-cu-v4.ip.zstaticcdn.com"
  "山东 移动 sd-cm-v4.ip.zstaticcdn.com"
  "山东 电信 sd-ct-v4.ip.zstaticcdn.com"
  "河南 联通 ha-cu-v4.ip.zstaticcdn.com"
  "河南 移动 ha-cm-v4.ip.zstaticcdn.com"
  "河南 电信 ha-ct-v4.ip.zstaticcdn.com"
  "湖北 联通 hb-cu-v4.ip.zstaticcdn.com"
  "湖北 移动 hb-cm-v4.ip.zstaticcdn.com"
  "湖北 电信 hb-ct-v4.ip.zstaticcdn.com"
  "湖南 联通 hn-cu-v4.ip.zstaticcdn.com"
  "湖南 移动 hn-cm-v4.ip.zstaticcdn.com"
  "湖南 电信 hn-ct-v4.ip.zstaticcdn.com"
  "广东 联通 gd-cu-v4.ip.zstaticcdn.com"
  "广东 移动 gd-cm-v4.ip.zstaticcdn.com"
  "广东 电信 gd-ct-v4.ip.zstaticcdn.com"
  "海南 联通 hi-cu-v4.ip.zstaticcdn.com"
  "海南 移动 hi-cm-v4.ip.zstaticcdn.com"
  "海南 电信 hi-ct-v4.ip.zstaticcdn.com"
  "四川 联通 sc-cu-v4.ip.zstaticcdn.com"
  "四川 移动 sc-cm-v4.ip.zstaticcdn.com"
  "四川 电信 sc-ct-v4.ip.zstaticcdn.com"
  "贵州 联通 gz-cu-v4.ip.zstaticcdn.com"
  "贵州 移动 gz-cm-v4.ip.zstaticcdn.com"
  "贵州 电信 gz-ct-v4.ip.zstaticcdn.com"
  "云南 联通 yn-cu-v4.ip.zstaticcdn.com"
  "云南 移动 yn-cm-v4.ip.zstaticcdn.com"
  "云南 电信 yn-ct-v4.ip.zstaticcdn.com"
  "陕西 联通 sn-cu-v4.ip.zstaticcdn.com"
  "陕西 移动 sn-cm-v4.ip.zstaticcdn.com"
  "陕西 电信 sn-ct-v4.ip.zstaticcdn.com"
  "甘肃 联通 gs-cu-v4.ip.zstaticcdn.com"
  "甘肃 移动 gs-cm-v4.ip.zstaticcdn.com"
  "甘肃 电信 gs-ct-v4.ip.zstaticcdn.com"
  "青海 联通 qh-cu-v4.ip.zstaticcdn.com"
  "青海 移动 qh-cm-v4.ip.zstaticcdn.com"
  "青海 电信 qh-ct-v4.ip.zstaticcdn.com"
  "内蒙古 联通 nm-cu-v4.ip.zstaticcdn.com"
  "内蒙古 移动 nm-cm-v4.ip.zstaticcdn.com"
  "内蒙古 电信 nm-ct-v4.ip.zstaticcdn.com"
  "广西 联通 gx-cu-v4.ip.zstaticcdn.com"
  "广西 移动 gx-cm-v4.ip.zstaticcdn.com"
  "广西 电信 gx-ct-v4.ip.zstaticcdn.com"
  "西藏 联通 xz-cu-v4.ip.zstaticcdn.com"
  "西藏 移动 xz-cm-v4.ip.zstaticcdn.com"
  "西藏 电信 xz-ct-v4.ip.zstaticcdn.com"
  "宁夏 联通 nx-cu-v4.ip.zstaticcdn.com"
  "宁夏 移动 nx-cm-v4.ip.zstaticcdn.com"
  "宁夏 电信 nx-ct-v4.ip.zstaticcdn.com"
  "新疆 联通 xj-cu-v4.ip.zstaticcdn.com"
  "新疆 移动 xj-cm-v4.ip.zstaticcdn.com"
  "新疆 电信 xj-ct-v4.ip.zstaticcdn.com"
  "北京 联通 bj-cu-v4.ip.zstaticcdn.com"
  "北京 移动 bj-cm-v4.ip.zstaticcdn.com"
  "北京 电信 bj-ct-v4.ip.zstaticcdn.com"
  "天津 联通 tj-cu-v4.ip.zstaticcdn.com"
  "天津 移动 tj-cm-v4.ip.zstaticcdn.com"
  "天津 电信 tj-ct-v4.ip.zstaticcdn.com"
  "上海 联通 sh-cu-v4.ip.zstaticcdn.com"
  "上海 移动 sh-cm-v4.ip.zstaticcdn.com"
  "上海 电信 sh-ct-v4.ip.zstaticcdn.com"
  "重庆 联通 cq-cu-v4.ip.zstaticcdn.com"
  "重庆 移动 cq-cm-v4.ip.zstaticcdn.com"
  "重庆 电信 cq-ct-v4.ip.zstaticcdn.com"
)

# CERNET（AS4538，仅 IPv4）与 CERNET2（AS23910，仅 IPv6）。
CERNET_NODES=(
  "河北 www.hebtu.edu.cn 202.206.100.34"
  "山西 www.tyut.edu.cn 202.207.240.104"
  "辽宁 www.dlut.edu.cn 202.118.66.66"
  "吉林 www.jlu.edu.cn 202.198.16.83"
  "黑龙江 www.hit.edu.cn 202.118.254.135"
  "江苏 www.nju.edu.cn 202.119.32.7"
  "浙江 www.hdu.edu.cn 210.32.32.181"
  "安徽 ustc.edu.cn 202.38.64.246"
  "福建 www.xmu.edu.cn 219.229.81.211"
  "江西 www.ncu.edu.cn 222.204.6.206"
  "山东 www.sdu.edu.cn 202.194.7.118"
  "河南 www.zzu.edu.cn 202.196.64.48"
  "湖北 www.whu.edu.cn 115.156.123.20"
  "湖南 www.hnu.edu.cn 202.197.98.24"
  "广东 www.sysu.edu.cn 202.116.64.8"
  "海南 www.hainnu.edu.cn 210.37.8.40"
  "四川 www.scu.edu.cn 202.115.32.43"
  "贵州 www.gzu.edu.cn 210.40.12.58"
  "云南 www.ynu.edu.cn 113.55.13.95"
  "陕西 www.xjtu.edu.cn 202.117.1.13"
  "甘肃 www.lzu.edu.cn 202.201.0.81"
  "青海 www.qhu.edu.cn 210.27.177.240"
  "内蒙古 www.imu.edu.cn 183.175.40.132"
  "广西 www.gxu.edu.cn 210.36.16.35"
  "西藏 www.xzmu.edu.cn 202.200.16.13"
  "宁夏 www.nxu.edu.cn 222.23.220.245"
  "新疆 www.xju.edu.cn 111.115.76.75"
  "北京 pku.edu.cn 162.105.131.160"
  "天津 www.tju.edu.cn 202.113.2.198"
  "上海 www.sjtu.edu.cn 202.120.2.114"
  "重庆 www.cqu.edu.cn 202.202.2.6"
)

CERNET2_NODES=(
  "河北 www.hebtu.edu.cn 2001:250:800:1::34"
  "山西 www.tyut.edu.cn 2001:250:c01:5000:cacf:f068::"
  "辽宁 www.dlut.edu.cn 2001:da8:a800:3::66"
  "吉林 www.jlu.edu.cn 2001:da8:b000::80"
  "黑龙江 www.hit.edu.cn 2001:da8:b800:253::c0a8:3208"
  "江苏 www.nju.edu.cn 2001:da8:1007::9999"
  "浙江 www.hdu.edu.cn 2001:250:6402:106::102:36"
  "安徽 ustc.edu.cn 2001:da8:d800:642::248"
  "福建 www.xmu.edu.cn 2001:da8:e800:251c::211"
  "江西 www.ncu.edu.cn 2001:250:6c00:60::4"
  "山东 www.sdu.edu.cn 2001:da8:7000:7:202:194:7:118"
  "河南 www.zzu.edu.cn 2001:da8:5000:6c00::47"
  "湖北 www.whu.edu.cn 2001:250:4001:4::9"
  "湖南 www.hnu.edu.cn 2001:250:4402:51::9"
  "广东 www.sysu.edu.cn 2001:250:3002:10::8"
  "海南 www.hainnu.edu.cn 2001:250:3800:18::40"
  "四川 www.scu.edu.cn 2001:250:2003::43"
  "贵州 www.gzu.edu.cn 2001:250:2c00::60"
  "云南 www.ynu.edu.cn 2001:250:2800:0:28:0:13:95"
  "陕西 www.xjtu.edu.cn 2001:250:1001:1::ca75:10d"
  "甘肃 www.lzu.edu.cn 2001:da8:c000:2::2026"
  "青海 www.qhu.edu.cn 2001:250:1e01:1::240"
  "内蒙古 www.imu.edu.cn 2001:da8:21d:c101::2"
  "广西 www.gxu.edu.cn 2001:250:3401:1::35"
  "西藏 www.xzmu.edu.cn 2001:da8:4023:16::13"
  "宁夏 www.nxu.edu.cn 2001:250:1c00:1::245"
  "新疆 www.xju.edu.cn 2001:250:1800:1997::4"
  "北京 lib.pku.edu.cn 2001:da8:201:1138::a269:8a9e"
  "天津 www.tju.edu.cn 2001:da8:a000:ab23::10"
  "上海 www.sjtu.edu.cn 2001:da8:8000:6181:202:120:2:114"
  "重庆 www.cqu.edu.cn 2001:da8:c800:100:caca:206::"
)

PACKETS=30
NODE_TOTAL=${#NODES[@]}
TOTAL=$NODE_TOTAL
PARALLEL=16
TEST_CERNET=0
TEST_ALL=0
UPLOAD_REPORT=1
ONLY_IPV4=0
ONLY_IPV6=0
REPORT_API=${TCPQUALITY_REPORT_API:-https://tcpquality.ibsgss.uk/generate}
RESULT_DIR=$(mktemp -d)
trap "rm -rf $RESULT_DIR" EXIT

# ===================== 参数与帮助 =====================
show_help() {
  cat <<EOF
TcpQuality 节点 TCP 丢包探测脚本

用法:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) [选项]

选项:
  -h, --help        显示帮助信息并退出
  -c, --count NUM   设置每节点发包数，默认 ${PACKETS}
  --count=NUM       同上，设置每节点发包数
  -p, --parallel NUM
                     设置并行节点数，范围 1-31，默认 ${PARALLEL}
  --parallel=NUM    同上，设置并行节点数
  -v4, --v4         仅探测 IPv4
  -v6, --v6         仅探测 IPv6
  --cernet          在三网基础上增加 CERNET IPv4 和 CERNET2 IPv6
  --all             探测三网、CERNET 和 CERNET2

示例:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -c 100

默认行为:
  - 节点范围: 全国 TcpQuality IPv4 节点；检测到可用 IPv6 时增加 IPv6 节点
  - 协议选择: 可使用 -v4/--v4 或 -v6/--v6 限定 IP 版本；--all 会探测全部可用协议
  - 指定教育网参数时: 在三网基础上增加 CERNET 和 CERNET2
  - 探测方式: 每节点单发 ${PACKETS} 次裸 TCP SYN 包，无内核重传
  - 并发数量: ${PARALLEL}
  - DNS 解析: 使用系统 DNS
  - 目标端口: 80/tcp
  - 结果展示: 统计摘要、三网概览
  - CSV 输出: /tmp/zstatic_nping_YYYYmmdd_HHMMSS.csv
  - 报告上传: 默认生成并上传 SVG 报告，返回公开链接

依赖:
  - nping: 随 nmap 安装
  - dig: 用于解析节点域名
  - awk/sed/grep: 用于结果解析和展示

安装提示:
  - Debian/Ubuntu: sudo apt-get install -y nmap dnsutils
  - RHEL/Fedora:   sudo dnf install -y nmap bind-utils
  - Alpine Linux:  sudo apk add nmap-nping bind-tools
  - Arch Linux:    sudo pacman -S nmap bind
  - macOS:         brew install nmap bind

说明:
  发送裸 TCP SYN 包通常需要 root/sudo 权限；如果 nping 权限不足，请使用 sudo 运行。
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -c|--count)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
          echo -e "${RED}[X] 发包数必须是大于 0 的整数${NC}" >&2
          exit 1
        fi
        PACKETS="$2"
        shift 2
        ;;
      --count=*)
        PACKETS="${1#*=}"
        if ! [[ "$PACKETS" =~ ^[0-9]+$ ]] || [ "$PACKETS" -lt 1 ]; then
          echo -e "${RED}[X] 发包数必须是大于 0 的整数${NC}" >&2
          exit 1
        fi
        shift
        ;;
      -p|--parallel)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ] || [ "$2" -gt 31 ]; then
          echo -e "${RED}[X] 并行节点数必须是 1-31 之间的整数${NC}" >&2
          exit 1
        fi
        PARALLEL="$2"
        shift 2
        ;;
      --parallel=*)
        PARALLEL="${1#*=}"
        if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -lt 1 ] || [ "$PARALLEL" -gt 31 ]; then
          echo -e "${RED}[X] 并行节点数必须是 1-31 之间的整数${NC}" >&2
          exit 1
        fi
        shift
        ;;
      -v4|--v4)
        ONLY_IPV4=1
        shift
        ;;
      -v6|--v6)
        ONLY_IPV6=1
        shift
        ;;
      --cernet)
        TEST_CERNET=1
        shift
        ;;
      --all)
        TEST_ALL=1
        shift
        ;;
      *)
        echo -e "${RED}[X] 不支持的参数: $1${NC}" >&2
        echo "使用 -h 或 --help 查看帮助。" >&2
        exit 1
        ;;
    esac
  done
}

# ===================== 工具函数 =====================
loss_color() {
  local v
  v=$(awk -v x="$1" 'BEGIN { printf "%d", x }' 2>/dev/null)
  v=${v:-0}
  if   [ "$v" -eq 0 ];  then echo -n "${GREEN}$1%${NC}"
  elif [ "$v" -le 5 ];  then echo -n "${YELLOW}$1%${NC}"
  elif [ "$v" -le 20 ]; then echo -n "${MAGENTA}$1%${NC}"
  else                      echo -n "${RED}$1%${NC}"
  fi
}

loss_level() {
  awk -v x="$1" 'BEGIN { v=int(x); if(v==0) print 0; else if(v<=5) print 1; else if(v<=20) print 2; else print 3 }' 2>/dev/null
}

bar() {
  local done=$1 total=$2 width=40
  local pct=$(( done * 100 / total ))
  local fill=$(( done * width / total ))
  local empty=$(( width - fill ))
  printf "["
  printf "%${fill}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' '-'
  printf "] %d/%d (%d%%)" "$done" "$total" "$pct"
}

count_results() {
  find "$RESULT_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

show_progress() {
  local done
  done=$(count_results)
  echo -ne "\r  ${CYAN}探测进度${NC} "
  bar "$done" "$TOTAL"
  echo -ne "   "
}

show_provider_summary() {
  local file="$1"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function cell(status, loss, lat, rcv,   l, v, color) {
    l = loss + 0
    v = lat + 0
    if (status != "OK") {
      return red "            失败" nc
    }

    if      (l > 20 || v > 240) color = red
    else if (l > 0  || v > 150) color = yellow
    else                        color = green

    return color sprintf("%4.0fms / %4s", v, compact_loss(loss) "%") nc
  }
  {
    status = $1
    prov = $2
    isp = $3
    rcv = $7
    loss = $8
    lat = $9
    if (!(prov in seen)) {
      seen[prov] = 1
      order[++n] = prov
    }
    data[prov SUBSEP isp] = cell(status, loss, lat, rcv)
  }
  END {
    printf "  %s%s三网概览%s %s(电信 | 联通 | 移动)%s\n", bold, cyan, nc, dim, nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      prov_pad = (prov == "黑龙江" || prov == "内蒙古") ? "  " : "    "
      printf "  %s%s%s%s  电信 %s  联通 %s  移动 %s\n", cyan, prov, nc, prov_pad, data[prov SUBSEP "电信"], data[prov SUBSEP "联通"], data[prov SUBSEP "移动"]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, dim
  }' "$file"
}

show_family_results() {
  local family="$1" file="$2"
  awk -F'|' -v family="$family" '
  BEGIN { z=0; y=0; h=0; }
  $1 == "OK" {
    v = int($8 + 0)
    if      (v == 0)  z++
    else if (v <= 20) y++
    else              h++
  }
  $1 != "OK" { h++ }
  END {
    printf "  \033[1m\033[0;36m%s 统计摘要\033[0m  ", family
    printf "\033[0;32m零丢包:%3d\033[0m    \033[0;33m1-20%%:%3d\033[0m    \033[0;31m>20%%:%3d\033[0m\n\n", z, y, h
  }' "$file"
  show_provider_summary "$file"
}

show_education_results() {
  local title="$1" file="$2"
  awk -F'|' -v title="$title" -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function cell(status, loss, lat,   l, v, color) {
    if (status != "OK") return red "            失败" nc
    l = loss + 0
    v = lat + 0
    if      (l > 20 || v > 240) color = red
    else if (l > 0  || v > 150) color = yellow
    else                        color = green
    return color sprintf("%4.0fms / %4s", v, compact_loss(loss) "%") nc
  }
  {
    status = $1
    prov = $2
    loss = $8
    lat = $9
    result[prov] = cell(status, loss, lat)
    order[++n] = prov
    if (status != "OK") h++
    else if (int(loss + 0) == 0) z++
    else if (int(loss + 0) <= 20) y++
    else h++
  }
  END {
    printf "  %s%s%s 统计摘要%s  ", bold, cyan, title, nc
    printf "%s零丢包:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n\n", green, z, nc, yellow, y, nc, red, h, nc
    printf "  %s%s省份概览%s\n", bold, cyan, nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      prov_pad = (prov == "黑龙江" || prov == "内蒙古") ? "  " : "    "
      printf "  %s%s%s%s  %s\n", cyan, prov, nc, prov_pad, result[prov]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, dim
  }' "$file"
}

show_education_combined() {
  local ipv4_file="$1" ipv6_file="$2"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function cell(status, loss, lat,   l, v, color) {
    if (status != "OK") return red "            失败" nc
    l = loss + 0
    v = lat + 0
    if      (l > 20 || v > 240) color = red
    else if (l > 0  || v > 150) color = yellow
    else                        color = green
    return color sprintf("%4.0fms / %4s", v, compact_loss(loss) "%") nc
  }
  {
    generation = (FILENAME == ARGV[1]) ? 1 : 2
    status = $1
    prov = $2
    loss = $8
    lat = $9
    result[prov SUBSEP generation] = cell(status, loss, lat)
    if (!(prov in seen)) {
      seen[prov] = 1
      order[++n] = prov
    }
    if (status != "OK") h[generation]++
    else if (int(loss + 0) == 0) z[generation]++
    else if (int(loss + 0) <= 20) y[generation]++
    else h[generation]++
  }
  END {
    printf "  %s%s教育网 CERNET-IPv4 和 CERNET2-IPv6 统计摘要%s\n", bold, cyan, nc
    printf "  CERNET-IPv4  %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n", green, z[1], nc, yellow, y[1], nc, red, h[1], nc
    printf "  CERNET2-IPv6 %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n\n", green, z[2], nc, yellow, y[2], nc, red, h[2], nc
    printf "  %s%s教育网概览%s %s(CERNET-IPv4 | CERNET2-IPv6)%s\n", bold, cyan, nc, dim, nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      prov_pad = (prov == "黑龙江" || prov == "内蒙古") ? "  " : "    "
      printf "  %s%s%s%s  CERNET-IPv4 %s  CERNET2-IPv6 %s\n", cyan, prov, nc, prov_pad, result[prov SUBSEP 1], result[prov SUBSEP 2]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, dim
  }' "$ipv4_file" "$ipv6_file"
}

terminal_link() {
  local text="$1" url="$2"
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    printf '\033]8;;%s\007%s\033]8;;\007' "$url" "$text"
  else
    printf "%s" "$text"
  fi
}

print_header() {
  echo -e "${BOLD}${CYAN}TcpQuality TCP 重传检测--最贴近你上网的综合体验${NC}"
  printf "%b特价VPS补货TG频道：" "$DIM"
  terminal_link "ibsgss" "https://t.me/ibsgss"
  printf " | 感谢 Zstatic CDN 节点%b\n" "$NC"
  echo -e "${DIM}------------------------------------------------------------${NC}"
}

# 返回“出口网卡|源IPv6|源MAC|下一跳MAC”。
get_ipv6_route() {
  local target="$1" route_info iface source_ip next_hop source_mac dest_mac

  if command -v ip &>/dev/null; then
    route_info=$(ip -6 route get "$target" 2>/dev/null | head -1)
    iface=$(printf "%s\n" "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    source_ip=$(printf "%s\n" "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    next_hop=$(printf "%s\n" "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -n "$iface" ] && [ -z "$source_ip" ]; then
      source_ip=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}')
    fi
    next_hop=${next_hop:-$target}
    source_mac=$(ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $2; exit}')
    dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i=1; i<=NF; i++) if ($i=="lladdr") {print $(i+1); exit}}')
    if [ -z "$dest_mac" ] && command -v ping &>/dev/null; then
      ping -6 -c 1 -W 1 -I "$iface" "$next_hop" >/dev/null 2>&1 || true
      dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i=1; i<=NF; i++) if ($i=="lladdr") {print $(i+1); exit}}')
    fi
  elif command -v route &>/dev/null && command -v ifconfig &>/dev/null; then
    route_info=$(route -n get -inet6 "$target" 2>/dev/null)
    iface=$(printf "%s\n" "$route_info" | awk '/interface:/ {print $2; exit}')
    source_ip=$(printf "%s\n" "$route_info" | awk '/source:/ {print $2; exit}')
    next_hop=$(printf "%s\n" "$route_info" | awk '/gateway:/ {print $2; exit}')
    if [ -n "$iface" ] && [ -z "$source_ip" ]; then
      source_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet6 / && $2 !~ /^fe80:/ && $2 != "::1" {sub(/%.*/, "", $2); print $2; exit}')
    fi
    next_hop=${next_hop%%\%*}
    source_mac=$(ifconfig "$iface" 2>/dev/null | awk '/ether / {print $2; exit}')
    if command -v ndp &>/dev/null; then
      dest_mac=$(ndp -an 2>/dev/null | awk -v gw="$next_hop" '{addr=$1; sub(/%.*/, "", addr); if (addr==gw) {print $2; exit}}')
    fi
  fi

  source_ip=${source_ip%%\%*}
  case "$source_ip" in
    [23]*:*)
      if [ -n "$iface" ] &&
         [[ "$source_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] &&
         [[ "$dest_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        printf "%s|%s|%s|%s\n" "$iface" "$source_ip" "$source_mac" "$dest_mac"
        return 0
      fi
      ;;
  esac
  return 1
}

ipv6_available() {
  local host target
  read -r _ _ host <<< "${NODES[0]}"
  host=${host/-v4./-v6.}
  target=$(dig_short "$host" AAAA | grep -E '^[0-9A-Fa-f:]+$' | head -1)
  case "$target" in
    [23]*:*) get_ipv6_route "$target" >/dev/null ;;
    *) return 1 ;;
  esac
}

dig_short() {
  local host="$1" record_type="$2"
  dig +short "$host" "$record_type" 2>/dev/null
}

is_public_ipv4() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) exit 1
      if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
      if ($1 == 169 && $2 == 254) exit 1
      if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
      if ($1 == 192 && $2 == 168) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 0) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 2) exit 1
      if ($1 == 198 && ($2 == 18 || $2 == 19)) exit 1
      if ($1 == 198 && $2 == 51 && $3 == 100) exit 1
      if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
      exit 0
    }
  ' <<< "$ip"
}

resolve_ipv4() {
  local host="$1" ip
  while IFS= read -r ip; do
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_public_ipv4 "$ip"; then
      printf "%s\n" "$ip"
      return 0
    fi
  done < <(dig_short "$host" A)
  return 1
}

ipv4_available() {
  local host target
  read -r _ _ host <<< "${NODES[0]}"
  target=$(resolve_ipv4 "$host") || return 1

  if command -v ip &>/dev/null; then
    ip -4 route get "$target" >/dev/null 2>&1
  elif command -v route &>/dev/null; then
    route -n get "$target" >/dev/null 2>&1
  else
    return 1
  fi
}

upload_report() {
  local csv="$1" report_time="${2:-}" response_file http_code report_url today_uses total_uses
  if ! command -v curl &>/dev/null; then
    echo -e "  ${YELLOW}[!] 未安装 curl，已跳过 SVG 报告上传${NC}"
    return
  fi

  response_file=$(mktemp)
  if ! http_code=$(curl -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: text/csv; charset=utf-8' \
    -H "X-Report-Time: $report_time" \
    --data-binary "@$csv" "$REPORT_API"); then
    echo -e "  ${YELLOW}[!] SVG 报告上传失败，本地 CSV 已保留${NC}"
    rm -f "$response_file"
    return
  fi

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    report_url=$(sed -nE 's/.*"url":"([^"]+)".*/\1/p' "$response_file" | head -1)
    today_uses=$(sed -nE 's/.*"todayUses":([0-9]+).*/\1/p' "$response_file" | head -1)
    total_uses=$(sed -nE 's/.*"totalUses":([0-9]+).*/\1/p' "$response_file" | head -1)
  fi
  if [ -n "$report_url" ]; then
    echo -e "  ${WHITE}报告链接：${UNDERLINE}${report_url}${NC}"
    if [ -n "$today_uses" ] && [ -n "$total_uses" ]; then
      echo -e "  ${DIM}今日TCP脚本使用次数：${today_uses}；总使用次数：${total_uses}。感谢使用ibsgss网络质量检测脚本！${NC}"
    fi
  else
    echo -e "  ${YELLOW}[!] SVG 报告上传失败（HTTP $http_code），本地 CSV 已保留${NC}"
  fi
  rm -f "$response_file"
}

# ===================== 单节点测试 =====================
test_one() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" idx="$6"
  local fixed_ip="${7:-}" port="${8:-80}"
  local outfile="${RESULT_DIR}/${group}_${idx}"

  local ip="$fixed_ip"
  if [ -z "$ip" ] && [ "$family" = "6" ]; then
    ip=$(dig_short "$host" AAAA | grep -E '^[0-9A-Fa-f:]+$' | head -1)
  elif [ -z "$ip" ]; then
    ip=$(resolve_ipv4 "$host") || ip=""
  elif [ "$family" = "4" ] && ! is_public_ipv4 "$ip"; then
    ip=""
  fi
  if [ -z "$ip" ]; then
    echo "FAIL|$prov|$isp|$host|DNS|0|0|100.00|0" > "$outfile"
    return
  fi

  local raw nping_rc iface source_ip source_mac dest_mac route_data
  local -a nping_base_args=(--tcp -p "$port" --flags syn)
  if [ "$family" = "6" ]; then
    if ! route_data=$(get_ipv6_route "$ip"); then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|IPV6_ROUTE_ERROR" > "$outfile"
      return
    fi
    IFS='|' read -r iface source_ip source_mac dest_mac <<< "$route_data"
    nping_base_args=(-6 -e "$iface" -S "$source_ip" --source-mac "$source_mac" --dest-mac "$dest_mac" "${nping_base_args[@]}")
  fi

  local sent=0 rcvd=0 loss_pct avg_rtt rtt_sum="0" one_sent one_rcvd one_rtt one_success i
  for ((i = 1; i <= PACKETS; i++)); do
    if raw=$(nping "${nping_base_args[@]}" -c 1 "$ip" 2>&1); then
      nping_rc=0
    else
      nping_rc=$?
    fi

    one_sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rtt=$(printf "%s\n" "$raw" | sed -nE 's/.*Avg rtt:[[:space:]]*([0-9.]+).*/\1/p' | head -1)

    if [ "$nping_rc" -ne 0 ] ||
       ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] ||
       ! [[ "$one_rcvd" =~ ^[0-9]+$ ]]; then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR" > "$outfile"
      return
    fi

    sent=$((sent + one_sent))
    one_success=0
    if [ "$one_rcvd" -gt 0 ]; then
      if ! [[ "$one_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR" > "$outfile"
        return
      fi
      one_success=1
      rcvd=$((rcvd + one_success))
      rtt_sum=$(awk -v a="$rtt_sum" -v b="$one_rtt" 'BEGIN { printf "%.6f", a + b }')
    fi
  done

  loss_pct=$(awk -v sent="$sent" -v rcvd="$rcvd" 'BEGIN { if (sent == 0) print "100.00"; else printf "%.2f", (sent - rcvd) * 100 / sent }')
  if [ "$rcvd" -gt 0 ]; then
    avg_rtt=$(awk -v sum="$rtt_sum" -v rcvd="$rcvd" 'BEGIN { printf "%.3f", sum / rcvd }')
  else
    avg_rtt=0
  fi
  echo "OK|$prov|$isp|$host|$ip|$sent|$rcvd|$loss_pct|$avg_rtt" > "$outfile"
}

export -f test_one
export -f get_ipv6_route
export -f dig_short
export -f is_public_ipv4
export -f resolve_ipv4
export RESULT_DIR PACKETS

# ===================== 主流程 =====================
main() {
  clear
  print_header

  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi

  check_nping
  check_dig

  local ipv4_enabled=0 ipv6_enabled=0 test_cdn=1 test_edu=0 want_ipv4=1 want_ipv6=1
  if [ "$TEST_ALL" -eq 1 ]; then
    want_ipv4=1
    want_ipv6=1
  elif [ "$ONLY_IPV4" -eq 1 ] && [ "$ONLY_IPV6" -eq 0 ]; then
    want_ipv6=0
  elif [ "$ONLY_IPV6" -eq 1 ] && [ "$ONLY_IPV4" -eq 0 ]; then
    want_ipv4=0
  fi

  if [ "$want_ipv4" -eq 1 ] && ipv4_available; then
    ipv4_enabled=1
    echo -e "${GREEN}[√] 检测到可用 IPv4${NC}"
  elif [ "$want_ipv4" -eq 1 ]; then
    echo -e "${YELLOW}[!] 未检测到可用 IPv4，已跳过 IPv4${NC}"
  fi
  if [ "$want_ipv4" -eq 0 ]; then
    echo -e "${DIM}[i] 已按参数跳过 IPv4${NC}"
  fi

  if [ "$TEST_CERNET" -eq 1 ] || [ "$TEST_ALL" -eq 1 ]; then test_edu=1; fi

  TOTAL=0
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + NODE_TOTAL)); fi
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + ${#CERNET_NODES[@]})); fi
  if [ "$want_ipv6" -eq 1 ] && ipv6_available; then
    ipv6_enabled=1
    if [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + NODE_TOTAL)); fi
    if [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + ${#CERNET2_NODES[@]})); fi
    echo -e "${GREEN}[√] 检测到可用 IPv6${NC}"
  elif [ "$want_ipv6" -eq 1 ]; then
    echo -e "${YELLOW}[!] 未检测到可用 IPv6，已跳过 IPv6${NC}"
    if [ "$test_edu" -eq 1 ]; then
      echo -e "${YELLOW}[!] 二代教育网需要 IPv6，已跳过${NC}"
    fi
  fi
  if [ "$want_ipv6" -eq 0 ]; then
    echo -e "${DIM}[i] 已按参数跳过 IPv6${NC}"
  fi
  if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}[X] 没有可执行的探测任务${NC}"
    exit 1
  fi
  echo -e "${DIM}  探测节点: $TOTAL  每节点发包: $PACKETS  并行: $PARALLEL  端口: 80/tcp${NC}"
  echo ""

  # 并行测试
  local idx=0
  echo -e "  ${DIM}正在探测，请稍候...${NC}"
  show_progress
  local family entry prov isp host fixed_ip
  local -a families=()
  if [ "$test_cdn" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then families+=(4); fi
    if [ "$ipv6_enabled" -eq 1 ]; then families+=(6); fi
    for family in "${families[@]}"; do
      for entry in "${NODES[@]}"; do
        read -r prov isp host <<< "$entry"
        if [ "$family" = "6" ]; then
          host=${host/-v4./-v6.}
        fi
        idx=$((idx + 1))
        while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do
          show_progress
          sleep 0.2
        done
        test_one "cdn${family}" "$family" "$prov" "$isp" "$host" "$idx" &
        show_progress
      done
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    for entry in "${CERNET_NODES[@]}"; do
      read -r prov host fixed_ip <<< "$entry"
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet" 4 "$prov" "教育网" "$host" "$idx" "$fixed_ip" 80 &
      show_progress
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    for entry in "${CERNET2_NODES[@]}"; do
      read -r prov host fixed_ip <<< "$entry"
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet2" 6 "$prov" "教育网" "$host" "$idx" "$fixed_ip" 80 &
      show_progress
    done
  fi
  while [ "$(jobs -pr | wc -l | tr -d ' ')" -gt 0 ]; do
    show_progress
    sleep 0.2
  done
  wait
  show_progress
  echo ""

  # 收集结果并写入 CSV
  local report_time
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  local CSV="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$CSV"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms" >> "$CSV"

  local sorted_v4 sorted_v6 sorted_cernet sorted_cernet2 sorted_file f i status ip snd rcv loss lat
  sorted_v4=$(mktemp)
  sorted_v6=$(mktemp)
  sorted_cernet=$(mktemp)
  sorted_cernet2=$(mktemp)
  if [ "$test_cdn" -eq 1 ]; then
    for family in "${families[@]}"; do
      if [ "$family" = "4" ]; then sorted_file="$sorted_v4"; else sorted_file="$sorted_v6"; fi
      for i in $(seq 1 "$TOTAL"); do
        f="${RESULT_DIR}/cdn${family}_${i}"
        if [ -f "$f" ]; then
          IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
          echo "三网,IPv${family},$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat" >> "$CSV"
          echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_file"
        fi
      done
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/cernet_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        echo "CERNET,IPv4,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat" >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_cernet"
      fi
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/cernet2_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        echo "CERNET2,IPv6,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat" >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_cernet2"
      fi
    done
  fi

  # ---- TUI 结果展示 ----
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo ""

  if [ "$test_cdn" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then
      show_family_results "IPv4" "$sorted_v4"
    fi
    if [ "$ipv6_enabled" -eq 1 ]; then
      show_family_results "IPv6" "$sorted_v6"
    fi
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    show_education_combined "$sorted_cernet" "$sorted_cernet2"
  else
    if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
      show_education_results "CERNET-IPv4" "$sorted_cernet"
    fi
    if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
      show_education_results "CERNET2-IPv6" "$sorted_cernet2"
    fi
  fi

  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    upload_report "$CSV" "${report_time%%（*}"
  fi
  echo ""

  rm -f "$sorted_v4" "$sorted_v6" "$sorted_cernet" "$sorted_cernet2"
}

parse_args "$@"
main
