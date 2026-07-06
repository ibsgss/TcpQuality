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

PACKETS=60
NODE_TOTAL=${#NODES[@]}
TOTAL=$NODE_TOTAL
PARALLEL=31
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

示例:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -c 100

默认行为:
  - 节点范围: 全国 TcpQuality IPv4 节点；检测到可用 IPv6 时增加 IPv6 节点
  - 探测方式: 每节点发送 ${PACKETS} 个裸 TCP SYN 包，无内核重传
  - 并发数量: ${PARALLEL}
  - 目标端口: 80/tcp
  - 结果展示: 统计摘要、三网概览
  - CSV 输出: /tmp/zstatic_nping_YYYYmmdd_HHMMSS.csv

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
    sub(/\.00$/, "", v)
    return v
  }
  function cell(status, loss, lat, rcv,   l, v, color) {
    l = loss + 0
    v = lat + 0
    if (status != "OK") {
      return red "          失败" nc
    }

    if      (l > 20 || v > 240) color = red
    else if (l > 0  || v > 150) color = yellow
    else                        color = green

    return color sprintf("%4.0fms/%7s", v, compact_loss(loss) "%") nc
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

print_header() {
  echo -e "${BOLD}${CYAN}TcpQuality TCP 重传检测--最贴近你上网的综合体验${NC}"
  echo -e "${DIM}特价VPS补货TG频道：ibsgss | 感谢 Zstatic CDN 节点${NC}"
  echo -e "${DIM}------------------------------------------------------------${NC}"
}

# 返回“出口网卡|源IPv6”，避免 nping 使用未指定源地址 ::。
get_ipv6_route() {
  local target="$1" route_info iface source_ip

  if command -v ip &>/dev/null; then
    route_info=$(ip -6 route get "$target" 2>/dev/null | head -1)
    iface=$(printf "%s\n" "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    source_ip=$(printf "%s\n" "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    if [ -n "$iface" ] && [ -z "$source_ip" ]; then
      source_ip=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}')
    fi
  elif command -v route &>/dev/null && command -v ifconfig &>/dev/null; then
    route_info=$(route -n get -inet6 "$target" 2>/dev/null)
    iface=$(printf "%s\n" "$route_info" | awk '/interface:/ {print $2; exit}')
    source_ip=$(printf "%s\n" "$route_info" | awk '/source:/ {print $2; exit}')
    if [ -n "$iface" ] && [ -z "$source_ip" ]; then
      source_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet6 / && $2 !~ /^fe80:/ && $2 != "::1" {sub(/%.*/, "", $2); print $2; exit}')
    fi
  fi

  source_ip=${source_ip%%\%*}
  case "$source_ip" in
    [23]*:*)
      if [ -n "$iface" ]; then
        printf "%s|%s\n" "$iface" "$source_ip"
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
  target=$(dig +short "$host" AAAA 2>/dev/null | grep -E '^[0-9A-Fa-f:]+$' | head -1)
  case "$target" in
    [23]*:*) get_ipv6_route "$target" >/dev/null ;;
    *) return 1 ;;
  esac
}

# ===================== 单节点测试 =====================
test_one() {
  local family="$1" prov="$2" isp="$3" host="$4" idx="$5"
  local outfile="${RESULT_DIR}/${family}_${idx}"

  local ip
  if [ "$family" = "6" ]; then
    ip=$(dig +short "$host" AAAA 2>/dev/null | grep -E '^[0-9A-Fa-f:]+$' | head -1)
  else
    ip=$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  fi
  if [ -z "$ip" ]; then
    echo "FAIL|$prov|$isp|$host|DNS|0|0|100.00|0" > "$outfile"
    return
  fi

  local raw nping_rc iface source_ip route_data
  local -a nping_args=(--tcp -p 80 --flags syn -c "$PACKETS" --delay 1s "$ip")
  if [ "$family" = "6" ]; then
    if ! route_data=$(get_ipv6_route "$ip"); then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|IPV6_ROUTE_ERROR" > "$outfile"
      return
    fi
    IFS='|' read -r iface source_ip <<< "$route_data"
    nping_args=(-6 -e "$iface" -S "$source_ip" "${nping_args[@]}")
  fi
  if raw=$(nping "${nping_args[@]}" 2>&1); then
    nping_rc=0
  else
    nping_rc=$?
  fi

  local sent rcvd loss_pct avg_rtt
  sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  loss_pct=$(printf "%s\n" "$raw" | sed -nE 's/.*\(([0-9.]+)%\).*/\1/p' | head -1)
  avg_rtt=$(printf "%s\n" "$raw" | sed -nE 's/.*Avg rtt:[[:space:]]*([0-9.]+).*/\1/p' | head -1)

  if [ "$nping_rc" -ne 0 ] ||
     ! [[ "$sent" =~ ^[0-9]+$ ]] || [ "$sent" -ne "$PACKETS" ] ||
     ! [[ "$rcvd" =~ ^[0-9]+$ ]] ||
     ! [[ "$loss_pct" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
     { [ "$rcvd" -gt 0 ] && ! [[ "$avg_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; }; then
    echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR" > "$outfile"
    return
  fi

  avg_rtt=${avg_rtt:-0}

  echo "OK|$prov|$isp|$host|$ip|$sent|$rcvd|$loss_pct|$avg_rtt" > "$outfile"
}

export -f test_one
export -f get_ipv6_route
export RESULT_DIR PACKETS

# ===================== 主流程 =====================
main() {
  clear
  print_header

  check_nping
  check_dig

  local ipv6_enabled=0
  if ipv6_available; then
    ipv6_enabled=1
    TOTAL=$((NODE_TOTAL * 2))
    echo -e "${GREEN}[√] 检测到可用 IPv6，启用双栈探测${NC}"
  else
    TOTAL=$NODE_TOTAL
    echo -e "${YELLOW}[!] 未检测到可用 IPv6，仅探测 IPv4${NC}"
  fi
  echo -e "${DIM}  探测节点: $TOTAL  每节点发包: $PACKETS  并行: $PARALLEL  端口: 80/tcp${NC}"
  echo ""

  # 并行测试
  local idx=0
  echo -e "  ${DIM}正在探测，请稍候...${NC}"
  show_progress
  local family entry prov isp host
  local -a families=(4)
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
      test_one "$family" "$prov" "$isp" "$host" "$idx" &
      show_progress
    done
  done
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
  echo "IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms" >> "$CSV"

  local sorted_v4 sorted_v6 sorted_file f i status ip snd rcv loss lat
  sorted_v4=$(mktemp)
  sorted_v6=$(mktemp)
  for family in "${families[@]}"; do
    if [ "$family" = "4" ]; then sorted_file="$sorted_v4"; else sorted_file="$sorted_v6"; fi
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/${family}_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        echo "IPv${family},$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat" >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_file"
      fi
    done
  done

  # ---- TUI 结果展示 ----
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo ""

  show_family_results "IPv4" "$sorted_v4"
  if [ "$ipv6_enabled" -eq 1 ]; then
    show_family_results "IPv6" "$sorted_v6"
  fi

  echo -e "  ${DIM}CSV: $CSV${NC}"
  echo ""

  rm -f "$sorted_v4" "$sorted_v6"
}

parse_args "$@"
main
