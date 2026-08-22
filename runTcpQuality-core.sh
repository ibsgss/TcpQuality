#!/usr/bin/env bash
#
# TcpQuality
#

set -e

# ===================== NixOS 临时运行环境 =====================
is_nixos() {
  [ -e /etc/NIXOS ] || {
    [ -r /etc/os-release ] && grep -Eq '^ID=(nixos|"nixos")$' /etc/os-release
  }
}

bootstrap_nixos_environment() {
  local arg need_speedtest=0 temp_script
  local -a nix_packages

  is_nixos || return 0
  [ "${TCPQUALITY_NIX_BOOTSTRAPPED:-0}" -eq 1 ] && return 0

  # 帮助信息本身不需要拉取任何依赖。
  for arg in "$@"; do
    case "$arg" in
      -h|--help) return 0 ;;
      --all|--speedtest|--only-speedtest) need_speedtest=1 ;;
    esac
  done

  if ! command -v nix >/dev/null 2>&1; then
    echo '[X] 当前系统是 NixOS，但没有找到 nix 命令。' >&2
    exit 1
  fi
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    echo '[X] 裸 TCP SYN 探测需要 root；请使用 root 运行，或先启用 sudo。' >&2
    exit 1
  fi

  # 兼容 `bash <(curl ...)`：/dev/fd 路径跨 exec 后可能失效，因此先复制脚本。
  temp_script=$(mktemp /tmp/tcpquality-nixos.XXXXXX.sh)
  cat "$0" > "$temp_script"
  chmod 0755 "$temp_script"
  trap 'rm -f -- "$temp_script"' EXIT

  nix_packages=(
    nixpkgs#bash
    nixpkgs#coreutils
    nixpkgs#curl
    nixpkgs#findutils
    nixpkgs#gawk
    nixpkgs#gnugrep
    nixpkgs#gnused
    nixpkgs#iproute2
    nixpkgs#iputils
    nixpkgs#ncurses
    nixpkgs#nmap
    nixpkgs#iperf3
    nixpkgs#jq
    nixpkgs#traceroute
  )
  if [ "$need_speedtest" -eq 1 ]; then
    # 单线程测速只依赖 curl，使用 --resolve 固定 TOS 目标 IP。
    :
  fi

  echo '[i] NixOS：正在进入临时 Nix 环境（不会修改 systemPackages）...'

  if [ "$(id -u)" -eq 0 ]; then
    exec env \
      TCPQUALITY_NIX_BOOTSTRAPPED=1 \
      TCPQUALITY_NIX_TEMP_SCRIPT="$temp_script" \
      NIXPKGS_ALLOW_UNFREE=1 \
      nix --extra-experimental-features 'nix-command flakes' \
        shell --impure "${nix_packages[@]}" \
        --command bash "$temp_script" "$@"
  fi

  # 先以普通用户构建/进入 nix shell，再只把实际探测进程提权；显式保留
  # Nix shell 生成的 PATH，否则 sudo 的 secure_path 会再次丢失这些工具。
  exec env NIXPKGS_ALLOW_UNFREE=1 \
    nix --extra-experimental-features 'nix-command flakes' \
      shell --impure "${nix_packages[@]}" \
      --command bash -c '
        exec sudo env \
          "PATH=$PATH" \
          "TERM=${TERM:-dumb}" \
          "LANG=${LANG:-C.UTF-8}" \
          "GET_NODES_URL=${GET_NODES_URL:-}" \
          "TCPQUALITY_REPORT_API=${TCPQUALITY_REPORT_API:-}" \
          TCPQUALITY_NIX_BOOTSTRAPPED=1 \
          "TCPQUALITY_NIX_TEMP_SCRIPT=$1" \
          NIXPKGS_ALLOW_UNFREE=1 \
          bash "$1" "${@:2}"
      ' bash "$temp_script" "$@"
}

bootstrap_nixos_environment "$@"

# ===================== 颜色定义 =====================
RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[0;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';     MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  BOLD='\033[1m';        DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'
BG_RED='\033[41m';   BG_GREEN='\033[42m';   BG_YELLOW='\033[43m'

USE_SUDO=""
IPV4_PUBLIC=""
IPV6_PUBLIC=""
IPV4_WORK=0
IPV6_WORK=0
GET_NODES_URL="${GET_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
GET_NODES_LAST_URL=""
GET_NODES_LAST_ERROR=""
GET_NODES_LAST_STATUS=""
REMOTE_NODES_LOADED=0
REMOTE_CDN4_NODES=()
REMOTE_CDN6_NODES=()
REMOTE_CERNET_NODES=()
REMOTE_CERNET2_NODES=()

# ===================== 依赖与权限检查 =====================
init_privilege() {
  USE_SUDO=""
  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
      USE_SUDO="sudo"
    fi
  fi
}

show_dependency_install_notice() {
  echo -ne "\r${YELLOW}[!] 检测到未安装的依赖，正在安装...${NC}"
}

clear_dependency_install_notice() {
  printf '\r\033[2K'
}

install_with_package_manager() {
  local dep="$1"

  if is_nixos; then
    echo -e "${RED}[X] NixOS 不应在脚本内调用传统包管理器：缺少 ${dep}${NC}" >&2
    return 1
  fi
  local apt_pkg="$2"
  local dnf_pkg="$3"
  local yum_pkg="$4"
  local apk_pkg="$5"
  local pacman_pkg="$6"
  local brew_pkg="$7"

  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ] && [ -z "$USE_SUDO" ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi

  if command -v apt-get &>/dev/null; then
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    $USE_SUDO apt-get install -y -qq "$apt_pkg" >/dev/null 2>&1 || return 1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q "$dnf_pkg" >/dev/null 2>&1 || {
      $USE_SUDO dnf install -y -q epel-release >/dev/null 2>&1 || true
      $USE_SUDO dnf install -y -q "$dnf_pkg" >/dev/null 2>&1 || return 1
    }
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q "$yum_pkg" >/dev/null 2>&1 || {
      $USE_SUDO yum install -y -q epel-release >/dev/null 2>&1 || true
      $USE_SUDO yum install -y -q "$yum_pkg" >/dev/null 2>&1 || return 1
    }
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache "$apk_pkg" >/dev/null 2>&1 || return 1
  elif command -v pacman &>/dev/null; then
    $USE_SUDO pacman -Sy --noconfirm "$pacman_pkg" >/dev/null 2>&1 || return 1
  elif command -v brew &>/dev/null; then
    brew install "$brew_pkg" >/dev/null 2>&1 || return 1
  else
    echo -e "${RED}[X] 无法自动安装 $dep，请手动安装后重试${NC}"
    exit 1
  fi
}

check_command() {
  local cmd="$1" desc="$2" apt_pkg="$3" dnf_pkg="$4" yum_pkg="$5" apk_pkg="$6" pacman_pkg="$7" brew_pkg="$8"
  if command -v "$cmd" &>/dev/null; then
    return 0
  fi
  if is_nixos; then
    echo -e "${RED}[X] Nix 临时环境中没有找到 ${desc}（命令：${cmd}）${NC}" >&2
    echo -e "${DIM}    请确认 nixpkgs 中对应软件包仍可用，或使用 --debug 排查。${NC}" >&2
    exit 1
  fi
  show_dependency_install_notice
  if install_with_package_manager "$desc" "$apt_pkg" "$dnf_pkg" "$yum_pkg" "$apk_pkg" "$pacman_pkg" "$brew_pkg" && command -v "$cmd" &>/dev/null; then
    clear_dependency_install_notice
  else
    clear_dependency_install_notice
    echo -e "${RED}[X] $desc 安装失败${NC}"
    exit 1
  fi
}

check_curl() {
  check_command curl curl curl curl curl curl curl curl
}

check_nping() {
  if command -v nping &>/dev/null; then
    return 0
  fi
  if is_nixos; then
    echo -e "${RED}[X] nixpkgs#nmap 环境中没有找到 nping${NC}" >&2
    exit 1
  fi
  show_dependency_install_notice
  if command -v apk &>/dev/null; then
    if ! install_with_package_manager nping nmap nmap nmap nmap-nping nmap nmap; then
      install_with_package_manager nping nmap nmap nmap nmap nmap nmap || true
    fi
  else
    install_with_package_manager nping nmap nmap nmap nmap nmap nmap || true
  fi
  if command -v nping &>/dev/null; then
    clear_dependency_install_notice
  else
    clear_dependency_install_notice
    echo -e "${RED}[X] nping 安装失败${NC}"
    exit 1
  fi
}

check_traceroute() {
  check_command traceroute traceroute traceroute traceroute traceroute traceroute traceroute traceroute
}

check_iperf3() {
  check_command iperf3 iperf3 iperf3 iperf3 iperf3 iperf3 iperf3 iperf3
  check_command jq jq jq jq jq jq jq jq
  check_command ss ss iproute2 iproute2 iproute2 iproute2 iproute2 iproute2
}

check_nexttrace() {
  if command -v nexttrace-tiny &>/dev/null; then
    return 0
  fi
  echo -e "${YELLOW}[!] 未检测到 nexttrace-tiny，已跳过 IPv4大包回程${NC}"
  return 1
}

require_raw_socket_privilege() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi
}

# ===================== 远端节点 =====================
# 节点域名、真实 IP 与端口统一由 GET_NODES_URL 提供，脚本不再内置探测节点或备用节点。

PACKETS=25
MAX_PACKETS=600
COUNT_EXPLICIT=0
PACKET_SIZES=(40 80 160 320 640 1200)
# 默认使用标准 TCP SYN，不携带数据；仅在显式指定 -s/--size 时构造指定长度报文。
PACKET_SIZE_OVERRIDE="0"
LARGE_PACKET_SIZES=(120 240 480 900 950 1000 1050 1100 1150 1200 1200 900)
LARGE_PACKET_SMALL_SIZES=(120 240 480)
LARGE_PACKET_BIG_SIZES=(900 950 1000 1050 1100 1150 1200 1200 900)
LARGE_PACKET_PRECHECK_DOMAIN="www.cloudflare.com"
LARGE_PACKET_PRECHECK_PACKETS=20
LARGE_PACKET_PRECHECK_SIZE=1200
LARGE_PACKET_FIREWALL_LIMITED=0
LARGE_PACKET_PRECHECK_LOSS=""
IPV6_NPING_PRECHECK_PACKETS=3
IPV6_NPING_FORCE_L2=0
TOTAL=0
PARALLEL=16
PARALLEL_EXPLICIT=0
TEST_CERNET=0
TEST_ALL=0
INCLUDE_DEFAULT_ROUTE="${TCPQUALITY_INCLUDE_DEFAULT_ROUTE:-0}"
UPLOAD_REPORT=1
REPORT_UPLOAD_FORCED_OFF=0
ONLY_IPV4=0
ONLY_IPV6=0
ONLY_LARGE=0
ROUTE_MODE=0
ROUTE_PROTOCOL="tcp"
ROUTE_ACTIVE_PREFIX=""
SELECTED_PROVINCES=""
DEBUG_MODE=0
SPEEDTEST_ENABLED=0
SPEEDTEST_ONLY=0
INTERNATIONAL_ENABLED=0
INTERNATIONAL_ONLY=0
INTL_REQUESTED=0
INTERNATIONAL_PROGRESS_TOTAL=0
INTERNATIONAL_PACKETS=15
INTERNATIONAL_HTTP_TIMEOUT=8
INTERNATIONAL_MAX_IPS="${TCPQUALITY_INTERNATIONAL_MAX_IPS:-2}"
if ! [[ "$INTERNATIONAL_MAX_IPS" =~ ^[1-9][0-9]*$ ]]; then
  INTERNATIONAL_MAX_IPS=2
fi
INTERNATIONAL_IPERF_SECONDS="${TCPQUALITY_INTERNATIONAL_IPERF_SECONDS:-5}"
INTERNATIONAL_IPERF_RATE="${TCPQUALITY_INTERNATIONAL_IPERF_RATE:-1M}"
INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS="${TCPQUALITY_INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS:-5000}"
INTERNATIONAL_IPERF_MAX_ATTEMPTS=10
SPEEDTEST_STATE_FILE=""
SPEEDTEST_PROGRESS_FILE=""
SPEEDTEST_BACKGROUND=0
SPEEDTEST_BACKGROUND_PID=""
ROUTE_PROGRESS_TOTAL=0
ROUTE_BACKGROUND_PID=""
MULTI_PROGRESS_MODE=0
PROGRESS_LINES_PRINTED=0
PROGRESS_LAST_STATE=""
PROGRESS_LAST_TS=0
PROGRESS_MIN_INTERVAL=1
REPORT_API=${TCPQUALITY_REPORT_API:-https://tcpquality.ibsgss.uk/generate}
ROUTE_ASN_API=${TCPQUALITY_ROUTE_ASN_API:-${REPORT_API%/generate}/route/asn?format=tsv}
RANK_SESSION_API=${TCPQUALITY_RANK_SESSION_API:-${REPORT_API%/generate}/rank/session}
RANK_SESSION_ID=""
RANK_SESSION_TOKEN=""
RANK_SESSION_STARTED_AT=""
RANK_SESSION_EXPIRES_AT=""
RANK_SESSION_IP4=""
RESULT_DIR=$(mktemp -d)
cleanup_result_dir() {
  printf '%b' "${NC:-\033[0m}"
  if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    local archive="${RESULT_DIR}.tar.gz"
    if [ -d "$RESULT_DIR" ] && tar -C "$(dirname "$RESULT_DIR")" -czf "$archive" "$(basename "$RESULT_DIR")" 2>/dev/null; then
      rm -rf "$RESULT_DIR"
      echo -e "${DIM}Debug 压缩包：$archive${NC}"
    else
      echo -e "${YELLOW}[!] Debug 打包失败：$RESULT_DIR${NC}"
    fi
  else
    rm -rf "$RESULT_DIR"
  fi
  case "${TCPQUALITY_NIX_TEMP_SCRIPT:-}" in
    /tmp/tcpquality-nixos.*.sh) rm -f -- "$TCPQUALITY_NIX_TEMP_SCRIPT" ;;
  esac
}
trap cleanup_result_dir EXIT

# ===================== 国际互联目标 =====================
# 网站格式：名称|域名|可选 HTTP 路径。
# CDN 格式：名称|提供商|域名|可选静态资源路径。
#
# 这里优先使用可长期访问的静态资源入口；官网和临时 Demo 不作为 CDN 基准。
# 路径非空时，TCP 探测成功后会额外做一次 HTTP HEAD；使用 --debug 时会保存状态/边缘信息。
INTERNATIONAL_SITE_TARGETS=(
  'Adobe Assets|assets.adobe.com'
  'Amazon|www.amazon.com'
  'Apple iCloud|www.icloud.com'
  'AWS STS|sts.amazonaws.com'
  'ChatGPT|chatgpt.com'
  'Claude|claude.ai'
  'Cloudflare Dashboard|dash.cloudflare.com'
  'Discord Gateway|gateway.discord.gg'
  'Dropbox API|api.dropboxapi.com'
  'Facebook|www.facebook.com'
  'GitHub API|api.github.com'
  'GitLab|gitlab.com'
  'Gmail|mail.google.com'
  'Google Search|www.google.com'
  'Google Static|www.gstatic.com'
  'Instagram|www.instagram.com'
  'Microsoft Login|login.microsoftonline.com'
  'Netflix API|api-global.netflix.com'
  'NodeSeek|www.nodeseek.com'
  'Notion API|api.notion.com'
  'OpenAI API|api.openai.com'
  'PayPal API|api-m.paypal.com'
  'Reddit OAuth|oauth.reddit.com'
  'Slack App|app.slack.com'
  'Spotify Web|open.spotify.com'
  'Steam|store.steampowered.com'
  'Telegram|telegram.org'
  'Wikipedia|www.wikipedia.org'
  'X|x.com'
  'YouTube API|youtubei.googleapis.com'
  'Zoom API|api.zoom.us'
)

INTERNATIONAL_CDN_TARGETS=(
  'Akamai Edge|Akamai|www.akamai.com|'
  'AWS CloudFront|CloudFront|d1.awsstatic.com|'
  'CacheFly|CacheFly|cachefly.cachefly.net|'
  'Cloudflare CDNJS|Cloudflare|cdnjs.cloudflare.com|/ajax/libs/jquery/3.7.1/jquery.min.js'
  'Fastly Test|Fastly|http-me.fastly.dev|'
  'Google Hosted Libraries|Google|ajax.googleapis.com|/ajax/libs/jquery/3.7.1/jquery.min.js'
  'jsDelivr Multi-CDN|jsDelivr|cdn.jsdelivr.net|/npm/jquery@3.7.1/dist/jquery.min.js'
  'UNPKG Cloudflare|UNPKG|unpkg.com|/jquery@3.7.1/dist/jquery.min.js'
)

# Leaseweb speedtest 节点支持 iPerf3 TCP，端口范围为 5201-5210。
# row_key 用于区分两行“美洲”，报告页面会按 row_key 分组并分别展示 IPv4/IPv6。
# 目标格式：row_key|区域|节点|主机|IPv4 起始端口|可选 IPv6 起始端口|可选 IPv4 备用主机|可选 IPv4 备用起始端口|可选 IPv6 备用主机|可选 IPv6 备用起始端口。
INTERNATIONAL_IPERF_TARGETS=(
  'asia|亚洲|香港|speedtest.hkg12.hk.leaseweb.net|5201'
  'asia|亚洲|日本|speedtest.tyo11.jp.leaseweb.net|5201'
  'asia|亚洲|新加坡|speedtest.sin1.sg.leaseweb.net|5201'
  'americas-us|美洲|美国西部-洛杉矶|speedtest.lax12.us.leaseweb.net|5201'
  'americas-us|美洲|美国中部-达拉斯|speedtest.dal13.us.leaseweb.net|5201'
  'americas-us|美洲|美国东部-芝加哥|speedtest.chi11.us.leaseweb.net|5201'
  'americas-latam|美洲|加拿大-蒙特利尔|speedtest.mtl2.ca.leaseweb.net|5201'
  # 巴西：Edgoo 节点优先；Leaseweb MIA-11 仅作为 IPv4 备用，IPv6 不设置备用。
  'americas-latam|美洲|巴西-里约热内卢|speedtest.sao1.edgoo.net|9209|9208|speedtest.mia11.us.leaseweb.net|5201'
  'europe|欧洲|德国-法兰克福|speedtest.fra1.de.leaseweb.net|5201'
  'europe|欧洲|英国-伦敦|speedtest.lon1.uk.leaseweb.net|5201'
  'europe|欧洲|荷兰-阿姆斯特丹|speedtest.ams1.nl.leaseweb.net|5201'
  # 悉尼：LeaseWeb 为默认节点；OVH 仅作为 IPv6 备用节点。
  'oceania|大洋洲|澳大利亚-悉尼|speedtest.syd12.au.leaseweb.net|5201||||syd.proof.ovh.net|5201'
)

# ===================== 省份筛选 =====================
province_from_code() {
  local code="$1"
  code=$(printf "%s" "$code" | tr '[:upper:]' '[:lower:]')
  code=${code#-}
  case "$code" in
    he|河北) echo "河北" ;;
    sx|山西) echo "山西" ;;
    ln|辽宁) echo "辽宁" ;;
    jl|吉林) echo "吉林" ;;
    hl|黑龙江) echo "黑龙江" ;;
    js|江苏) echo "江苏" ;;
    zj|浙江) echo "浙江" ;;
    ah|安徽) echo "安徽" ;;
    fj|福建) echo "福建" ;;
    jx|江西) echo "江西" ;;
    sd|山东) echo "山东" ;;
    ha|河南) echo "河南" ;;
    hb|湖北) echo "湖北" ;;
    hn|湖南) echo "湖南" ;;
    gd|广东) echo "广东" ;;
    hi|海南) echo "海南" ;;
    sc|四川) echo "四川" ;;
    gz|贵州) echo "贵州" ;;
    yn|云南) echo "云南" ;;
    sn|陕西) echo "陕西" ;;
    gs|甘肃) echo "甘肃" ;;
    qh|青海) echo "青海" ;;
    nm|内蒙古) echo "内蒙古" ;;
    gx|广西) echo "广西" ;;
    xz|西藏) echo "西藏" ;;
    nx|宁夏) echo "宁夏" ;;
    xj|新疆) echo "新疆" ;;
    bj|北京) echo "北京" ;;
    tj|天津) echo "天津" ;;
    sh|上海) echo "上海" ;;
    cq|重庆) echo "重庆" ;;
    *) return 1 ;;
  esac
}

add_province_filter() {
  local province
  province=$(province_from_code "$1") || return 1
  case "$SELECTED_PROVINCES" in
    *"|$province|"*) ;;
    *) SELECTED_PROVINCES="${SELECTED_PROVINCES}|${province}|" ;;
  esac
}

province_selected() {
  local province="$1"
  [ -z "$SELECTED_PROVINCES" ] || [[ "$SELECTED_PROVINCES" == *"|$province|"* ]]
}

province_filter_text() {
  if [ -z "$SELECTED_PROVINCES" ]; then
    echo "全国"
  else
    printf "%s" "$SELECTED_PROVINCES" | sed 's/^|//; s/|$//; s/||/、/g; s/|/、/g'
  fi
}

count_cdn_nodes() {
  local family="${1:-4}" entry prov isp host fixed_ip port count=0
  local -a remote_nodes=()
  if [ "$family" = "6" ]; then
    remote_nodes=("${REMOTE_CDN6_NODES[@]}")
  else
    remote_nodes=("${REMOTE_CDN4_NODES[@]}")
  fi
  for entry in "${remote_nodes[@]}"; do
    IFS='|' read -r prov isp host fixed_ip port <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

count_cernet_nodes() {
  local entry prov host ip port count=0
  for entry in "${REMOTE_CERNET_NODES[@]}"; do
    IFS='|' read -r prov host ip port <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

count_cernet2_nodes() {
  local entry prov host ip port count=0
  for entry in "${REMOTE_CERNET2_NODES[@]}"; do
    IFS='|' read -r prov host ip port <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

node_scope() {
  if [ "$TEST_ALL" -eq 1 ] || { [ "$INCLUDE_DEFAULT_ROUTE" -eq 1 ] && [ "$TEST_CERNET" -eq 1 ]; }; then
    echo "all"
  elif [ "$TEST_CERNET" -eq 1 ]; then
    echo "cernet"
  elif [ "$ONLY_IPV4" -eq 1 ] && [ "$ONLY_IPV6" -eq 0 ]; then
    echo "v4"
  elif [ "$ONLY_IPV6" -eq 1 ] && [ "$ONLY_IPV4" -eq 0 ]; then
    echo "v6"
  else
    echo "cdn"
  fi
}

load_remote_nodes() {
  local scope="${1:-$(node_scope)}"
  local tmp err line type family prov isp host ip port target backup_host backup_ip backup_port backup_target url sep curl_status
  command -v curl &>/dev/null || return 1
  tmp=$(mktemp)
  err="${tmp}.err"
  sep="?"
  [[ "$GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${GET_NODES_URL}${sep}format=tsv&scope=${scope}"
  if ! curl -4 -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>"$err"; then
    curl_status=$?
    if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>>"$err"; then
      GET_NODES_LAST_URL="$url"
      GET_NODES_LAST_ERROR=$(tr '\n' ' ' < "$err" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-240)
      GET_NODES_LAST_STATUS="$curl_status"
      rm -f "$tmp" "$err"
      return 1
    fi
  fi
  rm -f "$err"

  REMOTE_CDN4_NODES=()
  REMOTE_CDN6_NODES=()
  REMOTE_CERNET_NODES=()
  REMOTE_CERNET2_NODES=()

  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target <<< "$line"
    [ "$type" = "type" ] && continue
    [ -n "$ip" ] || continue
    port=${port:-80}
    case "$type:$family" in
      cdn:4) REMOTE_CDN4_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cdn:6) REMOTE_CDN6_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cernet:4) REMOTE_CERNET_NODES+=("$prov|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-443}") ;;
      cernet2:6) REMOTE_CERNET2_NODES+=("$prov|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-443}") ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  if [ "${#REMOTE_CDN4_NODES[@]}" -gt 0 ] || [ "${#REMOTE_CDN6_NODES[@]}" -gt 0 ] ||
     [ "${#REMOTE_CERNET_NODES[@]}" -gt 0 ] || [ "${#REMOTE_CERNET2_NODES[@]}" -gt 0 ]; then
    REMOTE_NODES_LOADED=1
    return 0
  fi
  return 1
}

require_remote_nodes() {
  local scope="${1:-$(node_scope)}"
  if load_remote_nodes "$scope"; then
    return 0
  fi
  echo -e "${RED}[X] 无法从 getNodes 获取节点 IP+端口，请稍后重试${NC}"
  echo -e "${DIM}    getNodes: ${GET_NODES_LAST_URL:-${GET_NODES_URL}}${NC}"
  [ -n "$GET_NODES_LAST_ERROR" ] && echo -e "${DIM}    curl: ${GET_NODES_LAST_ERROR}${NC}"
  exit 1
}

print_cdn_entries() {
  local family="$1" entry prov isp host port
  local -a remote_nodes=()
  if [ "$family" = "6" ]; then
    remote_nodes=("${REMOTE_CDN6_NODES[@]}")
  else
    remote_nodes=("${REMOTE_CDN4_NODES[@]}")
  fi
  printf "%s\n" "${remote_nodes[@]}"
}

print_cernet_entries() {
  local entry prov host fixed_ip port
  printf "%s\n" "${REMOTE_CERNET_NODES[@]}"
}

print_cernet2_entries() {
  local entry prov host fixed_ip port
  printf "%s\n" "${REMOTE_CERNET2_NODES[@]}"
}

# ===================== 参数与帮助 =====================
show_help() {
  cat <<EOF
TcpQuality 节点 TCP 丢包探测脚本

用法:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) [选项]

NixOS:
  脚本会自动通过 nix shell 提供运行依赖，不会写入 environment.systemPackages。
  使用 --speedtest/--only-speedtest 时会通过 curl --resolve 固定 TOS IP 做单线程测速。

选项:
  -h, --help        显示帮助信息并退出
  -c, --count NUM   设置每节点发包数，范围 1-${MAX_PACKETS}，默认 ${PACKETS}
  -s, --size NUM    指定 IP 包总长度（单位 B），0 为标准无负载 SYN；默认 0
                     小于协议头部的数值按最小头部长度发送
  -p, --parallel NUM
                     设置并行节点数，范围 1-31，默认按内存自动选择
  -v4, --v4         仅探测 IPv4
  -v6, --v6         仅探测 IPv6
  --only-large      仅探测 IPv4大包回程
  --cernet          仅探测 CERNET IPv4 和 CERNET2 IPv6
  --all             探测 IPv4/IPv6、CERNET/CERNET2、国际互联和单线程测速
  --route           仅做三网回程线路识别，不执行 nping 丢包探测、不上传报告
  --route-protocol PROTO
                    设置 --route 的 traceroute 协议: tcp、udp、both，默认 tcp
  --speedtest       追加单线程测速（默认北京/上海/广东三地三网）
  --only-speedtest  仅运行单线程测速（默认北京/上海/广东三地三网）
  --intl            单独使用时仅运行国际互联；与 -v4/-v6/--all 等组合时追加国际互联
  --no-rank-upload  不上传报告，也不参与速度排名
  --province CODE   仅检测指定省份，可重复；也支持简写参数如 -bj、-sh、-gd
                     注意: 山西使用 -sx，陕西使用 -sn
  --debug           保留临时文件并输出调试信息，便于排查线路识别问题

国际互联：
  CDN 目标优先使用静态资源入口；每个域名最多探测 2 个公网 IPv4，结果合并统计。
  国际节点分别执行 iPerf3 上传和下载（-R）；每个方向显示 TCP RTT 与重传次数，每行最多三个节点。
  国际节点 iPerf3 默认限速 1M、测试 5 秒；每个节点/协议/方向最多尝试 10 次，成功即停止；可用 TCPQUALITY_INTERNATIONAL_IPERF_RATE/TCPQUALITY_INTERNATIONAL_IPERF_SECONDS 覆盖。
  设置 TCPQUALITY_INTERNATIONAL_MAX_IPS=1 可恢复每个域名只探测一个地址。
  --debug 还会保存国际互联目标的候选 IP、HTTP 状态、边缘和缓存信息。

示例:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -c 100
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -bj -v4 --cernet
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) --route --debug
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) --speedtest

依赖:
  - nping: 随 nmap 安装
  - curl: 用于检测公网 IPv4/IPv6 与上传报告
  - iperf3/jq/ss: 国际节点 iPerf3 TCP RTT、双向重传与反向 TCP_INFO RTT 解析
  - traceroute: 用于自动识别三网 TCP 回程线路
  - nexttrace-tiny: 可选；用于 IPv4大包回程的 TCP 1200B 大包路由识别
  - curl/iproute2: 单线程测速使用
  - awk/sed/grep: 用于结果解析和展示

安装提示:
  - NixOS:          无需安装，脚本自动进入临时 nix shell
  - Debian/Ubuntu: apt-get install -y curl nmap iperf3 iproute2 jq traceroute
  - RHEL/Fedora:   dnf install -y curl nmap iperf3 iproute jq traceroute
  - Alpine Linux:  apk add curl nmap-nping iperf3 iproute2 jq traceroute
  - Arch Linux:    pacman -S curl nmap iperf3 iproute2 jq traceroute
  - macOS:         brew install curl nmap iperf3 jq traceroute

说明:
  发送裸 TCP SYN 包通常需要 root 权限；请切换到 root 用户后运行。
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
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ] || [ "$2" -gt "$MAX_PACKETS" ]; then
          echo -e "${RED}[X] 发包数必须是 1-${MAX_PACKETS} 之间的整数${NC}" >&2
          exit 1
        fi
        PACKETS="$2"
        COUNT_EXPLICIT=1
        shift 2
        ;;
      -s|--size)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -gt 65535 ]; then
          echo -e "${RED}[X] 包长必须是 0-65535 之间的整数（单位 B）${NC}" >&2
          exit 1
        fi
        PACKET_SIZE_OVERRIDE="$2"
        shift 2
        ;;
      -p|--parallel)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ] || [ "$2" -gt 31 ]; then
          echo -e "${RED}[X] 并行节点数必须是 1-31 之间的整数${NC}" >&2
          exit 1
        fi
        PARALLEL="$2"
        PARALLEL_EXPLICIT=1
        shift 2
        ;;
      -v4|--v4)
        ONLY_IPV4=1
        shift
        ;;
      -v6|--v6)
        ONLY_IPV6=1
        shift
        ;;
      --only-large)
        ONLY_LARGE=1
        shift
        ;;
      --cernet)
        TEST_CERNET=1
        shift
        ;;
      --all)
        TEST_ALL=1
        SPEEDTEST_ENABLED=1
        INTERNATIONAL_ENABLED=1
        shift
        ;;
      --route)
        ROUTE_MODE=1
        UPLOAD_REPORT=0
        shift
        ;;
      --route-protocol)
        if [ -z "${2:-}" ] || { [ "$2" != "tcp" ] && [ "$2" != "udp" ] && [ "$2" != "both" ]; }; then
          echo -e "${RED}[X] --route-protocol 只支持 tcp、udp、both${NC}" >&2
          exit 1
        fi
        ROUTE_PROTOCOL="$2"
        shift 2
        ;;
      --speedtest)
        SPEEDTEST_ENABLED=1
        shift
        ;;
      --only-speedtest)
        SPEEDTEST_ENABLED=1
        SPEEDTEST_ONLY=1
        shift
        ;;
      --intl)
        INTL_REQUESTED=1
        INTERNATIONAL_ENABLED=1
        [ "$REPORT_UPLOAD_FORCED_OFF" -eq 1 ] || UPLOAD_REPORT=1
        shift
        ;;
      --no-rank-upload)
        UPLOAD_REPORT=0
        REPORT_UPLOAD_FORCED_OFF=1
        shift
        ;;
      --debug)
        DEBUG_MODE=1
        shift
        ;;
      --province)
        if [ -z "${2:-}" ] || ! add_province_filter "$2"; then
          echo -e "${RED}[X] 不支持的省份代码: ${2:-}${NC}" >&2
          exit 1
        fi
        shift 2
        ;;
      -??|-???)
        if add_province_filter "$1"; then
          shift
        else
          echo -e "${RED}[X] 不支持的参数: $1${NC}" >&2
          echo "使用 -h 或 --help 查看帮助。" >&2
          exit 1
        fi
        ;;
      *)
        echo -e "${RED}[X] 不支持的参数: $1${NC}" >&2
        echo "使用 -h 或 --help 查看帮助。" >&2
        exit 1
        ;;
    esac
  done

  if [ "$ONLY_LARGE" -eq 1 ]; then
    ONLY_IPV4=1
    ONLY_IPV6=0
    TEST_CERNET=0
    TEST_ALL=0
    INCLUDE_DEFAULT_ROUTE=0
    ROUTE_MODE=0
    SPEEDTEST_ENABLED=0
    SPEEDTEST_ONLY=0
    INTERNATIONAL_ENABLED=0
    INTERNATIONAL_ONLY=0
  fi

  if [ "$INTL_REQUESTED" -eq 1 ] \
    && [ "$ONLY_LARGE" -eq 0 ] \
    && [ "$ONLY_IPV4" -eq 0 ] \
    && [ "$ONLY_IPV6" -eq 0 ] \
    && [ "$TEST_CERNET" -eq 0 ] \
    && [ "$TEST_ALL" -eq 0 ] \
    && [ "$INCLUDE_DEFAULT_ROUTE" -eq 0 ] \
    && [ "$ROUTE_MODE" -eq 0 ] \
    && [ "$SPEEDTEST_ENABLED" -eq 0 ] \
    && [ -z "$SELECTED_PROVINCES" ]; then
    INTERNATIONAL_ONLY=1
  fi
}

detect_total_memory_mb() {
  local mem_kb=""
  if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    if [[ "$mem_kb" =~ ^[0-9]+$ ]] && [ "$mem_kb" -gt 0 ]; then
      echo $((mem_kb / 1024))
      return
    fi
  fi
  if command -v free >/dev/null 2>&1; then
    free -m 2>/dev/null | awk '/^Mem:/ {print $2; exit}'
    return
  fi
  echo 512
}

auto_parallel_by_memory() {
  local mem_mb parallel
  mem_mb=$(detect_total_memory_mb)
  [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=512
  parallel=$(((mem_mb + 47) / 48))
  [ "$parallel" -lt 1 ] && parallel=1
  [ "$parallel" -gt 93 ] && parallel=93
  echo "$parallel"
}

apply_auto_parallel() {
  [ "$PARALLEL_EXPLICIT" -eq 1 ] && return
  PARALLEL=$(auto_parallel_by_memory)
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
  [ "$total" -gt 0 ] 2>/dev/null || total=1
  [ "$done" -gt "$total" ] 2>/dev/null && done="$total"
  local pct=$(( done * 100 / total ))
  local fill=$(( done * width / total ))
  local empty=$(( width - fill ))
  printf "["
  printf "%${fill}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' '-'
  printf "] %d/%d (%d%%)" "$done" "$total" "$pct"
}

count_results() {
  if [ "${ROUTE_MODE:-0}" -eq 1 ]; then
    if [ -n "${ROUTE_ACTIVE_PREFIX:-}" ]; then
      find "$RESULT_DIR" -type f -name "${ROUTE_ACTIVE_PREFIX}_[0-9]*" 2>/dev/null | wc -l | tr -d ' '
    else
      find "$RESULT_DIR" -type f \( -name 'route4_[0-9]*' -o -name 'route6_[0-9]*' \) 2>/dev/null | wc -l | tr -d ' '
    fi
  else
    find "$RESULT_DIR" -maxdepth 1 -type f \( -name 'cdn4_[0-9]*' -o -name 'cdn6_[0-9]*' -o -name 'large4_[0-9]*' -o -name 'cernet_[0-9]*' -o -name 'cernet2_[0-9]*' \) 2>/dev/null | wc -l | tr -d ' '
  fi
}

show_single_progress() {
  local done now state force
  force=${1:-0}
  done=$(count_results)
  [ "$done" -gt "$TOTAL" ] && done="$TOTAL"
  now=$(date +%s)
  state="single:${done}/${TOTAL}"
  if [ "$force" -ne 1 ] && [ "$state" = "$PROGRESS_LAST_STATE" ]; then
    return 0
  fi
  if [ "$force" -ne 1 ] && [ "$done" -lt "$TOTAL" ] && [ $((now - PROGRESS_LAST_TS)) -lt "$PROGRESS_MIN_INTERVAL" ]; then
    return 0
  fi
  PROGRESS_LAST_STATE="$state"
  PROGRESS_LAST_TS="$now"
  echo -ne "\r  ${CYAN}探测进度${NC} "
  bar "$done" "$TOTAL"
  echo -ne "   "
}

count_route_progress() {
  find "$RESULT_DIR" -maxdepth 1 -type f \( -name 'summary_route[46]_[0-9]*' -o -name 'summary_large_route4_[0-9]*' \) ! -name '*.ips' 2>/dev/null | wc -l | tr -d ' '
}

count_international_progress() {
  find "$RESULT_DIR" -maxdepth 1 -type f \( \
    -name 'internet_[0-9]*' \
    -o -name 'international_latency_[46]_[a-z]*_[0-9]*' \
  \) ! -name '*.debug' ! -name '*.http' 2>/dev/null | wc -l | tr -d ' '
}

count_selected_cdn_nodes() {
  local family="$1" prov count=0
  while IFS='|' read -r prov _; do
    province_selected "$prov" && count=$((count + 1))
  done < <(print_cdn_entries "$family")
  printf '%s' "$count"
}

read_speedtest_progress() {
  local progress done total
  progress=$(cat "$SPEEDTEST_PROGRESS_FILE" 2>/dev/null || true)
  done=${progress%%/*}
  total=${progress#*/}
  if [ -n "$done" ] && [ "$done" != "$progress" ] && [ -n "$total" ]; then
    printf '%s|%s' "$done" "$total"
  else
    printf '0|%s' "${SPEEDTEST_PROGRESS_TOTAL:-0}"
  fi
}

show_all_progress() {
  local latency_done route_done internet_done speed_done speed_total speed_progress now state complete force
  force=${1:-0}
  latency_done=$(count_results)
  [ "$latency_done" -gt "$TOTAL" ] && latency_done="$TOTAL"
  route_done=$(count_route_progress)
  [ "$route_done" -gt "$ROUTE_PROGRESS_TOTAL" ] && route_done="$ROUTE_PROGRESS_TOTAL"
  internet_done=$(count_international_progress)
  [ "$internet_done" -gt "$INTERNATIONAL_PROGRESS_TOTAL" ] && internet_done="$INTERNATIONAL_PROGRESS_TOTAL"
  speed_progress=$(read_speedtest_progress)
  speed_done=${speed_progress%%|*}
  speed_total=${speed_progress#*|}
  now=$(date +%s)
  state="all:${latency_done}/${TOTAL}:${route_done}/${ROUTE_PROGRESS_TOTAL}:${internet_done}/${INTERNATIONAL_PROGRESS_TOTAL}:${speed_done}/${speed_total}"
  complete=0
  if [ "$latency_done" -ge "$TOTAL" ] \
    && { [ "$ROUTE_PROGRESS_TOTAL" -eq 0 ] || [ "$route_done" -ge "$ROUTE_PROGRESS_TOTAL" ]; } \
    && { [ "$INTERNATIONAL_PROGRESS_TOTAL" -eq 0 ] || [ "$internet_done" -ge "$INTERNATIONAL_PROGRESS_TOTAL" ]; } \
    && { [ "$SPEEDTEST_ENABLED" -ne 1 ] || [ "$speed_done" -ge "$speed_total" ]; }; then
    complete=1
  fi
  if [ "$force" -ne 1 ] && [ "$state" = "$PROGRESS_LAST_STATE" ]; then
    return 0
  fi
  if [ "$force" -ne 1 ] && [ "$complete" -ne 1 ] && [ $((now - PROGRESS_LAST_TS)) -lt "$PROGRESS_MIN_INTERVAL" ]; then
    return 0
  fi
  PROGRESS_LAST_STATE="$state"
  PROGRESS_LAST_TS="$now"

  if [ "$PROGRESS_LINES_PRINTED" -gt 0 ]; then
    printf '\033[%dA' "$PROGRESS_LINES_PRINTED"
  fi
  if [ "$TOTAL" -gt 0 ]; then
    printf '\r\033[2K  %b延迟重传%b ' "$CYAN" "$NC"
    bar "$latency_done" "$TOTAL"
    printf '\n'
  fi
  if [ "$ROUTE_PROGRESS_TOTAL" -gt 0 ]; then
    printf '\r\033[2K  %b回程识别%b ' "$CYAN" "$NC"
    bar "$route_done" "$ROUTE_PROGRESS_TOTAL"
    printf '\n'
  fi
  if [ "$INTERNATIONAL_PROGRESS_TOTAL" -gt 0 ]; then
    printf '\r\033[2K  %b国际互联%b ' "$CYAN" "$NC"
    bar "$internet_done" "$INTERNATIONAL_PROGRESS_TOTAL"
    printf '\n'
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    printf '\r\033[2K  %b速度测试%b ' "$CYAN" "$NC"
    bar "$speed_done" "$speed_total"
    printf '\n'
  fi
  PROGRESS_LINES_PRINTED=$(((TOTAL > 0) + (SPEEDTEST_ENABLED == 1) + (ROUTE_PROGRESS_TOTAL > 0) + (INTERNATIONAL_PROGRESS_TOTAL > 0)))
}

show_progress() {
  local force=${1:-0}
  if [ "${MULTI_PROGRESS_MODE:-0}" -eq 1 ]; then
    show_all_progress "$force"
  else
    show_single_progress "$force"
  fi
}

awk_table_helpers() {
  cat <<'AWK'
  function display_width(text) {
    if (text == "三网概览") return 8
    if (text == "教育网概览") return 10
    if (text == "黑龙江" || text == "内蒙古") return 6
    if (text == "区域" || text == "节点" || text == "服务" || text == "域名" || text == "可达" || text == "延迟") return 4
    if (text == "亚洲" || text == "美洲" || text == "欧洲" || text == "悉尼" || text == "香港" || text == "日本") return 4
    if (text == "大洋洲") return 6
    if (text == "新加坡") return 6
    if (text == "澳大利亚-悉尼") return 13
    if (text == "加拿大-蒙特利尔" || text == "巴西-里约热内卢" || text == "荷兰-阿姆斯特丹") return 15
    if (text == "德国-法兰克福") return 13
    if (text == "英国-伦敦") return 9
    if (text == "美国西部-洛杉矶" || text == "美国中部-达拉斯" || text == "美国东部-芝加哥") return 15
    if (text == "丢包率") return 6
    if (text == "重传") return 4
    if (text == "✓" || text == "x") return 1
    return length(text)
  }
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function spaces(width) {
    if (width <= 0) return ""
    return sprintf("%" width "s", "")
  }
  function center(text, width,   left, right) {
    left = int((width - length(text)) / 2)
    right = width - length(text) - left
    return spaces(left) text spaces(right)
  }
  function center_display(text, width, display_width_value,   left, right) {
    left = int((width - display_width_value) / 2)
    right = width - display_width_value - left
    return spaces(left) text spaces(right)
  }
  function pad_right(text, width,   pad) {
    pad = width - display_width(text)
    if (pad < 0) pad = 0
    return text spaces(pad)
  }
  function pad_left(text, width,   pad) {
    pad = width - display_width(text)
    if (pad < 0) pad = 0
    return spaces(pad) text
  }
  function sep(width,   s, i) {
    s = ""
    for (i = 0; i < width; i++) s = s "-"
    return s
  }
AWK
}

show_provider_summary() {
  local file="$1" route_file="${2:-}"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    label_w = 10
    route_w = 11
    latency_w = 6
    loss_w = 6
    summary_cell_w = route_w + 1 + latency_w + 1 + loss_w
  }
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function spaces(width) {
    if (width <= 0) return ""
    return sprintf("%" width "s", "")
  }
  function center(text, width,   left, right) {
    left = int((width - length(text)) / 2)
    right = width - length(text) - left
    return spaces(left) text spaces(right)
  }
  function center_display(text, width, display_width_value,   left, right) {
    left = int((width - display_width_value) / 2)
    right = width - display_width_value - left
    return spaces(left) text spaces(right)
  }
  function header_align_latency(text,   left, right) {
    left = route_w + 1 + latency_w - display_width(text)
    right = summary_cell_w - route_w - 1 - latency_w
    return spaces(left) text spaces(right)
  }
  function display_width(text) {
    if (text == "三网概览") return 8
    if (text == "黑龙江" || text == "内蒙古") return 6
    return 4
  }
  function label_cell(text,   pad) {
    pad = label_w - display_width(text)
    if (pad < 0) pad = 0
    return text spaces(pad)
  }
  function format_summary_cell(label, latency, loss, latency_color_value, loss_color_value) {
    return white sprintf("%" route_w "s", label) nc " " latency_color_value sprintf("%" latency_w "s", latency) nc " " loss_color_value sprintf("%" loss_w "s", loss) nc
  }
  function latency_color(v, l) {
    if (l >= 100) return red
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function latency_text(v, l) {
    if (l >= 100) return "-1ms"
    return sprintf("%.0fms", v)
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat, label,   l, v, latency, loss_text) {
    if (label == "") label = "Hidden"
    if (status != "OK") {
      return format_summary_cell("failed", "failed", "failed", red, red)
    }
    l = loss + 0
    v = lat + 0
    latency = latency_text(v, l)
    loss_text = compact_loss(loss) "%"
    return format_summary_cell(label, latency, loss_text, latency_color(v, l), loss_color(l))
  }
  function route_label(prov, isp) {
    return ((prov SUBSEP isp) in route) ? route[prov SUBSEP isp] : isp
  }
  FILENAME == ARGV[1] && NF >= 6 {
    if ($1 == "OK") route[$2 SUBSEP $3] = $6
    else route[$2 SUBSEP $3] = "Hidden"
    next
  }
  {
    status = $1
    prov = $2
    isp = $3
    rcv = $7
    loss = $8
    lat = $9
    label = route_label(prov, isp)
    if (!(prov in seen)) {
      seen[prov] = 1
      order[++n] = prov
    }
    data[prov SUBSEP isp] = cell(status, loss, lat, label)
  }
  END {
    printf "  %s%s%s%s  %s%s%s %s/ %s%s%s %s/ %s%s%s\n", bold, cyan, label_cell("三网概览"), nc, cyan, header_align_latency("电信"), nc, white, cyan, header_align_latency("联通"), nc, white, cyan, header_align_latency("移动"), nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      printf "  %s%s%s  %s %s/ %s %s/ %s\n", cyan, label_cell(prov), nc, data[prov SUBSEP "电信"], white, data[prov SUBSEP "联通"], white, data[prov SUBSEP "移动"]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, nc
  }' "${route_file:-/dev/null}" "$file"
}

show_family_results() {
  local family="$1" file="$2" route_file="${3:-}"
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
  show_provider_summary "$file" "$route_file"
}

show_large_packet_results() {
  local title="$1" file="$2" route_file="${3:-}" firewall_limited="${4:-0}"
  awk -F'|' -v title="$title" -v firewall_limited="$firewall_limited" -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    label_w = 10
    route_w = 11
    latency_w = 6
    loss_w = 6
    summary_cell_w = route_w + 1 + latency_w + 1 + loss_w
  }
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function spaces(width) {
    if (width <= 0) return ""
    return sprintf("%" width "s", "")
  }
  function display_width(text) {
    if (text == "三网概览") return 8
    if (text == "黑龙江" || text == "内蒙古") return 6
    return 4
  }
  function label_cell(text,   pad) {
    pad = label_w - display_width(text)
    if (pad < 0) pad = 0
    return text spaces(pad)
  }
  function header_align_latency(text,   left, right) {
    left = route_w + 1 + latency_w - display_width(text)
    right = summary_cell_w - route_w - 1 - latency_w
    return spaces(left) text spaces(right)
  }
  function format_summary_cell(label, latency, loss, latency_color_value, loss_color_value) {
    return white sprintf("%" route_w "s", label) nc " " latency_color_value sprintf("%" latency_w "s", latency) nc " " loss_color_value sprintf("%" loss_w "s", loss) nc
  }
  function latency_color(v, l) {
    if (l >= 100) return red
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function latency_text(v, l) {
    if (l >= 100) return "-1ms"
    return sprintf("%.0fms", v)
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat, label,   l, v, latency, loss_text) {
    if (label == "") label = "Hidden"
    if (status == "SKIP") return format_summary_cell(label, "-", "-", red, red)
    if (status != "OK") return format_summary_cell("failed", "failed", "failed", red, red)
    l = loss + 0
    v = lat + 0
    latency = latency_text(v, l)
    loss_text = compact_loss(loss) "%"
    return format_summary_cell(label, latency, loss_text, latency_color(v, l), loss_color(l))
  }
  function route_label(prov, isp) {
    return ((prov SUBSEP isp) in route) ? route[prov SUBSEP isp] : isp
  }
  FILENAME == ARGV[1] && NF >= 6 {
    if ($1 == "OK") route[$2 SUBSEP $3] = $6
    else route[$2 SUBSEP $3] = "Hidden"
    next
  }
  FILENAME == ARGV[2] {
    status = $1
    prov = $2
    isp = $3
    loss = $8
    lat = $9
    label = route_label(prov, isp)
    if (!(prov in seen)) {
      seen[prov] = 1
      order[++n] = prov
    }
    data[prov SUBSEP isp] = cell(status, loss, lat, label)
    if (status == "SKIP") h++
    else if (status != "OK") h++
    else if (int(loss + 0) == 0) z++
    else if (int(loss + 0) <= 20) y++
    else h++
  }
  END {
    printf "  %s%s%s 统计摘要%s\n", bold, cyan, title, nc
    printf "  %s零重传:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n", green, z, nc, yellow, y, nc, red, h, nc
    if (firewall_limited + 0 == 1) {
      printf "  %s由于服务商防火墙限制，延迟和丢包无法探测%s\n", red, nc
    }
    printf "\n"
    printf "  %s%s%s%s  %s%s%s %s/ %s%s%s %s/ %s%s%s\n", bold, cyan, label_cell("三网概览"), nc, cyan, header_align_latency("电信"), nc, white, cyan, header_align_latency("联通"), nc, white, cyan, header_align_latency("移动"), nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      printf "  %s%s%s  %s %s/ %s %s/ %s\n", cyan, label_cell(prov), nc, data[prov SUBSEP "电信"], white, data[prov SUBSEP "联通"], white, data[prov SUBSEP "移动"]
    }
    if (firewall_limited + 0 == 1) {
      printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n", dim, green, dim, yellow, dim, red, nc
      printf "  %s提示: 由于服务商防火墙限制，延迟和丢包无法探测%s\n\n", red, nc
    } else {
      printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n", dim, green, dim, yellow, dim, red, nc
      printf "\n"
    }
  }' "${route_file:-/dev/null}" "$file"
}

show_education_results() {
  local title="$1" file="$2"
  awk -F'|' -v title="$title" -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    route_w = 14
    latency_w = 6
    loss_w = 6
  }
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function latency_color(v, l) {
    if (l >= 100) return red
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function latency_text(v, l) {
    if (l >= 100) return "-1ms"
    return sprintf("%.0fms", v)
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat, label,   l, v, color) {
    if (label == "") label = title
    if (status != "OK") return white sprintf("%" route_w "s", "failed") nc " " red sprintf("%" latency_w "s", "failed") nc " " red sprintf("%" loss_w "s", "failed") nc
    l = loss + 0
    v = lat + 0
    return white sprintf("%" route_w "s", label) nc " " latency_color(v, l) sprintf("%" latency_w "s", latency_text(v, l)) nc " " loss_color(l) sprintf("%" loss_w "s", compact_loss(loss) "%") nc
  }
  {
    status = $1
    prov = $2
    loss = $8
    lat = $9
    label = $10
    result[prov] = cell(status, loss, lat, label)
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
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, nc
  }' "$file"
}

show_education_combined() {
  local ipv4_file="$1" ipv6_file="$2"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    label_w = 10
    route_w = 18
    latency_w = 6
    loss_w = 6
    edu_cell_w = route_w + 1 + latency_w + 1 + loss_w
  }
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function latency_color(v, l) {
    if (l >= 100) return red
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function latency_text(v, l) {
    if (l >= 100) return "-1ms"
    return sprintf("%.0fms", v)
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function center(text, width,   left, right) {
    left = int((width - length(text)) / 2)
    right = width - length(text) - left
    return spaces(left) text spaces(right)
  }
  function spaces(width) {
    if (width <= 0) return ""
    return sprintf("%" width "s", "")
  }
  function display_width(text) {
    if (text == "教育网概览") return 10
    if (text == "黑龙江" || text == "内蒙古") return 6
    return 4
  }
  function label_cell(text,   pad) {
    pad = label_w - display_width(text)
    if (pad < 0) pad = 0
    return text spaces(pad)
  }
  function format_edu_cell(label, latency, loss, latency_color_value, loss_color_value) {
    return white sprintf("%" route_w "s", label) nc " " latency_color_value sprintf("%" latency_w "s", latency) nc " " loss_color_value sprintf("%" loss_w "s", loss) nc
  }
  function cell(status, loss, lat, label, fallback,   l, v, latency, loss_text) {
    if (label == "") label = fallback
    if (status != "OK") return format_edu_cell("failed", "failed", "failed", red, red)
    l = loss + 0
    v = lat + 0
    latency = latency_text(v, l)
    loss_text = compact_loss(loss) "%"
    return format_edu_cell(label, latency, loss_text, latency_color(v, l), loss_color(l))
  }
  {
    generation = (FILENAME == ARGV[1]) ? 1 : 2
    status = $1
    prov = $2
    loss = $8
    lat = $9
    label = $10
    fallback = "Hidden"
    result[prov SUBSEP generation] = cell(status, loss, lat, label, fallback)
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
    printf "  %s%s教育网回程 统计摘要%s\n", bold, cyan, nc
    printf "  CERNET-IPv4  %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n", green, z[1], nc, yellow, y[1], nc, red, h[1], nc
    printf "  CERNET2-IPv6 %s零丢包:%3d%s  %s1-20%%:%3d%s  %s>20%%:%3d%s\n\n", green, z[2], nc, yellow, y[2], nc, red, h[2], nc
    printf "  %s%s%s%s  %s%s%s %s/ %s%s%s\n", bold, cyan, label_cell("教育网概览"), nc, cyan, center("CERNET-IPv4", edu_cell_w), nc, white, cyan, center("CERNET2-IPv6", edu_cell_w), nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      printf "  %s%s%s  %s %s/ %s\n", cyan, label_cell(prov), nc, result[prov SUBSEP 1], white, result[prov SUBSEP 2]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, nc
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
  [ "$IPV6_WORK" -eq 1 ]
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

is_valid_ipv6() {
  local ip="$1"
  [[ "$ip" =~ : ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  case "$ip" in
    ""|::1|fe80:*|fc00:*|fd00:*|2001:db8:*|::ffff:*|2002:*) return 1 ;;
  esac
  return 0
}

get_public_ipv4() {
  local api response
  local apis=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
    "https://ifconfig.co/ip"
    "https://ident.me"
    "https://ip.sb"
  )
  for api in "${apis[@]}"; do
    response=$(curl -fsS4L --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if [[ "$response" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_public_ipv4 "$response"; then
      IPV4_PUBLIC="$response"
      IPV4_WORK=1
      return 0
    fi
  done
  IPV4_PUBLIC=""
  IPV4_WORK=0
  return 1
}

get_public_ipv6() {
  local api response
  local apis=(
    "https://api6.ipify.org"
    "https://ipv6.icanhazip.com"
    "https://ifconfig.co/ip"
    "https://ident.me"
  )
  for api in "${apis[@]}"; do
    response=$(curl -6 -fsSL --connect-timeout 5 --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if is_valid_ipv6 "$response"; then
      IPV6_PUBLIC="$response"
      IPV6_WORK=1
      return 0
    fi
  done
  IPV6_PUBLIC=""
  IPV6_WORK=0
  return 1
}

detect_ip_stack() {
  get_public_ipv4 || true
  get_public_ipv6 || true
}

ipv4_available() {
  [ "$IPV4_WORK" -eq 1 ]
}

report_api_base() {
  printf '%s' "${REPORT_API%/generate}"
}

ensure_public_ips_for_rank() {
  if [ -z "${IPV4_PUBLIC:-}" ]; then
    get_public_ipv4 || true
  fi
  if [ -z "${IPV6_PUBLIC:-}" ]; then
    get_public_ipv6 || true
  fi
}

upload_route_trace_bundle() {
  local report_id="$1" section="$2" prefix="$3" trace_glob bundle list_file manifest_file response_file endpoint http_code count
  trace_glob="$RESULT_DIR/${prefix}_trace_*"
  compgen -G "$trace_glob" >/dev/null || return 0
  command -v tar >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  bundle=$(mktemp "${TMPDIR:-/tmp}/tcpquality-${section}.XXXXXX.tar.gz") || return 0
  list_file=$(mktemp "${TMPDIR:-/tmp}/tcpquality-${section}.XXXXXX.list") || {
    rm -f "$bundle"
    return 0
  }
  manifest_file="$RESULT_DIR/${prefix}_trace_manifest.json"
  count=$(find "$RESULT_DIR" -maxdepth 1 -type f -name "${prefix}_trace_*" | wc -l | tr -d ' ')
  printf '{"reportId":"%s","section":"%s","prefix":"%s","generatedAt":"%s","traceFiles":%s}\n' \
    "$report_id" "$section" "$prefix" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${count:-0}" > "$manifest_file"
  find "$RESULT_DIR" -maxdepth 1 -type f -name "${prefix}_trace_*" -exec basename {} \; > "$list_file"
  basename "$manifest_file" >> "$list_file"
  if ! tar -C "$RESULT_DIR" -czf "$bundle" -T "$list_file" 2>/dev/null; then
    rm -f "$bundle" "$list_file"
    return 0
  fi

  response_file=$(mktemp)
  endpoint="$(report_api_base)/route-traces/${report_id}.${section}.tar.gz"
  if http_code=$(curl -4 -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: application/gzip' \
    --data-binary "@$bundle" "$endpoint" 2>/dev/null); then
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf '%s\n' "$http_code" > "$RESULT_DIR/route_trace_${section}_upload_http_code.txt"
      cp "$response_file" "$RESULT_DIR/route_trace_${section}_upload_response.json" 2>/dev/null || true
    fi
  elif [ "$DEBUG_MODE" -eq 1 ]; then
    printf '%s\n' "curl_failed" > "$RESULT_DIR/route_trace_${section}_upload_http_code.txt"
  fi
  rm -f "$bundle" "$list_file" "$response_file"
}

upload_route_trace_bundles() {
  local report_id="$1"
  [ -n "$report_id" ] || return 0
  upload_route_trace_bundle "$report_id" "ipv4" "summary_route4"
  upload_route_trace_bundle "$report_id" "ipv4_large" "summary_large_route4"
  upload_route_trace_bundle "$report_id" "ipv6" "summary_route6"
  upload_route_trace_bundle "$report_id" "cernet_ipv4" "edu_route4"
  upload_route_trace_bundle "$report_id" "cernet2_ipv6" "edu_route6"
}

upload_speedtest_debug_bundle() {
  local report_id="$1" debug_dir="$RESULT_DIR/speedtest-debug" bundle response_file endpoint http_code
  [ -n "$report_id" ] || return 0
  [ -d "$debug_dir" ] || return 0
  find "$debug_dir" -type f | grep -q . || return 0
  command -v tar >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  printf '{"reportId":"%s","generatedAt":"%s","type":"speedtest-debug"}\n' \
    "$report_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$debug_dir/manifest.json"
  bundle=$(mktemp "${TMPDIR:-/tmp}/tcpquality-speedtest-debug.XXXXXX.tar.gz") || return 0
  if ! tar -C "$debug_dir" -czf "$bundle" . 2>/dev/null; then
    rm -f "$bundle"
    return 0
  fi

  response_file=$(mktemp)
  endpoint="$(report_api_base)/speedtest-debug/${report_id}.tar.gz"
  if http_code=$(curl -4 -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: application/gzip' \
    --data-binary "@$bundle" "$endpoint" 2>/dev/null); then
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf '%s\n' "$http_code" > "$RESULT_DIR/speedtest_debug_upload_http_code.txt"
      cp "$response_file" "$RESULT_DIR/speedtest_debug_upload_response.json" 2>/dev/null || true
    fi
  elif [ "$DEBUG_MODE" -eq 1 ]; then
    printf '%s\n' "curl_failed" > "$RESULT_DIR/speedtest_debug_upload_http_code.txt"
  fi
  rm -f "$bundle" "$response_file"
}

upload_probe_debug_bundle() {
  local report_id="$1" bundle list_file response_file endpoint http_code count
  [ "${DEBUG_MODE:-0}" -eq 1 ] || return 0
  [ -n "$report_id" ] || return 0
  command -v tar >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  list_file=$(mktemp "${TMPDIR:-/tmp}/tcpquality-probe-debug.XXXXXX.list") || return 0
  {
    find "$RESULT_DIR" -maxdepth 1 -type f \
      \( -name 'nping_*.log' \
        -o -name 'nping_*_meta.txt' \
        -o -name 'backup_retry_meta.txt' \
        -o -name 'route_debug_meta.txt' \
        -o -name 'report_upload.csv' \
        -o -name 'report_upload*.json' \
        -o -name 'report_upload*.txt' \
        -o -name 'route_trace_*_upload*.json' \
        -o -name 'route_trace_*_upload*.txt' \
        -o -name 'speedtest_debug_upload*.json' \
        -o -name 'speedtest_debug_upload*.txt' \
        -o -name 'speedtest.log' \
        -o -name 'speedtest.progress' \
        -o -name 'speedtest.state' \
        -o -name 'internet_*.ips' \
        -o -name 'internet_*.http' \) \
      -exec basename {} \;
    find "$RESULT_DIR" -maxdepth 2 -type f -path '*/speedtest.*/*' \
      | sed "s#^$RESULT_DIR/##"
  } | sort -u > "$list_file"
  count=$(wc -l < "$list_file" | tr -d ' ')
  [ "${count:-0}" -gt 0 ] 2>/dev/null || {
    rm -f "$list_file"
    return 0
  }

  printf '{"reportId":"%s","generatedAt":"%s","type":"probe-debug","files":%s}\n' \
    "$report_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${count:-0}" > "$RESULT_DIR/probe_debug_manifest.json"
  printf '%s\n' "probe_debug_manifest.json" >> "$list_file"

  bundle=$(mktemp "${TMPDIR:-/tmp}/tcpquality-probe-debug.XXXXXX.tar.gz") || {
    rm -f "$list_file"
    return 0
  }
  if ! tar -C "$RESULT_DIR" -czf "$bundle" -T "$list_file" 2>/dev/null; then
    rm -f "$bundle" "$list_file"
    return 0
  fi

  response_file=$(mktemp)
  endpoint="$(report_api_base)/probe-debug/${report_id}.tar.gz"
  if http_code=$(curl -4 -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: application/gzip' \
    --data-binary "@$bundle" "$endpoint" 2>/dev/null); then
    printf '%s\n' "$http_code" > "$RESULT_DIR/probe_debug_upload_http_code.txt"
    cp "$response_file" "$RESULT_DIR/probe_debug_upload_response.json" 2>/dev/null || true
  else
    printf '%s\n' "curl_failed" > "$RESULT_DIR/probe_debug_upload_http_code.txt"
  fi
  rm -f "$bundle" "$list_file" "$response_file"
}

upload_report() {
  local csv="$1" report_time="${2:-}" response_file curl_err http_code report_id report_url today_uses total_uses rank_updated rank_reject_reason rank_finished_at
  local rank_headers=()
  if ! command -v curl &>/dev/null; then
    echo -e "  ${YELLOW}[!] 依赖不完整，已跳过 SVG 报告上传${NC}"
    return
  fi
  if grep -qE '^(Speedtest|三网单线程速度),' "$csv" 2>/dev/null; then
    ensure_public_ips_for_rank
  fi
  if [ -n "${RANK_SESSION_ID:-}" ] && [ -n "${RANK_SESSION_TOKEN:-}" ]; then
    rank_headers+=(-H "X-TcpQuality-Rank-Session: $RANK_SESSION_ID")
    rank_headers+=(-H "X-TcpQuality-Rank-Token: $RANK_SESSION_TOKEN")
    rank_headers+=(-H "X-TcpQuality-Rank-Started-At: ${RANK_SESSION_STARTED_AT:-}")
    rank_headers+=(-H "X-TcpQuality-Rank-Expires-At: ${RANK_SESSION_EXPIRES_AT:-}")
    rank_headers+=(-H "X-TcpQuality-Rank-Session-IPv4: ${RANK_SESSION_IP4:-}")
  fi
  if [ -n "${SPEEDTEST_RANK_DISABLED_REASON:-}" ]; then
    rank_headers+=(-H "X-TcpQuality-Rank-Disabled-Reason: $SPEEDTEST_RANK_DISABLED_REASON")
  fi

  response_file=$(mktemp)
  curl_err=$(mktemp)
  if [ "$DEBUG_MODE" -eq 1 ] && [ -f "$csv" ]; then
    cp "$csv" "$RESULT_DIR/report_upload.csv" 2>/dev/null || true
  fi
  rank_finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if ! http_code=$(curl -4 -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: text/csv; charset=utf-8' \
    -H "X-Report-Time: $report_time" \
    -H "X-TcpQuality-Public-IPv4: ${IPV4_PUBLIC:-}" \
    -H "X-TcpQuality-Public-IPv6: ${IPV6_PUBLIC:-}" \
    -H "X-TcpQuality-Rank-Finished-At: $rank_finished_at" \
    "${rank_headers[@]}" \
    --data-binary "@$csv" "$REPORT_API" 2>"$curl_err"); then
    echo -e "  ${YELLOW}[!] SVG 报告上传失败，本地 CSV 已保留${NC}"
    if [ "$DEBUG_MODE" -eq 1 ]; then
      cp "$response_file" "$RESULT_DIR/report_upload_response.json" 2>/dev/null || true
      cp "$curl_err" "$RESULT_DIR/report_upload_curl.err" 2>/dev/null || true
      printf '%s\n' "curl_failed" > "$RESULT_DIR/report_upload_http_code.txt"
    fi
    rm -f "$response_file" "$curl_err"
    return
  fi
  rm -f "$curl_err"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$response_file" "$RESULT_DIR/report_upload_response.json" 2>/dev/null || true
    printf '%s\n' "$http_code" > "$RESULT_DIR/report_upload_http_code.txt"
  fi

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    report_id=$(sed -nE 's/.*"id":"([^"]+)".*/\1/p' "$response_file" | head -1)
    report_url=$(sed -nE 's/.*"url":"([^"]+)".*/\1/p' "$response_file" | head -1)
    today_uses=$(sed -nE 's/.*"todayUses":([0-9]+).*/\1/p' "$response_file" | head -1)
    total_uses=$(sed -nE 's/.*"totalUses":([0-9]+).*/\1/p' "$response_file" | head -1)
    rank_updated=$(sed -nE 's/.*"rankUpdated":(true|false).*/\1/p' "$response_file" | head -1)
    rank_reject_reason=$(sed -nE 's/.*"rankRejectReason":"([^"]*)".*/\1/p' "$response_file" | head -1)
  fi
  if [ -n "$report_id" ]; then
    upload_route_trace_bundles "$report_id"
    upload_speedtest_debug_bundle "$report_id"
    upload_probe_debug_bundle "$report_id"
  fi
  if [ -n "$report_url" ]; then
    echo -e "  ${WHITE}报告链接：${UNDERLINE}${report_url}${NC}"
    if [ -n "$today_uses" ] && [ -n "$total_uses" ]; then
      echo -e "  ${DIM}今日TCP脚本使用次数：${today_uses}；总使用次数：${total_uses}。感谢使用ibsgss网络质量检测脚本！${NC}"
    fi
    if [ "$DEBUG_MODE" -eq 1 ] && [ "$rank_updated" = "false" ] && [ -n "$rank_reject_reason" ]; then
      echo -e "  ${YELLOW}[!] 排名未更新：${rank_reject_reason}${NC}"
    fi
  else
    echo -e "  ${YELLOW}[!] SVG 报告上传失败（HTTP $http_code），本地 CSV 已保留${NC}"
  fi
  rm -f "$response_file"
}

# ===================== 三网回程线路识别 =====================
extract_trace_ips() {
  local trace_file="$1"
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function public_v6(ip) {
      if (ip !~ /:/ || ip !~ /^[0-9A-Fa-f:]+$/) return 0
      if (ip ~ /^::1$/ || ip ~ /^fe80:/ || ip ~ /^fc/ || ip ~ /^fd/) return 0
      return 1
    }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      for (i = 1; i <= NF; i++) {
        field = $i
        gsub(/[^0-9A-Fa-f:.%]/, " ", field)
        count = split(field, tokens, /[[:space:]]+/)
        for (j = 1; j <= count; j++) {
          token = tokens[j]
          sub(/%.*/, "", token)
          gsub(/^:+|:+$/, "", token)
          if (public_v4(token)) print token
          else if (public_v6(token)) print token
        }
      }
    }
  ' "$trace_file"
}

route_needs_10099_hidden_tcp_retry() {
  local trace_file="$1"
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function is_10099(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./
    }
    function is_4837(ip) {
      return ip ~ /^219\.158\./
    }
    function is_9929(ip) {
      return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./
    }
    function is_163(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./
    }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ { next }
    {
      line = $0
      has_ip = 0
      while (match(line, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (!public_v4(ip)) continue
        has_ip = 1
        if (is_10099(ip)) {
          seen_10099 = 1
          after_10099 = 1
          continue
        }
        if (!after_10099) continue
        if (is_4837(ip) || is_9929(ip)) seen_unicom_domestic = 1
        if (is_163(ip)) seen_163 = 1
      }
      if (after_10099 && !seen_163 && !has_ip && $0 ~ /\*/) hidden_after_10099++
    }
    END {
      exit !(seen_10099 && seen_163 && !seen_unicom_domestic && hidden_after_10099 >= 2)
    }
  ' "$trace_file"
}

query_cymru_asn() {
  local ip_file="$1" out_file="$2" req_file
  req_file=$(mktemp)
  {
    echo "begin"
    echo "verbose"
    sort -u "$ip_file"
    echo "end"
  } > "$req_file"

  if command -v timeout &>/dev/null; then
    timeout 35 bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  else
    bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  fi
  rm -f "$req_file"
}

build_asn_map() {
  local cymru_file="$1" map_file="$2"
  awk -F'|' '
    NR == 1 { next }
    {
      asn = $1
      ip = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", asn)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
      owner = $7
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
      count = split(asn, values, /[[:space:]]+/)
      asn = values[count]
      if (asn ~ /^[0-9]+$/ && ip ~ /^[0-9A-Fa-f:.]+$/) print tolower(ip) "|" asn "|" owner
    }
  ' "$cymru_file" > "$map_file"
}

append_server_asn_meta() {
  local ip_file="$1" map_file="$2" response_file
  [ -s "$ip_file" ] || return 0
  response_file=$(mktemp)
  if curl -4 -fsSL --connect-timeout 5 --max-time 20 \
      -X POST -H 'content-type: text/plain; charset=utf-8' \
      --data-binary "@$ip_file" "$ROUTE_ASN_API" > "$response_file" 2>/dev/null; then
    awk -F'\t' '
      NR == 1 { next }
      {
        ip = tolower($1)
        asn = $2
        owner = $3
        sub(/^[Aa][Ss]/, "", asn)
        gsub(/[|\r\n]+/, " ", owner)
        if (ip ~ /^[0-9A-Fa-f:.]+$/ && asn ~ /^[0-9]+$/) print ip "|" asn "|" owner
      }
    ' "$response_file" >> "$map_file"
  fi
  rm -f "$response_file"
}

route_label_from_ip_trace() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3"
  local target_isp="${4:-}"
  awk -F'|' -v target_isp="$target_isp" '
    function infer_asn_from_ip(ip) {
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./) return "23764"
      if (ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./) return "4134"
      if (ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./) return "4837"
      if (ip ~ /^2408:/) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./) return "10099"
      if (ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./) return "9929"
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      if (ip ~ /^159\.226\./) return "7497"
      return ""
    }
    function has_asn(v) { return index(all_asn, "AS" v " ") > 0 }
    function add_asn(asn) {
      if (asn != "" && index(all_asn, "AS" asn " ") == 0) all_asn = all_asn "AS" asn " "
    }
    function is_ctgnet_ip(ip) {
      return ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/
    }
    function is_ctgnet_transit_ip(ip) {
      return is_ctgnet_ip(ip)
    }
    function is_163_ip(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/
    }
    function is_telecom_access_asn(asn) {
      return asn == "4134" || asn == "4811" || asn == "4812" || asn == "4847" || asn == "23724" || asn == "134756" || asn == "133776" || asn == "139201" || asn == "139203" || asn == "148969" || asn == "38283" || asn == "58540" || asn == "58563"
    }
    function is_telecom_access_ip(ip) {
      return ip ~ /^1\.202\./ || ip ~ /^27\.129\./ || ip ~ /^36\.110\./ || ip ~ /^36\.112\./ || ip ~ /^58\.213\./ || ip ~ /^101\.95\./ || ip ~ /^101\.226\./ || ip ~ /^106\.227\./ || ip ~ /^111\.74\./ || ip ~ /^117\.21\./ || ip ~ /^117\.68\./ || ip ~ /^124\.127\./ || ip ~ /^140\.249\./ || ip ~ /^180\.102\./ || ip ~ /^183\.47\./ || ip ~ /^219\.148\./ || ip ~ /^220\.181\./
    }
    function is_mobile_access_asn(asn) {
      return asn == "24547" || asn == "132510"
    }
    function is_mobile_access_ip(ip) {
      return ip ~ /^111\.63\./ || ip ~ /^183\.201\./ || ip ~ /^183\.203\./
    }
    function is_cmin2_asn(asn) {
      return asn == "58807"
    }
    function is_cmi_asn(asn) {
      return asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/
    }
    function compact_combo_label(label,   parts, n) {
      n = split(label, parts, "->")
      if (n > 2) return parts[1] "->" parts[n]
      return label
    }
    function mobile_label_before(last,   h, has_cmin2, has_cmi) {
      if (last <= 1) return ""
      for (h = 1; h < last; h++) {
        if (is_cmin2_asn(asns[h])) has_cmin2 = 1
        if (is_cmi_asn(asns[h]) || (target_isp == "移动" && (is_mobile_access_asn(asns[h]) || is_mobile_access_ip(ips[h])))) has_cmi = 1
      }
      if (has_cmin2 && has_cmi) return "CMIN2->CMI"
      if (has_cmin2) return "CMIN2"
      if (has_cmi) return "CMI"
      return ""
    }
    function is_oversea_163_ip(ip) {
      return ip ~ /^218\.30\./ || ip ~ /^145\.14\./ || ip ~ /^5\.154\./
    }
    function is_oversea_10099_ip(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.3[2-9]\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/
    }
    function is_10099_entry_ip(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/
    }
    function is_10099_hop(asn, ip) {
      # ASN 查询结果是权威判断；前缀只在 ASN 缺失时作为兜底。
      return asn == "10099" || (asn == "" && is_10099_entry_ip(ip))
    }
    function is_oversea_cn2_ip(ip) {
      return ip ~ /^2605:9d80:/
    }
    function is_unicom_backbone_ip(ip) {
      return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^219\.158\./ || ip ~ /^2408:/
    }
    function is_unicom_backbone_asn(asn) {
      return asn == "9929" || asn == "4837" || asn == "4808"
    }
    function is_unicom_access_asn(asn) {
      return asn == "17816" || asn == "135061" || asn == "136958" || asn == "140979"
    }
    function is_unicom_route_hop(h) {
      return is_unicom_backbone_asn(asns[h]) || is_unicom_backbone_ip(ips[h]) || is_unicom_access_asn(asns[h])
    }
    function has_163_before(last,   h) {
      if (last <= 1) return 0
      for (h = 1; h < last; h++) {
        if (asns[h] == "4134" || asns[h] == "4847" || is_163_ip(ips[h])) return 1
      }
      return 0
    }
    function unicom_domestic_label_from_hop(first,   h, has_4837) {
      for (h = first + 1; h <= max_hop; h++) {
        if (asns[h] == "9929" || ips[h] ~ /^210\.14\./ || ips[h] ~ /^210\.51\./ || ips[h] ~ /^210\.78\./ || ips[h] ~ /^218\.105\./) return "9929"
        if (asns[h] == "4837" || asns[h] == "4808" || is_unicom_access_asn(asns[h]) || ips[h] ~ /^219\.158\./ || ips[h] ~ /^2408:/) has_4837 = 1
      }
      if (has_4837) return "4837"
      return ""
    }
    function unicom_route_combo_label(   h, first_unicom, domestic, mobile_transit) {
      for (h = 1; h <= max_hop; h++) {
        if (is_10099_hop(asns[h], ips[h])) {
          first_unicom = h
          domestic = unicom_domestic_label_from_hop(h)
          if (domestic != "") return "10099->" domestic
          return "10099"
        }
        if (is_unicom_route_hop(h)) {
          first_unicom = h
          break
        }
      }
      domestic = unicom_domestic_label_from_hop(first_unicom - 1)
      mobile_transit = mobile_label_before(first_unicom)
      if (target_isp == "联通" && domestic != "" && mobile_transit != "") return compact_combo_label(mobile_transit "->" domestic)
      if (target_isp == "联通" && domestic != "" && has_163_before(first_unicom)) return "163->" domestic
      return domestic
    }
    function has_unicom_downstream(first,   h) {
      if (first <= 0) return 0
      for (h = first + 1; h <= max_hop; h++) {
        if (is_unicom_route_hop(h)) return 1
      }
      return 0
    }
    function has_10099_entry_to_unicom(   h) {
      for (h = 1; h <= max_hop; h++) {
        if (is_10099_hop(asns[h], ips[h]) && has_unicom_downstream(h)) return 1
      }
      return 0
    }
    function has_163_after(first,   h) {
      if (first <= 0) return 0
      for (h = first + 1; h <= max_hop; h++) {
        if (asns[h] == "4134" || is_163_ip(ips[h])) return 1
      }
      return 0
    }
    function has_cn2_to_163(first,   h, n) {
      if (first <= 0) return 0
      for (h = first; h <= max_hop; h++) {
        if (ips[h] !~ /^59\.43\.245\./) continue
        for (n = h + 1; n <= max_hop; n++) {
          if (ips[n] ~ /^59\.43\./) continue
          return asns[n] == "4134" || asns[n] == "4847" || is_163_ip(ips[n]) || (target_isp == "电信" && (is_telecom_access_asn(asns[n]) || is_telecom_access_ip(ips[n])))
        }
      }
      return 0
    }
    function is_mainland_backbone_hop(asn, ip) {
      if (is_10099_hop(asn, ip)) return 1
      if (asn == "9929" || asn == "4837" || asn == "4808") return 1
      if (asn == "4809") return !is_oversea_cn2_ip(ip)
      if (asn == "4134" || asn == "4847") return 1
      if (is_163_ip(ip)) return 1
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return 1
      if (asn == "23764" || is_ctgnet_ip(ip)) return !is_ctgnet_transit_ip(ip)
      if (asn == "58807" || asn == "58453" || asn == "9808") return 1
      if (asn ~ /^5604[0-8]$/) return 1
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return 1
      if (asn == "23911" || asn == "23910" || asn == "4538" || asn == "7497") return 1
      if (is_163_ip(ip)) return 1
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return 1
      return 0
    }
    function label_from_mainland_hop(hop, asn, ip,   h) {
      if (is_10099_hop(asn, ip)) return "10099"
      if (asn == "9929") return "9929"
      if (asn == "4837" || asn == "4808") return "4837"
      if (asn == "4134" || asn == "4847" || is_163_ip(ip)) return "163"
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return "163"
      if (asn == "23764" || is_ctgnet_ip(ip)) return ""
      if (asn == "4809") {
        if (has_cn2_to_163(hop)) return "CN2GT"
        for (h = hop; h <= max_hop; h++) {
          if (asns[h] == "23764" || is_ctgnet_ip(ips[h])) return "CTGGIA"
        }
        return "CN2GIA"
      }
      if (asn == "58807") return "CMIN2"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return "CMI"
      if (asn == "23911" || asn == "23910") return "CERNET2"
      if (asn == "4538") return "CERNET"
      if (asn == "7497") return "CSTNET"
      return ""
    }
    function is_local_probe_asn(asn) {
      return asn == "" || asn == "749"
    }
    function is_target_isp_hop(asn, ip) {
      if (target_isp == "电信") return is_163_ip(ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(ip)
      if (target_isp == "联通") return is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(ip) || is_unicom_access_asn(asn)
      if (target_isp == "移动") return asn == "58807" || asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(ip)
      return 0
    }
    function visible_hops_match_target_isp(   h) {
      if (max_hop <= 0) return 0
      for (h = 1; h <= max_hop; h++) {
        if (is_local_probe_asn(asns[h])) continue
        if (is_target_isp_hop(asns[h], ips[h])) continue
        return 0
      }
      return 1
    }
    function label_from_target_ip(   asn) {
      if (dest_ip == "" || !visible_hops_match_target_isp()) return ""
      asn = asn_by_ip[dest_ip]
      if (asn == "") asn = infer_asn_from_ip(dest_ip)
      if (target_isp == "电信" && (is_163_ip(dest_ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(dest_ip))) return "163"
      if (target_isp == "联通" && (is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(dest_ip) || is_unicom_access_asn(asn))) return unicom_route_combo_label()
      if (target_isp == "移动" && asn == "58807") return "CMIN2"
      if (target_isp == "移动" && (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(dest_ip))) return "CMI"
      return ""
    }
    function classify(   hop, label, first_cn2, has_ctgnet, has_cn2, has_v6) {
      for (hop = 1; hop <= max_hop; hop++) {
        if (ips[hop] ~ /:/) has_v6 = 1
        if (asns[hop] == "23764" || is_ctgnet_ip(ips[hop])) has_ctgnet = 1
        if (ips[hop] ~ /^59\.43\./) {
          has_cn2 = 1
          if (first_cn2 == 0) first_cn2 = hop
        }
      }
      if (has_cn2) {
        if (has_cn2_to_163(first_cn2)) return "CN2GT"
        if (has_ctgnet) return "CTGGIA"
        return "CN2GIA"
      }
      label = unicom_route_combo_label()
      if (label != "") return label
      if (has_asn("58807")) return "CMIN2"
      for (hop = 1; hop <= max_hop; hop++) {
        if (!is_mainland_backbone_hop(asns[hop], ips[hop])) continue
        label = label_from_mainland_hop(hop, asns[hop], ips[hop])
        if (label != "") return label
      }
      if (has_asn("23911")) return "CERNET2"
      if (has_asn("9929")) return "9929"
      if (has_asn("4837") || has_asn("4808")) return "4837"
      if (has_asn("4847")) return "163"
      if (has_asn("58453") || has_asn("9808") || has_asn("56040") || has_asn("56041") || has_asn("56042") || has_asn("56044") || has_asn("56045") || has_asn("56046") || has_asn("56047") || has_asn("56048")) return "CMI"
      if (has_ctgnet || has_asn("23764")) return "CTGGIA"
      if (has_asn("23910")) return "CERNET2"
      if (has_asn("4538")) return "CERNET"
      if (has_asn("7497")) return "CSTNET"
      label = label_from_target_ip()
      if (label != "") return label
      return "Hidden"
    }
    FILENAME == ARGV[1] {
      asn_by_ip[$1] = $2
      next
    }
    FILENAME == ARGV[2] {
      ip = $0
      if (seen_ip[ip]++) next
      asn = asn_by_ip[ip]
      if (asn == "") asn = infer_asn_from_ip(ip)
      max_hop++
      ips[max_hop] = ip
      asns[max_hop] = asn
      add_asn(asn)
      next
    }
    /^#/ {
      if (NF >= 6) dest_ip = $6
      next
    }
    /^target[[:space:]]/ {
      if (split($0, target_fields, /[[:space:]]+/) >= 2) dest_ip = target_fields[2]
      next
    }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      while (match($0, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
        if (seen_ip[ip]++) continue
        asn = asn_by_ip[ip]
        if (asn == "") asn = infer_asn_from_ip(ip)
        max_hop++
        ips[max_hop] = ip
        asns[max_hop] = asn
        add_asn(asn)
      }
    }
    END { print classify() }
  ' "$asn_map_file" "$trace_ip_file" "$trace_file"
}

education_route_label_from_ip_trace() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3" family="$4"
  local fallback label
  fallback=$(route_label_from_ip_trace "$trace_file" "$asn_map_file" "$trace_ip_file" "教育网")
  label=$(awk -F'|' -v family="$family" '
    function infer_education_asn(ip) {
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.6\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      return ""
    }
    function infer_route_asn(ip,   asn) {
      asn = infer_education_asn(ip)
      if (asn != "") return asn
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.(178|179)\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/)) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./ || ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2401:3cc0:/) return "7578"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/) return "9929"
      return ""
    }
    function is_education_asn(asn, owner, lower_owner) {
      lower_owner = tolower(owner)
      return asn == "4538" || asn == "23910" || asn == "23911" || asn == "24350" || lower_owner ~ /cernet/
    }
    function is_education_hop(asn, owner, ip) {
      return is_education_asn(asn, owner) || infer_education_asn(ip) != ""
    }
    function is_hkix_ip(ip) {
      return ip ~ /^123\.255\.(8[8-9]|9[0-5])\./ || ip ~ /^2001:7fa:/
    }
    function is_he_exchange_ip(ip) {
      return ip == "2001:504:13::210:122"
    }
    function is_ctggia_ip(ip) {
      return ip ~ /^59\.43\./
    }
    function is_ctggia_hop(asn, owner, ip, lower_owner) {
      lower_owner = tolower(owner)
      return asn == "23764" || is_ctggia_ip(ip) || lower_owner ~ /china telecom global|ctgnet|ctg[- ]/
    }
    function compact_owner(owner,   value, words, count, i, result, candidate) {
      value = owner
      sub(/[[:space:]]+-[[:space:]].*$/, "", value)
      gsub(/,/, "", value)
      gsub(/[[:space:]]+(Limited|Ltd\.?|Inc\.?|LLC|Corporation|Corp\.?|Company|Co\.?)$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (length(value) <= 9) return value
      count = split(value, words, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        candidate = result (result == "" ? "" : " ") words[i]
        if (length(candidate) > 9) break
        result = candidate
      }
      return result != "" ? result : substr(value, 1, 9)
    }
    function is_generic_owner_label(label, lower_label) {
      lower_label = tolower(label)
      return lower_label == "global" || lower_label == "network" || lower_label == "networks" || lower_label == "internet" || lower_label == "communications" || lower_label == "telecom"
    }
    function transit_label(asn, owner, ip,   lower_owner, label) {
      if (is_hkix_ip(ip)) return "HKIX"
      if (is_he_exchange_ip(ip)) return "HE"
      if (is_ctggia_hop(asn, owner, ip)) return "CTGGIA"
      if (asn == "4134") return "163"
      if (asn == "4837") return "4837"
      if (asn == "58807") return "CMIN2"
      if (asn == "10099") return "10099"
      if (asn == "9929") return "9929"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (asn == "7578" || asn == "137409") return "GSL"
      lower_owner = tolower(owner)
      if (lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (lower_owner ~ /china169[- ]backbone/) return "4837"
      if (lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (lower_owner ~ /china mobile international|cmi-int/) return "CMI"
      if (lower_owner ~ /global secure layer/) return "GSL"
      if (asn == "6939" || lower_owner ~ /hurricane electric/) return "HE"
      if (lower_owner ~ /ntt/) return "NTT"
      if (lower_owner ~ /arelion|twelve99|telia carrier/) return "Arelion"
      if (lower_owner ~ /cogent/) return "Cogent"
      if (lower_owner ~ /tata communications/) return "Tata"
      label = compact_owner(owner)
      if (is_generic_owner_label(label)) return asn != "" ? "AS" asn : ""
      return label != "" ? label : (asn != "" ? "AS" asn : "")
    }
    function domestic_label(asn, owner, ip,   lower_owner) {
      lower_owner = tolower(owner)
      if (asn == "4134" || ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/ || lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (asn == "9929" || ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/ || lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (asn == "4837" || ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/) || lower_owner ~ /china169[- ]backbone/) return "4837"
      return ""
    }
    function is_international_label(label) {
      return label == "CTGGIA" || label == "10099" || label == "CMI" || label == "CMIN2" || label == "HE" || label == "GSL" || label == "NTT" || label == "Arelion" || label == "Cogent" || label == "Tata"
    }
    FILENAME == ARGV[1] {
      asn_by_ip[tolower($1)] = $2
      owner_by_ip[tolower($1)] = $3
      next
    }
    FILENAME == ARGV[2] {
      ip = tolower($0)
      if (seen[ip]++) next
      hop++
      ips[hop] = ip
      asns[hop] = asn_by_ip[ip]
      owners[hop] = owner_by_ip[ip]
      if (asns[hop] == "") asns[hop] = infer_route_asn(ip)
      next
    }
    END {
      first_education = 0
      for (h = 1; h <= hop; h++) {
        if (is_education_hop(asns[h], owners[h], ips[h])) {
          first_education = h
          break
        }
      }
      if (first_education == 0) exit
      for (h = 1; h < first_education; h++) {
        if (is_hkix_ip(ips[h]) && first_hkix == 0) first_hkix = h
        candidate = transit_label(asns[h], owners[h], ips[h])
        if (is_international_label(candidate)) {
          if (first_international == "") first_international = candidate
          if (candidate == "CMIN2") {
            seen_cmin2 = 1
            international = candidate
          } else if (candidate == "CMI" && seen_cmin2) {
            international = "CMIN2->CMI"
          } else {
            international = candidate
          }
          last_international = h
        }
      }
      if (first_hkix > 0) {
        for (h = first_hkix - 1; h >= 1; h--) {
          candidate = transit_label(asns[h], owners[h], ips[h])
          if (candidate == "" || candidate == "HKIX" || candidate == "163" || candidate == "4837" || candidate == "9929") continue
          if (is_international_label(candidate)) {
            upstream = candidate
            break
          }
          if (fallback_upstream == "") fallback_upstream = candidate
        }
        if (upstream == "") upstream = fallback_upstream
        print (upstream != "" ? upstream "->HKIX" : "HKIX")
        exit
      }
      if (last_international > 0) {
        for (h = last_international + 1; h < first_education; h++) {
          domestic = domestic_label(asns[h], owners[h], ips[h])
          if (domestic != "") {
            first_domestic = domestic
            break
          }
        }
        if (first_domestic != "") {
          print (international !~ /->/ ? international "->" first_domestic : international)
        } else if (international ~ /->/) {
          print international
        } else if (first_international != "" && first_international != international) {
          print first_international "->" international
        } else {
          print international
        }
        exit
      }
      for (h = first_education - 1; h >= 1; h--) {
        if (is_education_hop(asns[h], owners[h], ips[h])) continue
        transit = transit_label(asns[h], owners[h], ips[h])
        if (transit != "") break
      }
      if (transit == "") transit = "Hidden"
      print transit
    }
  ' "$asn_map_file" "$trace_ip_file")
  printf '%s' "${label:-$fallback}"
}

route_trace_one() {
  local family="$1" protocol="$2" prov="$3" isp="$4" host="$5" idx="$6" port="${7:-80}" fixed_ip="${8:-}" prefix="${9:-route}"
  local packet_length="${10:-44}"
  local outfile="${RESULT_DIR}/${prefix}_${idx}" trace_file="${RESULT_DIR}/${prefix}_trace_${idx}"
  local probe_arg="-T"
  [ "$protocol" = "udp" ] && probe_arg="-U"
  local -a args
  local output rc target_ip target retry_output retry_rc

  target_ip="$fixed_ip"
  if [ -z "$target_ip" ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|NO_NODE_IP" > "$outfile"
    return
  fi
  target="$target_ip"
  if [ "$protocol" = "nexttrace" ]; then
    if [ "$family" != "4" ]; then
      echo "FAIL|$prov|$isp|$protocol|$host|UNSUPPORTED_FAMILY" > "$outfile"
      return
    fi
    args=(-4 -T -p "$port" --psize "$packet_length" -M -d disable-geoip -n -q 3 -m 30 "$target")
    if output=$(nexttrace-tiny "${args[@]}" 2>&1); then
      rc=0
    else
      rc=$?
    fi
  else
    args=(-n "-${family}" "$probe_arg" -p "$port" -q 3 -w 2 -m 30 "$target" "$packet_length")
    if output=$(traceroute "${args[@]}" 2>&1); then
      rc=0
    else
      rc=$?
    fi
  fi
  {
    printf "# %s|%s|%s|%s|%s|%s\n" "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
    [ -n "$target_ip" ] && printf "target %s\n" "$target_ip"
    printf "%s\n" "$output"
  } > "$trace_file"
  if [ "$protocol" = "nexttrace" ] && [ "$rc" -ne 0 ] &&
     printf "%s\n" "$output" | grep -Eq '(^usage:|bad integer value|unknown arguments)'; then
    echo "FAIL|$prov|$isp|$protocol|$host|NEXTTRACE_ERROR" > "$outfile"
    return
  fi
  if [ "$family" = "4" ] && [ "$protocol" = "tcp" ] && route_needs_10099_hidden_tcp_retry "$trace_file"; then
    if retry_output=$(traceroute "${args[@]}" 2>&1); then
      retry_rc=0
    else
      retry_rc=$?
    fi
    {
      printf "\n# retry 10099 hidden domestic segment|%s|%s|%s|%s|%s|%s\n" "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
      [ -n "$target_ip" ] && printf "target %s\n" "$target_ip"
      printf "%s\n" "$retry_output"
    } >> "$trace_file"
    if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
      printf "%s|%s|%s|%s|%s|%s|%s|retry_10099_hidden\n" "$idx" "$prov" "$isp" "$protocol" "$host" "${target_ip:-DNS_FAIL}" "$retry_rc" >> "${RESULT_DIR}/route_debug_meta.txt"
    fi
  fi
  if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    printf "%s|%s|%s|%s|%s|%s|%s\n" "$idx" "$prov" "$isp" "$protocol" "$host" "${target_ip:-DNS_FAIL}" "$rc" >> "${RESULT_DIR}/route_debug_meta.txt"
  fi
  if extract_trace_ips "$trace_file" | grep -q .; then
    echo "TRACE|$prov|$isp|$protocol|$host|$idx" > "$outfile"
    return
  fi
  if [[ "$output" == *"Operation not permitted"* || "$output" == *"operation not permitted"* ]]; then
    echo "FAIL|$prov|$isp|$protocol|$host|PERMISSION" > "$outfile"
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|TRACE_ERROR" > "$outfile"
  else
    echo "FAIL|$prov|$isp|$protocol|$host|NO_HOPS" > "$outfile"
  fi
}

show_route_results() {
  local file="$1"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
    function color(status, label) {
      if (status == "LIMIT") return yellow
      if (status != "OK") return red
      if (label == "Hidden" || label == "NoData") return yellow
      return green
    }
    function cell(status, label,   c) {
      c = color(status, label)
      return c sprintf("%-11s", label) nc
    }
    {
      status = $1
      prov = $2
      isp = $3
      proto = toupper($4)
      label = $6
      if (status == "LIMIT") label = "LIMIT"
      if (status == "FAIL") label = "failed"
      if (!(proto in proto_seen)) {
        proto_seen[proto] = 1
        proto_order[++pn] = proto
      }
      if (!(prov in seen)) {
        seen[prov] = 1
        order[++n] = prov
      }
      result[proto SUBSEP prov SUBSEP isp] = cell(status, label)
      if (status == "LIMIT") limit_count++
    }
    END {
      for (p = 1; p <= pn; p++) {
        proto = proto_order[p]
        printf "  %s%s%s 回程线路%s %s(-- 电信 -- | -- 联通 -- | -- 移动 --)%s\n", bold, cyan, proto, nc, dim, nc
        for (i = 1; i <= n; i++) {
          prov = order[i]
          prov_pad = (prov == "黑龙江" || prov == "内蒙古") ? "  " : "    "
          printf "  %s%s%s%s  %s  %s  %s\n", cyan, prov, nc, prov_pad, result[proto SUBSEP prov SUBSEP "电信"], result[proto SUBSEP prov SUBSEP "联通"], result[proto SUBSEP prov SUBSEP "移动"]
        }
        printf "\n"
      }
      if (limit_count > 0) {
        printf "  %s[!] 检测到 %d 次线路识别受限。%s\n\n", yellow, limit_count, nc
      }
    }
  ' "$file"
}

run_route_mode() {
  local family="${1:-4}" idx=0 entry prov isp host fixed_ip port backup_host backup_ip backup_port protocol route_raw_file route_file ip_file cymru_file asn_map_file prefix
  local route_parallel="$PARALLEL"
  local -a protocols=()
  if [ "$ROUTE_PROTOCOL" = "both" ]; then
    protocols=(tcp udp)
  else
    protocols=("$ROUTE_PROTOCOL")
  fi
  prefix="route${family}"
  ROUTE_ACTIVE_PREFIX="$prefix"

  check_curl
  require_remote_nodes "v${family}"
  check_traceroute
  if [ "$family" = "6" ]; then
    if ! ipv6_available; then
      echo -e "${YELLOW}[!] 未检测到可用 IPv6，已跳过 IPv6 线路识别${NC}"
      return 0
    fi
  elif ! ipv4_available; then
    echo -e "${YELLOW}[!] 未检测到可用 IPv4，已跳过 IPv4 线路识别${NC}"
    return 0
  fi

  if [ "$family" != "4" ] && [ "$family" != "6" ]; then
    echo -e "${RED}[X] 线路识别 family 只支持 4 或 6${NC}"
    exit 1
  fi

  local route_node_count
  route_node_count=$(count_cdn_nodes "$family")
  TOTAL=$((route_node_count * ${#protocols[@]}))
  if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}[X] 指定省份没有可执行的线路检测任务${NC}"
    exit 1
  fi
  echo -e "${CYAN}  IPv${family} 三网回程线路识别${NC}"
  echo -e "${DIM}  检测范围: $(province_filter_text)  线路检测节点: $TOTAL  协议: $ROUTE_PROTOCOL  并行: $route_parallel${NC}"
  echo -e "${YELLOW}  [!] 线路检测使用 traceroute，本地探测完成后批量查询 Team Cymru ASN。${NC}"
  echo ""

  show_progress
  for protocol in "${protocols[@]}"; do
    while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
        show_progress
        sleep 0.2
      done
      port=${port:-80}
      route_trace_one "$family" "$protocol" "$prov" "$isp" "$host" "$idx" "$port" "$fixed_ip" "$prefix" &
      show_progress
    done < <(print_cdn_entries "$family")
  done
  while [ "$(jobs -pr | wc -l | tr -d ' ')" -gt 0 ]; do
    show_progress
    sleep 0.2
  done
  wait
  show_progress
  echo ""

  route_raw_file=$(mktemp)
  route_file=$(mktemp)
  ip_file=$(mktemp)
  cymru_file=$(mktemp)
  asn_map_file=$(mktemp)
  for idx in $(seq 1 "$TOTAL"); do
    [ -f "${RESULT_DIR}/${prefix}_${idx}" ] && cat "${RESULT_DIR}/${prefix}_${idx}" >> "$route_raw_file"
    [ -f "${RESULT_DIR}/${prefix}_trace_${idx}" ] && extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    query_cymru_asn "$ip_file" "$cymru_file"
    build_asn_map "$cymru_file" "$asn_map_file"
  fi

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_raw_file" "${RESULT_DIR}/${prefix}_raw.txt"
    cp "$ip_file" "${RESULT_DIR}/${prefix}_ips.txt"
    cp "$cymru_file" "${RESULT_DIR}/${prefix}_cymru.txt"
    cp "$asn_map_file" "${RESULT_DIR}/${prefix}_asn_map.txt"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = "TRACE" ] && [ -f "${RESULT_DIR}/${prefix}_trace_${value}" ]; then
      trace_ip_file="${RESULT_DIR}/${prefix}_trace_${value}.ips"
      extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${value}" > "$trace_ip_file"
      label=$(route_label_from_ip_trace "${RESULT_DIR}/${prefix}_trace_${value}" "$asn_map_file" "$trace_ip_file" "$isp")
      echo "OK|$prov|$isp|$protocol|$host|$label" >> "$route_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|$protocol|$host|$value" >> "$route_file"
    fi
  done < "$route_raw_file"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_file" "${RESULT_DIR}/${prefix}_final.txt"
  fi

  echo ""
  show_route_results "$route_file"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo -e "  ${DIM}Debug IPv${family}: traces=$(ls "${RESULT_DIR}"/${prefix}_trace_* 2>/dev/null | wc -l | tr -d ' ') ips=$(wc -l < "$ip_file" | tr -d ' ') cymru=$(grep -c '|' "$cymru_file" 2>/dev/null || echo 0) asn_map=$(wc -l < "$asn_map_file" | tr -d ' ')${NC}"
    echo ""
  fi
  rm -f "$route_raw_file" "$route_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

collect_route_labels() {
  local family="$1" out_file="$2" idx=0 entry prov isp host fixed_ip port backup_host backup_ip backup_port route_total route_raw_file ip_file cymru_file asn_map_file trace_ip_file status protocol value label prefix
  prefix="${3:-summary_route${family}}"
  local packet_length="${4:-44}"
  local route_protocol="${5:-tcp}"
  local route_parallel="$PARALLEL"
  route_total=0
  while IFS='|' read -r prov isp host _; do
    province_selected "$prov" && route_total=$((route_total + 1))
  done < <(print_cdn_entries "$family")
  [ "$route_total" -eq 0 ] && return 0

  while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
    province_selected "$prov" || continue
    port=${port:-80}
    idx=$((idx + 1))
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
      sleep 0.2
    done
    route_trace_one "$family" "$route_protocol" "$prov" "$isp" "$host" "$idx" "$port" "$fixed_ip" "$prefix" "$packet_length" &
  done < <(print_cdn_entries "$family")
  wait

  route_raw_file=$(mktemp)
  ip_file=$(mktemp)
  cymru_file=$(mktemp)
  asn_map_file=$(mktemp)
  for idx in $(seq 1 "$route_total"); do
    [ -f "${RESULT_DIR}/${prefix}_${idx}" ] && cat "${RESULT_DIR}/${prefix}_${idx}" >> "$route_raw_file"
    [ -f "${RESULT_DIR}/${prefix}_trace_${idx}" ] && extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    query_cymru_asn "$ip_file" "$cymru_file"
    build_asn_map "$cymru_file" "$asn_map_file"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = "TRACE" ] && [ -f "${RESULT_DIR}/${prefix}_trace_${value}" ]; then
      trace_ip_file="${RESULT_DIR}/${prefix}_trace_${value}.ips"
      extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${value}" > "$trace_ip_file"
      label=$(route_label_from_ip_trace "${RESULT_DIR}/${prefix}_trace_${value}" "$asn_map_file" "$trace_ip_file" "$isp")
      echo "OK|$prov|$isp|$protocol|$host|$label" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|$protocol|$host|${value:-Hidden}" >> "$out_file"
    fi
  done < "$route_raw_file"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_raw_file" "${RESULT_DIR}/route_raw_summary_v${family}.txt"
    cp "$ip_file" "${RESULT_DIR}/route_ips_summary_v${family}.txt"
    cp "$cymru_file" "${RESULT_DIR}/route_cymru_summary_v${family}.txt"
    cp "$asn_map_file" "${RESULT_DIR}/route_asn_map_summary_v${family}.txt"
    cp "$out_file" "${RESULT_DIR}/route_final_summary_v${family}.txt"
  fi

  rm -f "$route_raw_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

collect_education_route_labels() {
  local family="$1" out_file="$2" idx=0 entry prov host fixed_ip port route_total route_raw_file ip_file cymru_file asn_map_file trace_ip_file status protocol value label prefix
  local route_parallel="$PARALLEL"
  prefix="edu_route${family}"
  route_total=0
  if [ "$family" = "6" ]; then
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" && route_total=$((route_total + 1))
    done < <(print_cernet2_entries)
  else
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" && route_total=$((route_total + 1))
    done < <(print_cernet_entries)
  fi
  [ "$route_total" -eq 0 ] && return 0

  if [ "$family" = "6" ]; then
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" || continue
      port=${port:-80}
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
        sleep 0.2
      done
      route_trace_one "$family" tcp "$prov" "教育网" "$host" "$idx" "$port" "$fixed_ip" "$prefix" &
    done < <(print_cernet2_entries)
  else
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" || continue
      port=${port:-80}
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
        sleep 0.2
      done
      route_trace_one "$family" tcp "$prov" "教育网" "$host" "$idx" "$port" "$fixed_ip" "$prefix" &
    done < <(print_cernet_entries)
  fi
  wait

  route_raw_file=$(mktemp)
  ip_file=$(mktemp)
  cymru_file=$(mktemp)
  asn_map_file=$(mktemp)
  for idx in $(seq 1 "$route_total"); do
    [ -f "${RESULT_DIR}/${prefix}_${idx}" ] && cat "${RESULT_DIR}/${prefix}_${idx}" >> "$route_raw_file"
    [ -f "${RESULT_DIR}/${prefix}_trace_${idx}" ] && extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    query_cymru_asn "$ip_file" "$cymru_file"
    build_asn_map "$cymru_file" "$asn_map_file"
    append_server_asn_meta "$ip_file" "$asn_map_file"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = "TRACE" ] && [ -f "${RESULT_DIR}/${prefix}_trace_${value}" ]; then
      trace_ip_file="${RESULT_DIR}/${prefix}_trace_${value}.ips"
      extract_trace_ips "${RESULT_DIR}/${prefix}_trace_${value}" > "$trace_ip_file"
      label=$(education_route_label_from_ip_trace "${RESULT_DIR}/${prefix}_trace_${value}" "$asn_map_file" "$trace_ip_file" "$family")
      echo "OK|$prov|$isp|tcp|$host|$label" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|tcp|$host|${value:-Hidden}" >> "$out_file"
    fi
  done < "$route_raw_file"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_raw_file" "${RESULT_DIR}/edu_route_raw_v${family}.txt"
    cp "$ip_file" "${RESULT_DIR}/edu_route_ips_v${family}.txt"
    cp "$cymru_file" "${RESULT_DIR}/edu_route_cymru_v${family}.txt"
    cp "$asn_map_file" "${RESULT_DIR}/edu_route_asn_map_v${family}.txt"
    cp "$out_file" "${RESULT_DIR}/edu_route_final_v${family}.txt"
  fi

  rm -f "$route_raw_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

set_route_progress_total() {
  local has_v4="$1" has_v6="$2" include_cdn="${3:-1}" include_edu="${4:-0}" include_large="${5:-0}"
  ROUTE_PROGRESS_TOTAL=0
  if [ "$include_cdn" -eq 1 ] && [ "$has_v4" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_selected_cdn_nodes 4)))
  fi
  if [ "$include_large" -eq 1 ] && [ "$has_v4" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_selected_cdn_nodes 4)))
  fi
  if [ "$include_cdn" -eq 1 ] && [ "$has_v6" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_selected_cdn_nodes 6)))
  fi
  if [ "$include_edu" -eq 1 ] && [ "$has_v4" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_cernet_nodes)))
  fi
  if [ "$include_edu" -eq 1 ] && [ "$has_v6" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_cernet2_nodes)))
  fi
  return 0
}

start_route_background() {
  local route_labels_v4="$1" route_labels_v6="$2" has_v4="$3" has_v6="$4" include_cdn="${5:-1}" include_edu="${6:-0}" edu_route_labels_v4="${7:-}" edu_route_labels_v6="${8:-}" large_route_labels_v4="${9:-}" include_large="${10:-0}"
  [ "$ROUTE_PROGRESS_TOTAL" -gt 0 ] || return 0
  (
    if [ "$include_cdn" -eq 1 ] && [ "$has_v4" -eq 1 ]; then
      collect_route_labels 4 "$route_labels_v4"
    fi
    if [ "$include_large" -eq 1 ] && [ "$has_v4" -eq 1 ] && [ -n "$large_route_labels_v4" ]; then
      collect_route_labels 4 "$large_route_labels_v4" "summary_large_route4" 1200 nexttrace
    fi
    if [ "$include_cdn" -eq 1 ] && [ "$has_v6" -eq 1 ]; then
      collect_route_labels 6 "$route_labels_v6"
    fi
    if [ "$include_edu" -eq 1 ] && [ "$has_v4" -eq 1 ] && [ -n "$edu_route_labels_v4" ]; then
      collect_education_route_labels 4 "$edu_route_labels_v4"
    fi
    if [ "$include_edu" -eq 1 ] && [ "$has_v6" -eq 1 ] && [ -n "$edu_route_labels_v6" ]; then
      collect_education_route_labels 6 "$edu_route_labels_v6"
    fi
  ) >"$RESULT_DIR/route.log" 2>&1 &
  ROUTE_BACKGROUND_PID=$!
}

wait_route_background() {
  [ -n "${ROUTE_BACKGROUND_PID:-}" ] || return 0
  while kill -0 "$ROUTE_BACKGROUND_PID" 2>/dev/null; do
    if [ "${MULTI_PROGRESS_MODE:-0}" -eq 1 ]; then
      show_all_progress
    fi
    sleep 0.2
  done
  wait "$ROUTE_BACKGROUND_PID" 2>/dev/null || true
}

export -f route_trace_one
export -f extract_trace_ips
export -f route_needs_10099_hidden_tcp_retry

nping_random_source_port() {
  printf "%s\n" $((20000 + RANDOM % 40000))
}

nping_random_seq() {
  printf "%s\n" $((((RANDOM << 16) ^ RANDOM) & 0x7ffffffe))
}

export -f nping_random_source_port
export -f nping_random_seq

nping_matching_min_rtt() {
  local raw="$1"
  printf "%s\n" "$raw" | awk '
    function ep_ip(ep) {
      sub(/:[0-9]+$/, "", ep)
      return tolower(ep)
    }
    function ep_port(ep) {
      if (match(ep, /:[0-9]+$/)) {
        return substr(ep, RSTART + 1)
      }
      return ""
    }
    function parse_tcp_line(line, prefix, time_s, body, parts, left, right) {
      time_s = line
      sub(/^[^(]*\(/, "", time_s)
      sub(/s\).*/, "", time_s)
      body = line
      sub(/^.* TCP /, "", body)
      split(body, parts, " > ")
      if (!parts[1] || !parts[2]) return 0
      left = parts[1]
      right = parts[2]
      sub(/ .*/, "", right)
      if (!ep_port(left) || !ep_port(right)) return 0
      if (prefix == "sent") {
        sent_time = time_s + 0
        sent_src_ip = ep_ip(left)
        sent_src_port = ep_port(left)
        sent_dst_ip = ep_ip(right)
        sent_dst_port = ep_port(right)
        have_sent = 1
      } else {
        rcvd_time = time_s + 0
        rcvd_src_ip = ep_ip(left)
        rcvd_src_port = ep_port(left)
        rcvd_dst_ip = ep_ip(right)
        rcvd_dst_port = ep_port(right)
      }
      return 1
    }
    /^SENT .* TCP / && !have_sent {
      parse_tcp_line($0, "sent")
    }
    /^RCVD .* TCP / && have_sent {
      if (parse_tcp_line($0, "rcvd") &&
          rcvd_src_ip == sent_dst_ip &&
          rcvd_src_port == sent_dst_port &&
          rcvd_dst_ip == sent_src_ip &&
          rcvd_dst_port == sent_src_port) {
        rtt_ms = (rcvd_time - sent_time) * 1000
        if (!found || rtt_ms < min_rtt) min_rtt = rtt_ms
        found = 1
      }
    }
    END {
      if (found) {
        printf "%.3f\n", min_rtt
      } else {
        exit 1
      }
    }
  '
}

export -f nping_matching_min_rtt

# ===================== 单节点测试 =====================
probe_target() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" ip="$6" port="${7:-80}" idx="${8:-0}" label="${9:-main}"
  if [ "$family" = "4" ] && [ -n "$ip" ] && ! is_public_ipv4 "$ip"; then
    ip=""
  fi
  if [ -z "$ip" ]; then
    echo "FAIL|$prov|$isp|$host|GETNODES|0|0|100.00|0"
    return
  fi

  local raw nping_rc iface source_ip source_mac dest_mac route_data
  # 不使用 --privileged：macOS 下该选项会强制二层发包，容易因无法解析下一跳 MAC 而失败。
  local -a nping_base_args=(--tcp -p "$port" --flags syn)
  local -a nping_l2_args=()
  local nping_l2_ready=0 nping_l2_failed=0 nping_use_l2=0
  if [ "$family" = "6" ]; then
    nping_base_args=(-6 "${nping_base_args[@]}")
  fi

  local sent=0 rcvd=0 loss_pct avg_rtt rtt_sum="0" one_sent one_rcvd one_rtt one_success i packet_size payload_size header_size
  local source_port tcp_seq
  local large_packet_mode="${LARGE_PACKET_MODE:-0}" large_big_target=0 large_big_used=0 large_small_used=0 remaining big_remaining small_remaining
  header_size=40
  [ "$family" = "6" ] && header_size=60
  if [ "$large_packet_mode" -eq 1 ]; then
    large_big_target=$(((PACKETS * 3 + 3) / 4))
  fi
  if [ "$family" = "6" ] && [ "${IPV6_NPING_FORCE_L2:-0}" -eq 1 ]; then
    if route_data=$(get_ipv6_route "$ip"); then
      IFS='|' read -r iface source_ip source_mac dest_mac <<< "$route_data"
      nping_l2_args=(-6 -e "$iface" -S "$source_ip" --source-mac "$source_mac" --dest-mac "$dest_mac" --tcp -p "$port" --flags syn)
      nping_l2_ready=1
      nping_use_l2=1
    else
      nping_l2_failed=1
    fi
  fi
  for ((i = 1; i <= PACKETS; i++)); do
    if [ "$group" = "cdn4" ] || [ "$group" = "cdn6" ] ||
       [ "$group" = "cernet" ] || [ "$group" = "cernet2" ]; then
      packet_size="$header_size"
    elif [ -n "$PACKET_SIZE_OVERRIDE" ]; then
      packet_size="$PACKET_SIZE_OVERRIDE"
    elif [ "$large_packet_mode" -eq 1 ]; then
      remaining=$((PACKETS - i + 1))
      big_remaining=$((large_big_target - large_big_used))
      small_remaining=$((PACKETS - large_big_target - large_small_used))
      if [ "$big_remaining" -ge "$remaining" ] || [ "$small_remaining" -le 0 ] || [ $((RANDOM % remaining)) -lt "$big_remaining" ]; then
        packet_size="${LARGE_PACKET_BIG_SIZES[$((RANDOM % ${#LARGE_PACKET_BIG_SIZES[@]}))]}"
        large_big_used=$((large_big_used + 1))
      else
        packet_size="${LARGE_PACKET_SMALL_SIZES[$((RANDOM % ${#LARGE_PACKET_SMALL_SIZES[@]}))]}"
        large_small_used=$((large_small_used + 1))
      fi
    else
      packet_size="${PACKET_SIZES[$((RANDOM % ${#PACKET_SIZES[@]}))]}"
    fi
    payload_size=0
    [ "$packet_size" -gt 0 ] && payload_size=$((packet_size - header_size))
    [ "$payload_size" -lt 0 ] && payload_size=0
    local -a current_nping_args=("${nping_base_args[@]}")
    [ "$nping_use_l2" -eq 1 ] && current_nping_args=("${nping_l2_args[@]}")
    source_port=$(nping_random_source_port)
    tcp_seq=$(nping_random_seq)
    current_nping_args+=(-g "$source_port" --seq "$tcp_seq")
    if [ "$packet_size" -eq 0 ]; then
      if raw=$(nping "${current_nping_args[@]}" -c 1 "$ip" 2>&1); then
        nping_rc=0
      else
        nping_rc=$?
      fi
    elif raw=$(nping "${current_nping_args[@]}" --data-length "$payload_size" -c 1 "$ip" 2>&1); then
      nping_rc=0
    else
      nping_rc=$?
    fi

    one_sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    if [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ] && one_rtt=$(nping_matching_min_rtt "$raw"); then
      one_rcvd=1
    elif [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ]; then
      if [ "$DEBUG_MODE" -eq 1 ]; then
        printf "%s\n" "$raw" > "${RESULT_DIR}/nping_mismatch_${group}_${idx}_${label}_${i}.log"
      fi
      one_rcvd=0
      one_rtt=""
    fi

    if { ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || ! [[ "$one_rcvd" =~ ^[0-9]+$ ]] || [ "$one_rcvd" -eq 0 ]; } &&
       [ "$family" = "6" ] && [ "$nping_use_l2" -eq 0 ] && [ "$nping_l2_failed" -eq 0 ]; then
      if [ "$nping_l2_ready" -eq 0 ]; then
        if route_data=$(get_ipv6_route "$ip"); then
          IFS='|' read -r iface source_ip source_mac dest_mac <<< "$route_data"
          nping_l2_args=(-6 -e "$iface" -S "$source_ip" --source-mac "$source_mac" --dest-mac "$dest_mac" --tcp -p "$port" --flags syn)
          nping_l2_ready=1
        else
          nping_l2_failed=1
        fi
      fi
      if [ "$nping_l2_ready" -eq 1 ]; then
        nping_use_l2=1
        source_port=$(nping_random_source_port)
        tcp_seq=$(nping_random_seq)
        local -a current_l2_nping_args=("${nping_l2_args[@]}" -g "$source_port" --seq "$tcp_seq")
        if [ "$packet_size" -eq 0 ]; then
          if raw=$(nping "${current_l2_nping_args[@]}" -c 1 "$ip" 2>&1); then
            nping_rc=0
          else
            nping_rc=$?
          fi
        elif raw=$(nping "${current_l2_nping_args[@]}" --data-length "$payload_size" -c 1 "$ip" 2>&1); then
          nping_rc=0
        else
          nping_rc=$?
        fi
        one_sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
        one_rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
        if [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ] && one_rtt=$(nping_matching_min_rtt "$raw"); then
          one_rcvd=1
        elif [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ]; then
          if [ "$DEBUG_MODE" -eq 1 ]; then
            printf "%s\n" "$raw" > "${RESULT_DIR}/nping_mismatch_${group}_${idx}_${label}_${i}.log"
          fi
          one_rcvd=0
          one_rtt=""
        fi
      fi
    fi

    if ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || ! [[ "$one_rcvd" =~ ^[0-9]+$ ]]; then
      if [ "$DEBUG_MODE" -eq 1 ]; then
        printf "%s\n" "$raw" > "${RESULT_DIR}/nping_error_${group}_${idx}_${label}_${i}.log"
        printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$group" "$idx" "$label" "$i" "$prov" "$isp" "$host" "$ip" >> "${RESULT_DIR}/nping_error_meta.txt"
      fi
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
      return
    fi

    sent=$((sent + one_sent))
    one_success=0
    if [ "$one_rcvd" -gt 0 ]; then
      if ! [[ "$one_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [ "$DEBUG_MODE" -eq 1 ]; then
          printf "%s\n" "$raw" > "${RESULT_DIR}/nping_error_${group}_${idx}_${label}_${i}.log"
        fi
        echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
        return
      fi
      one_success=1
      if [ "$DEBUG_MODE" -eq 1 ]; then
        printf "%s\n" "$raw" > "${RESULT_DIR}/nping_success_${group}_${idx}_${label}_${i}.log"
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
          "$group" "$idx" "$label" "$i" "$prov" "$isp" "$host" "$ip" "$one_sent" "$one_rcvd" "$one_rtt" \
          >> "${RESULT_DIR}/nping_success_meta.txt"
      fi
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
  echo "OK|$prov|$isp|$host|$ip|$sent|$rcvd|$loss_pct|$avg_rtt"
}

combine_probe_results() {
  local primary="$1" backup="$2"
  local ps pp pi ph pip psent prcv ploss plat bs bp bi bh bip bsent brcv bloss blat
  IFS='|' read -r ps pp pi ph pip psent prcv ploss plat <<< "$primary"
  IFS='|' read -r bs bp bi bh bip bsent brcv bloss blat <<< "$backup"
  if [ "$ps" != "OK" ] || [ "$bs" != "OK" ]; then
    echo "$backup"
    return
  fi
  local sent=$((psent + bsent)) rcv=$((prcv + brcv)) loss lat
  loss=$(awk -v a="$ploss" -v b="$bloss" 'BEGIN { printf "%.2f", (a + b) / 2 }')
  lat=$(awk -v a="$plat" -v b="$blat" 'BEGIN { if (a > 0 && b > 0) printf "%.3f", (a + b) / 2; else if (a > 0) printf "%.3f", a; else printf "%.3f", b }')
  echo "OK|$pp|$pi|$ph|$pip|$sent|$rcv|$loss|$lat"
}

test_one() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" idx="$6"
  local fixed_ip="${7:-}" port="${8:-80}" backup_host="${9:-}" backup_ip="${10:-}" backup_port="${11:-80}"
  local outfile="${RESULT_DIR}/${group}_${idx}" primary_result backup_result p_status p_loss b_status b_loss
  primary_result=$(probe_target "$group" "$family" "$prov" "$isp" "$host" "$fixed_ip" "$port" "$idx" main)
  IFS='|' read -r p_status _ _ _ _ _ _ p_loss _ <<< "$primary_result"

  if [ -n "$backup_ip" ] &&
     { [ "$p_status" != "OK" ] || awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 > 15) }'; }; then
    backup_result=$(probe_target "$group" "$family" "$prov" "$isp" "$backup_host" "$backup_ip" "$backup_port" "$idx" backup)
    IFS='|' read -r b_status _ _ _ _ _ _ b_loss _ <<< "$backup_result"
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$group" "$idx" "$prov" "$isp" "$p_loss" "$backup_host" "$backup_ip" "$backup_result" >> "${RESULT_DIR}/backup_retry_meta.txt"
    fi
    if [ "$p_status" != "OK" ] || awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 >= 100) }'; then
      printf "%s\n" "$backup_result" > "$outfile"
      return
    fi
    if [ "$b_status" = "OK" ]; then
      if awk -v loss="$b_loss" 'BEGIN { exit !(loss + 0 > 0) }'; then
        combine_probe_results "$primary_result" "$backup_result" > "$outfile"
      else
        printf "%s\n" "$backup_result" > "$outfile"
      fi
      return
    fi
  fi
  printf "%s\n" "$primary_result" > "$outfile"
}

large_packet_precheck() {
  local ip result status _prov _isp _host _ip sent rcv loss lat
  ip=$(resolve_first_public_ipv4 "$LARGE_PACKET_PRECHECK_DOMAIN" || true)
  if [ -z "$ip" ]; then
    LARGE_PACKET_FIREWALL_LIMITED=1
    LARGE_PACKET_PRECHECK_LOSS="100.00"
    return 1
  fi

  local PACKETS="$LARGE_PACKET_PRECHECK_PACKETS"
  local PACKET_SIZE_OVERRIDE="$LARGE_PACKET_PRECHECK_SIZE"
  result=$(probe_target "largepre" 4 "Cloudflare" "预检" "$LARGE_PACKET_PRECHECK_DOMAIN" "$ip" 443 0 precheck)
  IFS='|' read -r status _prov _isp _host _ip sent rcv loss lat <<< "$result"
  LARGE_PACKET_PRECHECK_LOSS="${loss:-100.00}"
  if [ "$status" != "OK" ] || awk -v loss="${loss:-100}" 'BEGIN { exit !(loss + 0 >= 80) }'; then
    LARGE_PACKET_FIREWALL_LIMITED=1
    return 1
  fi
  LARGE_PACKET_FIREWALL_LIMITED=0
  return 0
}

ipv6_nping_precheck() {
  local ip raw sent rcv source_port tcp_seq
  IPV6_NPING_FORCE_L2=0
  ip=$(resolve_first_public_ipv6 "$LARGE_PACKET_PRECHECK_DOMAIN" || true)
  [ -n "$ip" ] || return 0

  source_port=$(nping_random_source_port)
  tcp_seq=$(nping_random_seq)
  raw=$(nping -6 --tcp -p 443 -g "$source_port" --seq "$tcp_seq" --flags syn -c "$IPV6_NPING_PRECHECK_PACKETS" "$ip" 2>&1 || true)
  sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  rcv=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -gt 0 ] && ! nping_matching_min_rtt "$raw" >/dev/null; then
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf "%s\n" "$raw" > "${RESULT_DIR}/nping_mismatch_ipv6_precheck.log"
    fi
    rcv=0
  fi
  if [[ "$sent" =~ ^[0-9]+$ ]] && [ "$sent" -gt 0 ] &&
     [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -eq 0 ]; then
    IPV6_NPING_FORCE_L2=1
  fi
}

test_large_one() {
  local PACKET_SIZE_OVERRIDE=""
  local LARGE_PACKET_MODE=1
  test_one "$@"
}

write_large_skip_result() {
  local prov="$1" isp="$2" host="$3" fixed_ip="$4" idx="$5"
  printf 'SKIP|%s|%s|%s|%s|0|0|-|-\n' "$prov" "$isp" "$host" "${fixed_ip:-FIREWALL_LIMITED}" > "${RESULT_DIR}/large4_${idx}"
}

export -f probe_target
export -f combine_probe_results
export -f test_one
export -f test_large_one
export -f get_ipv6_route
export -f is_public_ipv4
export RESULT_DIR PACKETS PACKET_SIZES PACKET_SIZE_OVERRIDE LARGE_PACKET_SIZES IPV6_NPING_FORCE_L2

# ===================== 国际互联 TCP ping =====================
international_task_count() {
  printf '%s' "$((${#INTERNATIONAL_SITE_TARGETS[@]} + ${#INTERNATIONAL_CDN_TARGETS[@]}))"
}

international_latency_families() {
  if [ "$ONLY_IPV4" -eq 1 ] && [ "$ONLY_IPV6" -eq 0 ]; then
    printf '4\n'
  elif [ "$ONLY_IPV6" -eq 1 ] && [ "$ONLY_IPV4" -eq 0 ]; then
    printf '6\n'
  else
    printf '4\n6\n'
  fi
}

international_latency_family_count() {
  if [ "$ONLY_IPV4" -eq 1 ] && [ "$ONLY_IPV6" -eq 0 ]; then
    printf '1'
  elif [ "$ONLY_IPV6" -eq 1 ] && [ "$ONLY_IPV4" -eq 0 ]; then
    printf '1'
  else
    printf '2'
  fi
}

international_latency_direction_count() {
  printf '2'
}

international_latency_task_count() {
  printf '%s' "$((${#INTERNATIONAL_IPERF_TARGETS[@]} * $(international_latency_family_count) * $(international_latency_direction_count)))"
}

international_total_task_count() {
  printf '%s' "$(($(international_task_count) + $(international_latency_task_count)))"
}

tcp_info_rtt_ms() {
  local ip="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  ss -tinp 2>/dev/null | awk -v ip="$ip" -v port="$port" '
    function is_remote(line) {
      return index(line, ip ":" port) || index(line, "[" ip "]:" port)
    }
    is_remote($0) {
      matched = 1
      next
    }
    matched && $0 ~ /^[[:space:]]/ && $0 ~ /rtt:/ {
      start = index($0, " rtt:")
      if (start == 0) next
      value = substr($0, start + 5)
      sub(/\/.*$/, "", value)
      if (value ~ /^[0-9]+([.][0-9]+)?$/) {
        last = value
        if ($0 ~ /bytes_received:[1-9][0-9][0-9]+/) {
          print value
          found = 1
          exit
        }
      }
      next
    }
    matched && $0 !~ /^[[:space:]]/ {
      matched = 0
    }
    END {
      if (!found && last != "") print last
    }
  '
}

emit_public_ipv4s() {
  local answers="$1" ip found=0
  while read -r ip; do
    [ -n "$ip" ] || continue
    if is_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      found=1
    fi
  done <<< "$answers"
  [ "$found" -eq 1 ]
}

resolve_public_ipv4s() {
  local domain="$1" answers=""
  if command -v getent >/dev/null 2>&1; then
    answers=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | awk '!seen[$1]++' || true)
    if [ -n "$answers" ] && emit_public_ipv4s "$answers"; then
      return 0
    fi
    answers=""
  fi
  if command -v dig >/dev/null 2>&1; then
    answers=$(dig +time=3 +tries=1 +short A "$domain" 2>/dev/null | awk '!seen[$1]++' || true)
    if [ -n "$answers" ] && emit_public_ipv4s "$answers"; then
      return 0
    fi
    answers=""
  fi
  if command -v host >/dev/null 2>&1; then
    answers=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | awk '!seen[$1]++' || true)
    if [ -n "$answers" ] && emit_public_ipv4s "$answers"; then
      return 0
    fi
  fi
  return 1
}

resolve_first_public_ipv4() {
  local ip
  ip=$(resolve_public_ipv4s "$1" | head -1)
  [ -n "$ip" ] && printf '%s' "$ip"
}

resolve_first_public_ipv6() {
  local domain="$1" ip
  if command -v getent >/dev/null 2>&1; then
    while read -r ip _; do
      if is_valid_ipv6 "$ip"; then
        printf '%s' "$ip"
        return 0
      fi
    done < <(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1, $2}' | awk '!seen[$1]++')
  fi
  if command -v dig >/dev/null 2>&1; then
    while read -r ip; do
      if is_valid_ipv6 "$ip"; then
        printf '%s' "$ip"
        return 0
      fi
    done < <(dig +time=3 +tries=1 +short AAAA "$domain" 2>/dev/null)
  fi
  if command -v host >/dev/null 2>&1; then
    while read -r ip; do
      if is_valid_ipv6 "$ip"; then
        printf '%s' "$ip"
        return 0
      fi
    done < <(host -t AAAA "$domain" 2>/dev/null | awk '/has IPv6 address/ {print $NF}')
  fi
  return 1
}

international_http_probe() {
  local domain="$1" ip="$2" path="${3:-}" headers http_status edge cache
  [ -n "$path" ] || { printf -- '-|-|-\n'; return 0; }
  [[ "$path" == /* ]] || path="/$path"
  headers=$(curl -4 -sS -I -L \
    --connect-timeout 3 --max-time "$INTERNATIONAL_HTTP_TIMEOUT" \
    --resolve "${domain}:443:${ip}" \
    -A 'TcpQuality/1.0' \
    "https://${domain}${path}" 2>/dev/null | tr -d '\r' || true)
  if [ -z "$headers" ]; then
    printf -- '-|-|-\n'
    return 0
  fi

  http_status=$(printf '%s\n' "$headers" | awk '
    toupper($1) ~ /^HTTP\/[0-9.]+$/ { code = $2 }
    END { print code }
  ')
  [ -n "$http_status" ] || http_status="-"
  edge=$(printf '%s\n' "$headers" | awk '
    {
      key = tolower($1); sub(/:$/, "", key)
      if (key == "cf-ray") { value = $2; sub(/.*-/, "", value); print "CF:" value; exit }
      if (key == "x-amz-cf-pop") { print "CloudFront:" $2; exit }
      if (key == "x-served-by") { print "Fastly"; exit }
    }
  ')
  [ -n "$edge" ] || edge="-"
  cache=$(printf '%s\n' "$headers" | awk '
    {
      key = tolower($1); sub(/:$/, "", key)
      if (key == "cf-cache-status" || key == "x-cache-status" || key == "x-cache") {
        print $2; exit
      }
    }
  ')
  [ -n "$cache" ] || cache="-"
  printf '%s|%s|%s\n' "$http_status" "$edge" "$cache"
}

international_test_one() {
  local idx="$1" category="$2" name="$3" provider="$4" domain="$5" path="${6:-}"
  local outfile="${RESULT_DIR}/internet_${idx}" result status _prov _isp _host _ip sent rcv loss lat
  local PACKETS="$INTERNATIONAL_PACKETS"
  local -a candidates=()
  local ip i selected_ip="" selected_success=0 candidate_count=0 limit=0
  local total_sent=0 total_rcv=0 rtt_sum="0" aggregate_loss aggregate_rtt
  local http_status="-" edge="-" cache="-"

  while read -r ip; do
    [ -n "$ip" ] && candidates+=("$ip")
  done < <(resolve_public_ipv4s "$domain" || true)
  candidate_count=${#candidates[@]}
  if [ "$DEBUG_MODE" -eq 1 ]; then
    printf '%s\n' "${candidates[@]}" > "${outfile}.ips"
  fi

  if [ "$candidate_count" -eq 0 ]; then
    printf 'FAIL|%s|%s|%s||0|0|100.00|-1\n' "$category" "$name" "$domain" > "$outfile"
    return
  fi

  limit="$INTERNATIONAL_MAX_IPS"
  [ "$limit" -gt "$candidate_count" ] && limit="$candidate_count"
  for ((i = 0; i < limit; i++)); do
    ip="${candidates[$i]}"
    result=$(probe_target "internet" 4 "$name" "$category" "$domain" "$ip" 443 "$idx" "${provider}-${i}")
    IFS='|' read -r status _prov _isp _host _ip sent rcv loss lat <<< "$result"
    if [[ "$sent" =~ ^[0-9]+$ ]]; then
      total_sent=$((total_sent + sent))
    fi
    if [[ "$rcv" =~ ^[0-9]+$ ]]; then
      total_rcv=$((total_rcv + rcv))
    fi
    if [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -gt 0 ] && [[ "$lat" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      rtt_sum=$(awk -v a="$rtt_sum" -v b="$lat" -v n="$rcv" 'BEGIN { printf "%.6f", a + b * n }')
      if [ "$selected_success" -eq 0 ]; then
        selected_ip="$ip"
        selected_success=1
      fi
    elif [ -z "$selected_ip" ]; then
      selected_ip="$ip"
    fi
  done

  aggregate_loss=$(awk -v sent="$total_sent" -v rcv="$total_rcv" 'BEGIN {
    if (sent == 0) print "100.00";
    else printf "%.2f", (sent - rcv) * 100 / sent;
  }')
  if [ "$total_rcv" -gt 0 ]; then
    aggregate_rtt=$(awk -v sum="$rtt_sum" -v rcv="$total_rcv" 'BEGIN { printf "%.3f", sum / rcv }')
  else
    aggregate_rtt=0
  fi

  if [ "$selected_success" -eq 1 ] && [ -n "$path" ]; then
    IFS='|' read -r http_status edge cache <<< "$(international_http_probe "$domain" "$selected_ip" "$path")"
  fi
  if [ "$DEBUG_MODE" -eq 1 ]; then
    printf 'provider=%s\ndomain=%s\npath=%s\nip=%s\nhttp_status=%s\nedge=%s\ncache=%s\n' \
      "$provider" "$domain" "${path:-/}" "$selected_ip" "$http_status" "$edge" "$cache" \
      > "${outfile}.http"
  fi
  if [ "$total_rcv" -eq 0 ]; then
    printf 'FAIL|%s|%s|%s|%s|%s|0|%s|-1\n' \
      "$category" "$name" "$domain" "$selected_ip" "$total_sent" "$aggregate_loss" \
      > "$outfile"
    return
  fi
  printf 'OK|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$category" "$name" "$domain" "$selected_ip" "$total_sent" "$total_rcv" "$aggregate_loss" "$aggregate_rtt" \
    > "$outfile"
}

international_latency_test_one() {
  local idx="$1" family="$2" direction="$3" row_key="$4" region="$5" label="$6" host="$7" base_port="${8:-5201}" v6_base_port="${9:-}"
  local fallback_host="${10:-}" fallback_base_port="${11:-}"
  local fallback_v6_host="${12:-}" fallback_v6_base_port="${13:-}"
  local outfile="${RESULT_DIR}/international_latency_${family}_${direction}_${idx}"
  local ip="" port="" json err_file rtt_us tcp_rtt_ms latency="-" retransmits="-" candidate_retransmits="" status="FAIL"
  local first_port last_port attempt=0 error_reason="" iperf_pid
  local -a iperf_direction_args=()

  [[ "$base_port" =~ ^[0-9]+$ ]] || base_port=5201
  if [ "$direction" = "download" ]; then
    iperf_direction_args=(-R)
  else
    direction="upload"
  fi

  if [ "$family" = "4" ]; then
    if is_public_ipv4 "$host"; then
      ip="$host"
    else
      ip=$(resolve_first_public_ipv4 "$host" || true)
    fi
  else
    ip=$(resolve_first_public_ipv6 "$host" || true)
  fi
  if [ -z "$ip" ]; then
    if [ "$family" = "4" ] && [ -n "$fallback_host" ]; then
      international_latency_test_one "$idx" "$family" "$direction" "$row_key" "$region" "$label" "$fallback_host" "${fallback_base_port:-5201}"
      return
    fi
    if [ "$family" = "6" ] && [ -n "$fallback_v6_host" ]; then
      international_latency_test_one "$idx" "$family" "$direction" "$row_key" "$region" "$label" "$fallback_v6_host" "$base_port" "$fallback_v6_base_port"
      return
    fi
    printf 'SKIP|%s|%s|%s|%s|%s|%s||-|-\n' "$family" "$direction" "$row_key" "$region" "$label" "$host" > "$outfile"
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf 'status=SKIP\nreason=no-public-%s\n' "${family}" > "${outfile}.debug"
    fi
    return
  fi

  # Leaseweb 每个端口只允许一个连接。IPv4/IPv6 使用互不重叠的端口池，
  # 每个节点/协议/方向最多尝试 10 次，循环使用同一协议的 5 个端口，任意一次成功即停止。
  if [ "$family" = "4" ]; then
    first_port="$base_port"
  else
    if [[ "$v6_base_port" =~ ^[0-9]+$ ]]; then
      first_port="$v6_base_port"
    else
      first_port=$((base_port + 5))
    fi
  fi
  last_port=$((first_port + 4))
  attempt=0
  while [ "$attempt" -lt "$INTERNATIONAL_IPERF_MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    port=$((first_port + ( (attempt - 1) % 5 )))
    json=$(mktemp "${RESULT_DIR}/iperf3.XXXXXX.json")
    err_file="${json}.err"
    tcp_rtt_ms=""
    candidate_retransmits=""
    if [ "${direction}" = "download" ] && command -v ss >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 15 iperf3 "-${family}" "${iperf_direction_args[@]}" -c "$ip" -p "$port" \
          -t "$INTERNATIONAL_IPERF_SECONDS" -b "$INTERNATIONAL_IPERF_RATE" \
          -J --connect-timeout "$INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS" \
          > "$json" 2> "$err_file" &
      else
        iperf3 "-${family}" "${iperf_direction_args[@]}" -c "$ip" -p "$port" \
          -t "$INTERNATIONAL_IPERF_SECONDS" -b "$INTERNATIONAL_IPERF_RATE" \
          -J --connect-timeout "$INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS" \
          > "$json" 2> "$err_file" &
      fi
      iperf_pid=$!
      while kill -0 "${iperf_pid}" 2>/dev/null; do
        tcp_rtt_ms=$(tcp_info_rtt_ms "$ip" "$port" || true)
        [[ "${tcp_rtt_ms}" =~ ^[0-9]+([.][0-9]+)?$ ]] || tcp_rtt_ms=""
        sleep 0.2
      done
      wait "${iperf_pid}" || true
    else
      if command -v timeout >/dev/null 2>&1; then
        timeout 15 iperf3 "-${family}" "${iperf_direction_args[@]}" -c "$ip" -p "$port" \
          -t "$INTERNATIONAL_IPERF_SECONDS" -b "$INTERNATIONAL_IPERF_RATE" \
          -J --connect-timeout "$INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS" \
          > "$json" 2> "$err_file" || true
      else
        iperf3 "-${family}" "${iperf_direction_args[@]}" -c "$ip" -p "$port" \
          -t "$INTERNATIONAL_IPERF_SECONDS" -b "$INTERNATIONAL_IPERF_RATE" \
          -J --connect-timeout "$INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS" \
          > "$json" 2> "$err_file" || true
      fi
    fi

    rtt_us=$(jq -r '
      .end.streams[0].sender.mean_rtt
      // .end.streams[0].receiver.mean_rtt
      // .intervals[-1].streams[0].rtt
      // empty
    ' "$json" 2>/dev/null || true)
    candidate_retransmits=$(jq -r '
      .end.streams[0].sender.retransmits
      // .end.sum_sent.retransmits
      // .end.streams[0].receiver.retransmits
      // empty
    ' "$json" 2>/dev/null || true)
    error_reason=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
    if [ -z "$error_reason" ] && [ -s "$err_file" ]; then
      error_reason=$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-240)
    fi
    if jq -e '(.error? // "") == "" and (((.start.connected // []) | length) > 0)' "$json" >/dev/null 2>&1; then
      if [[ "$direction" = "download" && "$tcp_rtt_ms" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        latency=$(awk -v ms="$tcp_rtt_ms" 'BEGIN { printf "%.3f", ms }')
      elif [[ "$rtt_us" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "$(awk -v us="$rtt_us" 'BEGIN { print (us > 0) ? 1 : 0 }')" -eq 1 ]; then
        latency=$(awk -v us="$rtt_us" 'BEGIN { printf "%.3f", us / 1000 }')
      else
        latency="-"
      fi
      if [[ "$latency" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [[ "$candidate_retransmits" =~ ^[0-9]+$ ]]; then
          retransmits="$candidate_retransmits"
        fi
        status="OK"
        rm -f -- "$json" "$err_file"
        break
      fi
      error_reason="${error_reason:-no-rtt}"
    fi
    rm -f -- "$json" "$err_file"
    [ "$attempt" -lt "$INTERNATIONAL_IPERF_MAX_ATTEMPTS" ] || break
  done
  if [ "$status" != "OK" ] && [ "$family" = "4" ] && [ -n "$fallback_host" ]; then
    international_latency_test_one "$idx" "$family" "$direction" "$row_key" "$region" "$label" "$fallback_host" "${fallback_base_port:-5201}"
    return
  fi
  if [ "$status" != "OK" ] && [ "$family" = "6" ] && [ -n "$fallback_v6_host" ]; then
    international_latency_test_one "$idx" "$family" "$direction" "$row_key" "$region" "$label" "$fallback_v6_host" "$base_port" "$fallback_v6_base_port"
    return
  fi
  if [ "$DEBUG_MODE" -eq 1 ]; then
    printf 'status=%s\nfamily=IPv%s\ndirection=%s\nhost=%s\nip=%s\nports=%s-%s\nattempts=%s\nrtt_tcp_info_ms=%s\nretransmits=%s\nreason=%s\n' \
      "$status" "$family" "$direction" "$host" "$ip" "$first_port" "$last_port" "$attempt" "${tcp_rtt_ms:--}" "$retransmits" "${error_reason:--}" \
      > "${outfile}.debug"
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$status" "$family" "$direction" "$row_key" "$region" "$label" "$host" "$ip" "$latency" "$retransmits" > "$outfile"
}

run_international_tests() {
  local idx=0 launched=0 entry name provider domain path category total latency_expected=0
  local row_key region label host port v6_port fallback_host fallback_port fallback_v6_host fallback_v6_port family direction
  local -a latency_families=()
  mapfile -t latency_families < <(international_latency_families)
  total=$(international_total_task_count)
  INTERNATIONAL_PROGRESS_TOTAL="$total"
  [ "$total" -gt 0 ] || return 0
  check_iperf3

  # 每个节点分别执行上传和下载；每个方向内再分别测试 IPv4/IPv6。
  for direction in upload download; do
    for family in "${latency_families[@]}"; do
      idx=0
      for entry in "${INTERNATIONAL_IPERF_TARGETS[@]}"; do
        IFS='|' read -r row_key region label host port v6_port fallback_host fallback_port fallback_v6_host fallback_v6_port <<< "$entry"
        idx=$((idx + 1))
        while [ $((launched - $(count_international_progress))) -ge "$PARALLEL" ]; do
          show_progress
          sleep 0.2
        done
        international_latency_test_one "$idx" "$family" "$direction" "$row_key" "$region" "$label" "$host" "$port" "$v6_port" "$fallback_host" "$fallback_port" "$fallback_v6_host" "$fallback_v6_port" &
        launched=$((launched + 1))
        show_progress
      done
      latency_expected=$((latency_expected + ${#INTERNATIONAL_IPERF_TARGETS[@]}))
      while [ "$(count_international_progress)" -lt "$latency_expected" ]; do
        show_progress
        sleep 0.2
      done
    done
  done

  category="网站"
  # iPerf3 延迟结果使用独立的文件名前缀；网站/CDN 结果必须从 internet_1
  # 连续编号，否则追加的节点任务会导致后半段 CDN 被展示和上传逻辑跳过。
  idx=0
  for entry in "${INTERNATIONAL_SITE_TARGETS[@]}"; do
    IFS='|' read -r name domain path <<< "$entry"
    idx=$((idx + 1))
    while [ $((launched - $(count_international_progress))) -ge "$PARALLEL" ]; do
      show_progress
      sleep 0.2
    done
    international_test_one "$idx" "$category" "$name" "Website" "$domain" "${path:-}" &
    launched=$((launched + 1))
    show_progress
  done

  category="CDN"
  for entry in "${INTERNATIONAL_CDN_TARGETS[@]}"; do
      IFS='|' read -r name provider domain path <<< "$entry"
      idx=$((idx + 1))
      while [ $((launched - $(count_international_progress))) -ge "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      international_test_one "$idx" "$category" "$name" "$provider" "$domain" "${path:-}" &
      launched=$((launched + 1))
      show_progress
  done

  while [ "$(count_international_progress)" -lt "$total" ]; do
    show_progress
    sleep 0.2
  done
  wait
  show_progress
}

append_international_csv() {
  local csv="$1" f status category name domain ip sent rcv loss lat total i
  total=$(international_task_count)
  for ((i = 1; i <= total; i++)); do
    f="${RESULT_DIR}/internet_${i}"
    [ -f "$f" ] || continue
    IFS='|' read -r status category name domain ip sent rcv loss lat < "$f"
    echo "国际互联,IPv4,$name,$category,$domain,$ip,$status,$sent,$rcv,$loss,$lat,TCP443" >> "$csv"
  done
}

append_international_latency_csv() {
  local csv="$1" entry row_key region label host port v6_port fallback_host fallback_port fallback_v6_host fallback_v6_port family direction f i
  local status result_family result_direction result_row_key result_region result_label result_host ip lat retrans loss
  local target_count=${#INTERNATIONAL_IPERF_TARGETS[@]}
  local -a latency_families=()
  mapfile -t latency_families < <(international_latency_families)

  for ((i = 1; i <= target_count; i++)); do
    entry="${INTERNATIONAL_IPERF_TARGETS[i - 1]}"
    IFS='|' read -r row_key region label host port v6_port fallback_host fallback_port fallback_v6_host fallback_v6_port <<< "$entry"
    for direction in upload download; do
      for family in "${latency_families[@]}"; do
        f="${RESULT_DIR}/international_latency_${family}_${direction}_${i}"
        [ -f "$f" ] || continue
        IFS='|' read -r status result_family result_direction result_row_key result_region result_label result_host ip lat retrans < "$f"
        if [ "$status" = "OK" ]; then loss="0.00"; else loss="100.00"; fi
        echo "国际互联,IPv${family},${result_label},延迟,${result_host},${ip},${status},0,0,${loss},${lat},iPerf3,${result_region},${result_row_key},,,${retrans:--},${result_direction:-${direction}}" >> "$csv"
      done
    done
  done
}

show_international_latency_results() {
  local first_file="${RESULT_DIR}/international_latency_4_upload_1"
  [ -f "$first_file" ] || first_file="${RESULT_DIR}/international_latency_6_upload_1"
  [ -f "$first_file" ] || first_file="${RESULT_DIR}/international_latency_4_download_1"
  [ -f "$first_file" ] || first_file="${RESULT_DIR}/international_latency_6_download_1"
  [ -f "$first_file" ] || return 0
  local target_count=${#INTERNATIONAL_IPERF_TARGETS[@]} i family direction f
  local -a latency_families=()
  mapfile -t latency_families < <(international_latency_families)
  {
    for ((i = 1; i <= target_count; i++)); do
      for direction in upload download; do
        for family in "${latency_families[@]}"; do
          f="${RESULT_DIR}/international_latency_${family}_${direction}_${i}"
          [ -f "$f" ] && cat "$f"
        done
      done
    done
  } | awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    region_w = 8
    label_w = 18
    latency_w = 9
    retrans_w = 8
  }
'"$(awk_table_helpers)"'
  function value(status, latency) {
    if (status != "OK" || latency !~ /^[0-9]+([.][0-9]+)?$/) return "-"
    return sprintf("%dms", latency + 0)
  }
  function retransmission_value(status, retransmits) {
    if (status != "OK" || retransmits !~ /^[0-9]+$/) return "-"
    return sprintf("%d", retransmits + 0)
  }
  function latency_color(value_text, numeric) {
    if (value_text == "-" || value_text == "") return red
    numeric = value_text
    sub(/ms$/, "", numeric)
    if (numeric + 0 > 200) return red
    if (numeric + 0 > 100) return yellow
    return green
  }
  function colored_latency(value_text) {
    return latency_color(value_text) pad_left(value_text, latency_w) nc
  }
  function retransmission_color(value_text, numeric) {
    if (value_text == "-" || value_text == "") return red
    numeric = value_text + 0
    if (numeric >= 50) return red
    if (numeric > 10) return yellow
    return green
  }
  function colored_retransmission(value_text) {
    return retransmission_color(value_text) pad_left(value_text, retrans_w) nc
  }
  function metric_header(text, width) {
    return spaces(width - 8) text
  }
  function metric_latency(key, slot, direction, family) {
    return values[key, slot, direction, family] == "" ? "-" : values[key, slot, direction, family]
  }
  function metric_retransmissions(key, slot, direction, family) {
    return retransmissions[key, slot, direction, family] == "" ? "-" : retransmissions[key, slot, direction, family]
  }
  function print_family_row(key, slot, family, show_region, region_text, label_text) {
    region_text = show_region && key != "americas-latam" ? pad_right(row_region[key], region_w) : pad_right("", region_w)
    label_text = pad_right(labels[key, slot], label_w)
    printf "  %s  %s  ", region_text, label_text
    printf "%s  %s  %s  %s\n", \
      colored_latency(metric_latency(key, slot, "download", family)), \
      colored_retransmission(metric_retransmissions(key, slot, "download", family)), \
      colored_latency(metric_latency(key, slot, "upload", family)), \
      colored_retransmission(metric_retransmissions(key, slot, "upload", family))
  }
  function print_header(family) {
    printf "  %s%s  %s  ", cyan, \
      pad_right("区域", region_w), \
      pad_right(family == 4 ? "节点-IPv4" : "节点-IPv6", label_w)
    printf "%s  %s  %s  %s%s\n", \
      metric_header("下载延迟", latency_w), \
      metric_header("下载重传", retrans_w), \
      metric_header("上传延迟", latency_w), \
      metric_header("上传重传", retrans_w), nc
  }
  function print_color_legend() {
    printf "  %s测试消耗流量<100MB，颜色: %s0-100ms 正常%s  %s101-200ms 一般%s  %s>200ms 较高%s\n\n", dim, green, dim, yellow, dim, red, nc
  }
  function print_family_table(family, require_success, r, s, key, has_rows, group_shown, eligible) {
    has_rows = 0
    for (r = 1; r <= row_count; r++) {
      key = row_order[r]
      for (s = 1; s <= slot_count[key]; s++) {
        eligible = require_success ? family_success[key, s, family] == 1 : family_seen[key, s, family] == 1
        if (eligible) has_rows = 1
      }
    }
    if (has_rows == 0) return 0
    print_header(family)
    for (r = 1; r <= row_count; r++) {
      key = row_order[r]
      group_shown = 0
      for (s = 1; s <= slot_count[key]; s++) {
        eligible = require_success ? family_success[key, s, family] == 1 : family_seen[key, s, family] == 1
        if (!eligible) continue
        print_family_row(key, s, family, group_shown == 0)
        group_shown = 1
      }
    }
    return 1
  }
  function print_combined_table() {
    printf "  %s%s%s%s\n", bold, cyan, "国际节点TCP互联测试", nc
    if (print_family_table(4, 0)) printf "\n"
    print_family_table(6, 1)
    print_color_legend()
  }
  {
    status = $1
    family = $2
    direction = ($3 == "download" || $3 == "upload") ? $3 : "upload"
    row_key = $4
    region = $5
    label = $6
    target_key = row_key SUBSEP label
    if (!(row_key in row_seen)) {
      row_order[++row_count] = row_key
      row_seen[row_key] = 1
      row_region[row_key] = region
    }
    if (!(target_key in target_seen)) {
      target_seen[target_key] = 1
      slot_count[row_key]++
      slot[row_key, label] = slot_count[row_key]
      labels[row_key, slot_count[row_key]] = label
    }
    s = slot[row_key, label]
    values[row_key, s, direction, family] = value(status, $9)
    retransmissions[row_key, s, direction, family] = retransmission_value(status, $10)
    family_seen[row_key, s, family] = 1
    if (status == "OK" && $9 ~ /^[0-9]+([.][0-9]+)?$/) family_success[row_key, s, family] = 1
  }
  END {
    print_combined_table()
  }'
}

show_international_results() {
  show_international_latency_results
  local file_list=("$RESULT_DIR"/internet_[0-9]*) total i f
  [ -f "${file_list[0]}" ] || return 0
  total=$(international_task_count)
  {
    for ((i = 1; i <= total; i++)); do
      f="${RESULT_DIR}/internet_${i}"
      [ -f "$f" ] && cat "$f"
    done
  } | awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v white="$WHITE" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  BEGIN {
    name_w = 24
    domain_w = 32
    reachable_w = 4
    latency_w = 10
    loss_w = 8
  }
'"$(awk_table_helpers)"'
  function latency_color(category, v, ok) {
    if (!ok) return red
    if (category == "CDN") {
      if (v > 10) return red
      if (v > 2) return yellow
      return green
    }
    if (v > 200) return red
    if (v > 100) return yellow
    return green
  }
  function loss_color(loss, ok) {
    if (!ok || loss + 0 >= 100) return red
    if (loss + 0 > 0) return yellow
    return green
  }
  function row(category, name, domain, status, loss, lat,   ok, mark, latency, loss_text) {
    ok = (status == "OK" && loss + 0 < 100)
    mark = ok ? "✓" : "x"
    latency = ok ? sprintf("%.3fms", lat + 0) : "-1ms"
    loss_text = sprintf("%d%%", int(loss + 0.5))
    printf "  %s  %s  %s%s%s  %s%s%s  %s%s%s\n", \
      pad_right(name, name_w), pad_right(domain, domain_w), \
      ok ? green : red, pad_right(mark, reachable_w), nc, \
      latency_color(category, lat + 0, ok), pad_left(latency, latency_w), nc, \
      loss_color(loss, ok), pad_left(loss_text, loss_w), nc
  }
  function header(title) {
    printf "  %s%s%s\n", bold, cyan title, nc
    printf "  %s%s  %s  %s  %s  %s%s\n", cyan, \
      pad_right("服务", name_w), pad_right("域名", domain_w), \
      pad_right("可达", reachable_w), pad_left("延迟", latency_w), pad_left("重传", loss_w), nc
    printf "  %s  %s  %s  %s  %s\n", \
      sep(name_w), sep(domain_w), sep(reachable_w), sep(latency_w), sep(loss_w)
  }
  {
    status = $1
    category = $2
    name = $3
    domain = $4
    loss = $8
    lat = $9
    if (category == "网站") {
      sites[++sn] = category SUBSEP name SUBSEP domain SUBSEP status SUBSEP loss SUBSEP lat
    } else {
      cdns[++cn] = category SUBSEP name SUBSEP domain SUBSEP status SUBSEP loss SUBSEP lat
    }
  }
  END {
    if (sn > 0) {
      header("常用网站 国际互联")
      for (i = 1; i <= sn; i++) {
        split(sites[i], a, SUBSEP)
        row(a[1], a[2], a[3], a[4], a[5], a[6])
      }
      printf "  %s颜色: %s0-100ms 正常%s  %s101-200ms 一般%s  %s>200ms 较高%s\n\n", dim, green, dim, yellow, dim, red, nc
    }
    if (cn > 0) {
      header("常用 CDN 国际互联")
      for (i = 1; i <= cn; i++) {
        split(cdns[i], a, SUBSEP)
        row(a[1], a[2], a[3], a[4], a[5], a[6])
      }
      printf "  %s颜色: %s0-2ms 正常%s  %s2-10ms 一般%s  %s>10ms 较高%s\n\n", dim, green, dim, yellow, dim, red, nc
    }
  }'
}

run_international_mode() {
  local report_time csv
  require_raw_socket_privilege
  check_curl
  check_nping
  echo -e "${DIM}  国际互联网站/CDN: $(international_task_count)  延迟方向: ${#INTERNATIONAL_IPERF_TARGETS[@]}×$(international_latency_family_count)×2（上传/下载）  并行: $PARALLEL  端口: 443/tcp、iPerf3 ${INTERNATIONAL_IPERF_RATE}/${INTERNATIONAL_IPERF_SECONDS}s，失败最多重试 ${INTERNATIONAL_IPERF_MAX_ATTEMPTS} 次（目标可单独指定）${NC}"
  echo
  MULTI_PROGRESS_MODE=1
  TOTAL=0
  ROUTE_PROGRESS_TOTAL=0
  SPEEDTEST_ENABLED=0
  run_international_tests
  printf '\n'
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  csv="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$csv"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路,回程连接耗时ms,回程TLS握手耗时ms,去程连接耗时ms,去程TLS握手耗时ms,iPerf3重传次数,iPerf3方向" >> "$csv"
  append_international_csv "$csv"
  append_international_latency_csv "$csv"
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo
  show_international_results
  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    upload_report "$csv" "${report_time%%（*}"
  fi
  echo
}

# ===================== 国内单线程测速 =====================
SPEEDTEST_IFACE=""
SPEEDTEST_TOS_REGION="${TOS_REGION:-cn-beijing}"
SPEEDTEST_TOS_NETWORK="${TOS_NETWORK:-public}"
SPEEDTEST_TOS_SIZE="${TOS_PROBE_SIZE:-500MB}"
SPEEDTEST_TOS_TIMEOUT="${TOS_TIMEOUT:-10}"
SPEEDTEST_APPLECDN_ENABLED="${SPEEDTEST_APPLECDN_ENABLED:-1}"
SPEEDTEST_APPLECDN_DOWNLOAD_URL="${SPEEDTEST_APPLECDN_DOWNLOAD_URL:-https://mensura.cdn-apple.com/api/v1/gm/large}"
SPEEDTEST_APPLECDN_UPLOAD_URL="${SPEEDTEST_APPLECDN_UPLOAD_URL:-https://mensura.cdn-apple.com/api/v1/gm/slurp}"
SPEEDTEST_APPLECDN_HOST="${SPEEDTEST_APPLECDN_HOST:-mensura.cdn-apple.com}"
SPEEDTEST_APPLECDN_MAX_MB="${SPEEDTEST_APPLECDN_MAX_MB:-2048}"
SPEEDTEST_APPLECDN_USER_AGENT="${SPEEDTEST_APPLECDN_USER_AGENT:-networkQuality/194.80.3 CFNetwork/3860.400.51 Darwin/25.3.0}"
SPEEDTEST_TOS_CT_IP="${TOS_CT_IP:-42.81.80.86}"
SPEEDTEST_TOS_CU_IP="${TOS_CU_IP:-221.194.175.109}"
SPEEDTEST_TOS_CM_IP="${TOS_CM_IP:-120.255.0.180}"
SPEEDTEST_IPV6_PROBE_URL="${SPEEDTEST_IPV6_PROBE_URL:-https://api6.ipify.org}"
SPEEDTEST_IPV6_CHECKED=0
SPEEDTEST_IPV6_AVAILABLE=0
SPEEDTEST_TOS_REMOTE_LOADED=0
SPEEDTEST_APPLECDN6_REMOTE_LOADED=0
SPEEDTEST_APPLECDN6_NODES=()
SPEEDTEST_TOS_CT_CITY="北京"
SPEEDTEST_TOS_CU_CITY="北京"
SPEEDTEST_TOS_CM_CITY="北京"
SPEEDTEST_TOS_CT_CANDIDATES="${TOS_CT_IP:-42.81.80.86}|北京|cn-beijing"
SPEEDTEST_TOS_CU_CANDIDATES="${TOS_CU_IP:-221.194.175.109}|北京|cn-beijing"
SPEEDTEST_TOS_CM_CANDIDATES="${TOS_CM_IP:-120.255.0.180}|北京|cn-beijing"
SPEEDTEST_TELECOM_ID=""
SPEEDTEST_TELECOM_CITY=""
SPEEDTEST_UNICOM_ID=""
SPEEDTEST_UNICOM_CITY=""
SPEEDTEST_MOBILE_ID=""
SPEEDTEST_MOBILE_CITY=""
SPEEDTEST_ROWS=()
SPEEDTEST_RANK_ELIGIBLE=1
SPEEDTEST_RANK_DISABLED_REASON=""
SPEEDTEST_COUNTER_CHAIN=""
SPEEDTEST_COUNTER_HOOK=""
SPEEDTEST_COUNTER_TOOL=""
SPEEDTEST_TCP_INFO_ENABLED="${TCPQUALITY_TCP_INFO:-1}"
SPEEDTEST_TCP_INFO_MONITOR_PID=""
SPEEDTEST_TCP_INFO_ACTIVE_MODE="none"
SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD=""
SPEEDTEST_TCP_INFO_FAILURE_REASON=""
SPEEDTEST_RETRANS_TRACE_ENABLED="${TCPQUALITY_RETRANS_TRACE:-1}"
SPEEDTEST_RETRANS_TRACE_PID=""
SPEEDTEST_RETRANS_TRACE_FILE=""
SPEEDTEST_RETRANS_TRACE_ERR=""
SPEEDTEST_RETRANS_TRACE_READY=0
SPEEDTEST_RETRANS_TRACE_KEY=""
SPEEDTEST_RETRANS_TRACE_DISABLED=0
SPEEDTEST_TCP_INFO_PRELOAD="${TCPQUALITY_TCP_INFO_PRELOAD:-/usr/local/lib/libtcpquality-tcpinfo.so}"
SPEEDTEST_RETRANS_TRACE_SCRIPT="${TCPQUALITY_RETRANS_TRACE_SCRIPT:-/usr/local/libexec/tcpquality-retrans-seq.bt}"
SPEEDTEST_RETRANS_TRACE_FALLBACK_SCRIPT="${TCPQUALITY_RETRANS_TRACE_FALLBACK_SCRIPT:-/usr/local/libexec/tcpquality-retrans-skb.bt}"
SPEEDTEST_BPFTRACE_BTF="${TCPQUALITY_BPFTRACE_BTF:-/sys/kernel/btf/vmlinux}"

speedtest_candidates() {
  case "$1" in
    电信)
      printf '%s\n' "$SPEEDTEST_TOS_CT_CANDIDATES"
      ;;
    联通)
      printf '%s\n' "$SPEEDTEST_TOS_CU_CANDIDATES"
      ;;
    移动)
      printf '%s\n' "$SPEEDTEST_TOS_CM_CANDIDATES"
      ;;
  esac
}

speedtest_group_specs() {
  local selected_supported=0
  if [ -n "$SELECTED_PROVINCES" ]; then
    [[ "$SELECTED_PROVINCES" == *"|北京|"* ]] && {
      printf '%s\n' "北京|cn-beijing|unlimited"
      selected_supported=1
    }
    [[ "$SELECTED_PROVINCES" == *"|上海|"* ]] && {
      printf '%s\n' "上海|cn-shanghai|unlimited"
      selected_supported=1
    }
    [[ "$SELECTED_PROVINCES" == *"|广东|"* ]] && {
      printf '%s\n' "广东|cn-guangzhou|unlimited"
      selected_supported=1
    }
    [ "$selected_supported" -eq 1 ] && return 0
  fi
  printf '%s\n' \
    "北京|cn-beijing|unlimited" \
    "上海|cn-shanghai|unlimited" \
    "广东|cn-guangzhou|unlimited"
}

speedtest_group_count() {
  speedtest_group_specs | awk 'NF{count++} END{print count + 0}'
}

speedtest_applecdn_tests_enabled() {
  [ "$SPEEDTEST_APPLECDN_ENABLED" = "1" ] || return 1
  if [[ "$SELECTED_PROVINCES" == *"|北京|"* ||
        "$SELECTED_PROVINCES" == *"|上海|"* ||
        "$SELECTED_PROVINCES" == *"|广东|"* ]]; then
    return 1
  fi
  return 0
}

speedtest_applecdn6_tests_enabled() {
  speedtest_applecdn_tests_enabled || return 1
  speedtest_ipv6_available
}

speedtest_applecdn6_count() {
  speedtest_applecdn6_tests_enabled || {
    printf '0'
    return 0
  }
  load_remote_applecdn6_nodes || true
  printf '%s' "${#SPEEDTEST_APPLECDN6_NODES[@]}"
}

request_rank_session() {
  local response_file session_id token started_at expires_at session_ip4
  RANK_SESSION_ID=""
  RANK_SESSION_TOKEN=""
  RANK_SESSION_STARTED_AT=""
  RANK_SESSION_EXPIRES_AT=""
  RANK_SESSION_IP4=""
  command -v curl &>/dev/null || return 1

  response_file=$(mktemp)
  if ! curl -4 -fsS --connect-timeout 5 --max-time 15 \
    -H "X-TcpQuality-Public-IPv4: ${IPV4_PUBLIC:-}" \
    -H "X-TcpQuality-Public-IPv6: ${IPV6_PUBLIC:-}" \
    -o "$response_file" "$RANK_SESSION_API" >/dev/null 2>&1; then
    if [ "$DEBUG_MODE" -eq 1 ]; then
      cp "$response_file" "$RESULT_DIR/rank_session_response.json" 2>/dev/null || true
    fi
    rm -f "$response_file"
    return 1
  fi
  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$response_file" "$RESULT_DIR/rank_session_response.json" 2>/dev/null || true
  fi

  session_id=$(sed -nE 's/.*"sessionId":"([^"]+)".*/\1/p' "$response_file" | head -1)
  token=$(sed -nE 's/.*"token":"([^"]+)".*/\1/p' "$response_file" | head -1)
  started_at=$(sed -nE 's/.*"startedAt":"([^"]+)".*/\1/p' "$response_file" | head -1)
  expires_at=$(sed -nE 's/.*"expiresAt":"([^"]+)".*/\1/p' "$response_file" | head -1)
  session_ip4=$(sed -nE 's/.*"sessionIp4":"([^"]+)".*/\1/p' "$response_file" | head -1)
  rm -f "$response_file"
  [ -n "$session_id" ] && [ -n "$token" ] || return 1
  RANK_SESSION_ID="$session_id"
  RANK_SESSION_TOKEN="$token"
  RANK_SESSION_STARTED_AT="$started_at"
  RANK_SESSION_EXPIRES_AT="$expires_at"
  RANK_SESSION_IP4="$session_ip4"
  return 0
}

speedtest_region_title() {
  case "$1" in
    cn-shanghai) printf '上海' ;;
    cn-guangzhou) printf '广东' ;;
    *) printf '北京' ;;
  esac
}

speedtest_pick_candidate() {
  local carrier="$1" region="$2"
  speedtest_candidates "$carrier" | awk -F'|' -v region="$region" '
    $1 != "" && $3 == region { print; exit }
  '
}

load_remote_speedtest_nodes() {
  local tmp url sep line type family prov isp host ip port target backup_host backup_ip backup_port backup_target region
  local loaded_ct=0 loaded_cu=0 loaded_cm=0
  local ct_candidates="" cu_candidates="" cm_candidates=""
  [ "$SPEEDTEST_TOS_REMOTE_LOADED" -eq 1 ] && return 0
  command -v curl &>/dev/null || return 1

  tmp=$(mktemp)
  sep="?"
  [[ "$GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${GET_NODES_URL}${sep}format=tsv&scope=tos"
  if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target <<< "$line"
    [ "$type" = "type" ] && continue
    [ "$family" = "4" ] || continue
    [ -n "$ip" ] || continue
    case "$type" in
      tos|tosutil|speedtest) ;;
      *) continue ;;
    esac
    region="cn-beijing"
    case "$target" in
      *cn-shanghai*) region="cn-shanghai" ;;
      *cn-guangzhou*) region="cn-guangzhou" ;;
      *cn-beijing*) region="cn-beijing" ;;
    esac
    case "$isp" in
      电信|CT|ChinaTelecom|chinatelecom)
        SPEEDTEST_TOS_CT_IP="$ip"
        SPEEDTEST_TOS_CT_CITY="${prov:-北京}"
        ct_candidates+="${ct_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_ct=1
        ;;
      联通|CU|ChinaUnicom|chinaunicom)
        SPEEDTEST_TOS_CU_IP="$ip"
        SPEEDTEST_TOS_CU_CITY="${prov:-北京}"
        cu_candidates+="${cu_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_cu=1
        ;;
      移动|CM|ChinaMobile|chinamobile)
        SPEEDTEST_TOS_CM_IP="$ip"
        SPEEDTEST_TOS_CM_CITY="${prov:-北京}"
        cm_candidates+="${cm_candidates:+$'\n'}$ip|${prov:-北京}|$region"
        loaded_cm=1
        ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  if [ "$loaded_ct" -eq 1 ] || [ "$loaded_cu" -eq 1 ] || [ "$loaded_cm" -eq 1 ]; then
    [ -n "$ct_candidates" ] && SPEEDTEST_TOS_CT_CANDIDATES="$ct_candidates"
    [ -n "$cu_candidates" ] && SPEEDTEST_TOS_CU_CANDIDATES="$cu_candidates"
    [ -n "$cm_candidates" ] && SPEEDTEST_TOS_CM_CANDIDATES="$cm_candidates"
    SPEEDTEST_TOS_REMOTE_LOADED=1
    return 0
  fi
  return 1
}

load_remote_applecdn6_nodes() {
  local tmp url sep line type family prov isp host ip port target backup_host backup_ip backup_port backup_target label
  local local_index existing existing_label
  [ "$SPEEDTEST_APPLECDN6_REMOTE_LOADED" -eq 1 ] && return 0
  command -v curl &>/dev/null || return 1

  tmp=$(mktemp)
  sep="?"
  [[ "$GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${GET_NODES_URL}${sep}format=tsv&scope=apple6"
  if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  SPEEDTEST_APPLECDN6_NODES=()
  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target <<< "$line"
    [ "$type" = "type" ] && continue
    [ "$type" = "applecdn" ] || continue
    [ "$family" = "6" ] || continue
    [ "$isp" = "移动" ] || continue
    is_valid_ipv6 "$ip" || continue
    label="${prov}${isp}"
    local_index=0
    for existing in "${SPEEDTEST_APPLECDN6_NODES[@]}"; do
      existing_label=${existing%%|*}
      if [ "$existing_label" = "$label" ]; then
        SPEEDTEST_APPLECDN6_NODES[$local_index]="${existing}|$ip"
        break
      fi
      local_index=$((local_index + 1))
    done
    [ "$local_index" -lt "${#SPEEDTEST_APPLECDN6_NODES[@]}" ] || \
      SPEEDTEST_APPLECDN6_NODES+=("$label|$ip")
  done < "$tmp"
  rm -f "$tmp"
  [ "${#SPEEDTEST_APPLECDN6_NODES[@]}" -gt 0 ] || return 1
  SPEEDTEST_APPLECDN6_REMOTE_LOADED=1
  return 0
}

speedtest_selected_id() {
  case "$1" in
    电信) printf '%s' "$SPEEDTEST_TELECOM_ID" ;;
    联通) printf '%s' "$SPEEDTEST_UNICOM_ID" ;;
    移动) printf '%s' "$SPEEDTEST_MOBILE_ID" ;;
  esac
}

speedtest_selected_city() {
  case "$1" in
    电信) printf '%s' "$SPEEDTEST_TELECOM_CITY" ;;
    联通) printf '%s' "$SPEEDTEST_UNICOM_CITY" ;;
    移动) printf '%s' "$SPEEDTEST_MOBILE_CITY" ;;
  esac
}

speedtest_set_selected() {
  local carrier="$1" server_id="$2" city="$3"
  case "$carrier" in
    电信) SPEEDTEST_TELECOM_ID="$server_id"; SPEEDTEST_TELECOM_CITY="$city" ;;
    联通) SPEEDTEST_UNICOM_ID="$server_id"; SPEEDTEST_UNICOM_CITY="$city" ;;
    移动) SPEEDTEST_MOBILE_ID="$server_id"; SPEEDTEST_MOBILE_CITY="$city" ;;
  esac
}

speedtest_cleanup() {
  speedtest_tcp_info_monitor_stop
  speedtest_retrans_trace_stop
  speedtest_counter_stop_current
}

speedtest_dependencies_ready() {
  local cmd
  for cmd in ip nstat awk curl; do
    command -v "$cmd" &>/dev/null || return 1
  done
}

install_speedtest_dependencies() {
  if is_nixos; then
    echo -e "${RED}[X] Nix 临时环境中的测速依赖不完整${NC}" >&2
    return 1
  fi
  show_dependency_install_notice
  if command -v apt-get &>/dev/null; then
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq \
      iproute2 gawk curl ca-certificates >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q iproute gawk curl ca-certificates >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q iproute gawk curl ca-certificates >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache iproute2 awk curl ca-certificates >/dev/null 2>&1
  else
    return 1
  fi
  if speedtest_dependencies_ready; then
    clear_dependency_install_notice
    return 0
  fi
  clear_dependency_install_notice
  return 1
}

install_speedtest_counter_dependency() {
  command -v iptables &>/dev/null && command -v ip6tables &>/dev/null && return 0
  if is_nixos; then
    return 1
  fi
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq iptables >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q iptables >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q iptables >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache iptables >/dev/null 2>&1
  else
    return 1
  fi
  command -v iptables &>/dev/null && command -v ip6tables &>/dev/null
}

speedtest_retrans_count() {
  nstat -az 2>/dev/null | awk '$1=="TcpRetransSegs"{print $2; found=1} END{if(!found) print 0}'
}

speedtest_retrans_percent() {
  local retrans="$1" packets="$2"
  awk -v retrans="$retrans" -v packets="$packets" 'BEGIN {
    if (retrans !~ /^[0-9]+$/ || packets !~ /^[0-9]+$/ || packets <= 0) {
      print "-"
      exit
    }
    ratio = retrans / packets * 100
    if (ratio < 0) ratio = 0
    if (ratio > 100) ratio = 100
    printf "%.2f%%", ratio
  }'
}

speedtest_unique_retrans_percent() {
  local retrans="$1" data_segs_out="$2" total_retrans="$3" denominator
  denominator=$(awk -v data="$data_segs_out" -v retrans="$total_retrans" 'BEGIN {
    if (data !~ /^[0-9]+$/ || retrans !~ /^[0-9]+$/ || data <= 0) {
      print 0
      exit
    }
    denominator = data - retrans
    if (denominator <= 0) denominator = data
    print denominator
  }')
  speedtest_retrans_percent "$retrans" "$denominator"
}

speedtest_curl_partial_timeout_valid() {
  local exit_code="$1" elapsed="$2" timeout="$3" bytes="$4"
  [ "$exit_code" -eq 28 ] || return 1
  [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] || return 1
  awk -v elapsed="$elapsed" -v timeout="$timeout" 'BEGIN {
    if (elapsed !~ /^[0-9]+([.][0-9]+)?$/ ||
        timeout !~ /^[0-9]+([.][0-9]+)?$/) {
      exit 1
    }
    exit !((elapsed + 0) >= (timeout + 0) - 0.1)
  }'
}

speedtest_curl_partial_http_valid() {
  local http_code="$1" elapsed="$2" bytes="$3"
  [ "$http_code" = "413" ] || return 1
  [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] || return 1
  awk -v elapsed="$elapsed" 'BEGIN {
    if (elapsed !~ /^[0-9]+([.][0-9]+)?$/ || elapsed <= 0) exit 1
  }'
}

speedtest_curl_average_rate() {
  local bytes="$1" elapsed="$2"
  awk -v bytes="$bytes" -v elapsed="$elapsed" 'BEGIN {
    if (bytes !~ /^[0-9]+$/ || elapsed !~ /^[0-9]+([.][0-9]+)?$/ ||
        bytes <= 0 || elapsed <= 0) {
      print 0
      exit
    }
    printf "%.0f", bytes / elapsed
  }'
}

speedtest_result_valid() {
  local value="$1"
  [ "$value" != "failed" ] && [ -n "$value" ]
}

speedtest_parse_rate_mbps() {
  awk '
    tolower($0) ~ /average/ && tolower($0) ~ /rate:/ {
      line = $0
      sub(/^.*[Rr][Aa][Tt][Ee]:[[:space:]]*/, "", line)
      compact = line
      gsub(/[[:space:]]+/, "", compact)
      if (match(compact, /[0-9]+([.][0-9]+)?[GgMmKk]?[Bb]\/[Ss]/)) {
        token = substr(compact, RSTART, RLENGTH)
        value = token
        unit = token
        gsub(/[^0-9.]/, "", value)
        gsub(/[0-9.[:space:]]/, "", unit)
      } else {
        value = $(NF)
        unit = $(NF)
        gsub(/[^0-9.]/, "", value)
      }
      unit = toupper(unit)
      if (unit ~ /GB\/S/) value = value * 8000
      else if (unit ~ /MB\/S/) value = value * 8
      else if (unit ~ /KB\/S/) value = value * 8 / 1000
      else if (unit ~ /B\/S/) value = value * 8 / 1000000
      else next
      printf "%.1f", value
      found = 1
    }
    END { if (!found) printf "failed" }
  '
}

speedtest_net_bytes() {
  local probe_type="$1" stat="rx_bytes"
  [ "$probe_type" = "upload" ] && stat="tx_bytes"
  cat "/sys/class/net/$SPEEDTEST_IFACE/statistics/$stat" 2>/dev/null || printf -- '-'
}

speedtest_counter_stop_current() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  if [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] && [ -n "${SPEEDTEST_COUNTER_HOOK:-}" ]; then
    $USE_SUDO "$tool" -D "$SPEEDTEST_COUNTER_HOOK" -j "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -F "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -X "$SPEEDTEST_COUNTER_CHAIN" >/dev/null 2>&1 || true
  fi
  SPEEDTEST_COUNTER_CHAIN=""
  SPEEDTEST_COUNTER_HOOK=""
  SPEEDTEST_COUNTER_TOOL=""
}

speedtest_tcp_info_ss_snapshot() {
  local server_ip="$1" family_flag="${2:--4}" ss_output
  command -v ss >/dev/null 2>&1 || return 1
  ss_output=$(ss -tinp -n "$family_flag" state established 2>/dev/null || true)
  [ -n "$ss_output" ] || return 1
  printf '%s\n' "$ss_output" | awk -v target="$server_ip" '
    BEGIN { target_is_v6 = (index(target, ":") > 0) }
    function field_value(line, name, i, token, fields, count) {
      count = split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (fields[i] ~ ("^" name ":[0-9]+$")) {
          token = fields[i]
          sub("^" name ":", "", token)
          return token + 0
        }
      }
      return 0
    }
    function retrans_value(line, i, token, fields, count) {
      count = split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (fields[i] ~ /^retrans:[0-9]+\/[0-9]+$/) {
          token = fields[i]
          sub(/^retrans:[0-9]+\//, "", token)
          return token + 0
        }
      }
      # ss may omit retrans:0/0 when this connection has not retransmitted.
      return 0
    }
    $1 == "ESTAB" {
      if (target_is_v6) {
        waiting = (index($0, "[" target "]:443") > 0)
      } else {
        waiting = (index($0, target ":443") > 0)
      }
      next
    }
    # `ss ... state established` omits the state column on some iproute2
    # versions, leaving Recv-Q/Send-Q as fields 1/2. Handle that form too.
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (target_is_v6) {
        waiting = (index($0, "[" target "]:443") > 0)
      } else {
        waiting = (index($0, target ":443") > 0)
      }
      next
    }
    waiting && ($0 ~ /(^|[[:space:]])data_segs_out:[0-9]+([[:space:]]|$)/ ||
                $0 ~ /(^|[[:space:]])segs_out:[0-9]+([[:space:]]|$)/) {
      printf "%d|%d|%d|%d\n", retrans_value($0), \
        field_value($0, "data_segs_out"), \
        field_value($0, "segs_out"), \
        field_value($0, "bytes_retrans")
      exit
    }
  '
}

speedtest_tcp_info_metrics() {
  local info_file="$1"
  local tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans
  local denominator ratio
  [ -s "$info_file" ] || return 1
  IFS='|' read -r tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans < "$info_file" || true
  if ! [[ "$tcp_info_retrans" =~ ^[0-9]+$ ]] ||
     ! [[ "$tcp_info_data_segs_out" =~ ^[0-9]+$ ]] ||
     ! [[ "$tcp_info_segs_out" =~ ^[0-9]+$ ]] ||
     ! [[ "$tcp_info_bytes_retrans" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$tcp_info_data_segs_out" -gt 0 ]; then
    denominator="$tcp_info_data_segs_out"
  else
    denominator="$tcp_info_segs_out"
  fi
  [ "$denominator" -gt 0 ] || return 1
  ratio=$(speedtest_retrans_percent "$tcp_info_retrans" "$denominator")
  [ "$ratio" != "-" ] || return 1
  printf '%s|%s|%s|%s|%s' "$ratio" "$tcp_info_retrans" \
    "$tcp_info_data_segs_out" "$tcp_info_segs_out" "$tcp_info_bytes_retrans"
}

speedtest_tcp_info_preload_path() {
  local preload="${SPEEDTEST_TCP_INFO_PRELOAD:-}"
  SPEEDTEST_TCP_INFO_FAILURE_REASON=""
  if [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" != "1" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="disabled"
    return 1
  fi
  if [ -z "$preload" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="preload_path_empty"
    return 1
  fi
  if [ ! -r "$preload" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="preload_missing:$preload"
    return 1
  fi
  printf '%s\n' "$preload"
}

speedtest_tcp_info_monitor_loop() {
  local server_ip="$1" output_file="$2" family_flag="${3:--4}" snapshot temp_file
  trap - EXIT INT TERM
  temp_file="${output_file}.tmp"
  set +e
  while :; do
    snapshot=$(speedtest_tcp_info_ss_snapshot "$server_ip" "$family_flag" 2>/dev/null || true)
    if [ -n "$snapshot" ]; then
      printf '%s\n' "$snapshot" > "$temp_file" && mv -f "$temp_file" "$output_file"
    fi
    sleep 0.05
  done
}

speedtest_tcp_info_monitor_start() {
  local server_ip="$1" output_file="$2" family_flag="${3:--4}" preload force_ss="${4:-0}"
  SPEEDTEST_TCP_INFO_MONITOR_PID=""
  SPEEDTEST_TCP_INFO_ACTIVE_MODE="none"
  SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD=""
  SPEEDTEST_TCP_INFO_FAILURE_REASON=""
  if [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" != "1" ]; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="disabled"
    return 1
  fi
  rm -f "$output_file" "${output_file}.tmp"

  if [ "$force_ss" != "1" ]; then
    preload=$(speedtest_tcp_info_preload_path 2>/dev/null || true)
    if [ -n "$preload" ]; then
      SPEEDTEST_TCP_INFO_ACTIVE_MODE="getsockopt"
      SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD="$preload"
      return 0
    fi
  fi

  if ! command -v ss >/dev/null 2>&1; then
    SPEEDTEST_TCP_INFO_FAILURE_REASON="ss_unavailable"
    return 1
  fi
  SPEEDTEST_TCP_INFO_ACTIVE_MODE="ss"
  speedtest_tcp_info_monitor_loop "$server_ip" "$output_file" "$family_flag" &
  SPEEDTEST_TCP_INFO_MONITOR_PID=$!
  return 0
}

speedtest_tcp_info_monitor_stop() {
  local pid="${SPEEDTEST_TCP_INFO_MONITOR_PID:-}"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  SPEEDTEST_TCP_INFO_MONITOR_PID=""
}

speedtest_retrans_trace_program() {
  local script_path="$1"
  [ -r "$script_path" ] || return 1
  cat "$script_path"
}

speedtest_retrans_trace_launch() {
  local output_file="$1" program="$2" use_btf="$3"
  rm -f "$SPEEDTEST_RETRANS_TRACE_FILE" "$SPEEDTEST_RETRANS_TRACE_ERR"
  if [ "$use_btf" -eq 1 ] && [ -r "$SPEEDTEST_BPFTRACE_BTF" ]; then
    BPFTRACE_BTF="$SPEEDTEST_BPFTRACE_BTF" bpftrace -q -e "$program" \
      > "$SPEEDTEST_RETRANS_TRACE_FILE" 2> "$SPEEDTEST_RETRANS_TRACE_ERR" &
  else
    bpftrace -q -e "$program" \
      > "$SPEEDTEST_RETRANS_TRACE_FILE" 2> "$SPEEDTEST_RETRANS_TRACE_ERR" &
  fi
  SPEEDTEST_RETRANS_TRACE_PID=$!
  # Allow bpftrace to load the program before curl starts.  A failed attach
  # exits immediately and is treated as unavailable below.
  sleep 0.1
  if ! kill -0 "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null; then
    wait "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    SPEEDTEST_RETRANS_TRACE_PID=""
    return 1
  fi
  if [ -s "$SPEEDTEST_RETRANS_TRACE_ERR" ]; then
    kill -KILL "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    wait "$SPEEDTEST_RETRANS_TRACE_PID" 2>/dev/null || true
    SPEEDTEST_RETRANS_TRACE_PID=""
    return 1
  fi
  SPEEDTEST_RETRANS_TRACE_READY=1
  return 0
}

speedtest_retrans_trace_start() {
  local output_file="$1" program
  SPEEDTEST_RETRANS_TRACE_PID=""
  SPEEDTEST_RETRANS_TRACE_FILE="${output_file}.retrans-trace"
  SPEEDTEST_RETRANS_TRACE_ERR="${SPEEDTEST_RETRANS_TRACE_FILE}.err"
  SPEEDTEST_RETRANS_TRACE_READY=0
  SPEEDTEST_RETRANS_TRACE_KEY=""
  [ "${SPEEDTEST_RETRANS_TRACE_ENABLED:-1}" = "1" ] || return 1
  [ "${SPEEDTEST_RETRANS_TRACE_DISABLED:-0}" -eq 0 ] || return 1
  command -v bpftrace >/dev/null 2>&1 || return 1
  program=$(speedtest_retrans_trace_program "$SPEEDTEST_RETRANS_TRACE_SCRIPT" 2>/dev/null || true)
  if [ -n "$program" ] && speedtest_retrans_trace_launch "$output_file" "$program" 1; then
    SPEEDTEST_RETRANS_TRACE_KEY="seq"
    return 0
  fi
  program=$(speedtest_retrans_trace_program "$SPEEDTEST_RETRANS_TRACE_FALLBACK_SCRIPT" 2>/dev/null || true)
  if [ -n "$program" ] && speedtest_retrans_trace_launch "$output_file" "$program" 0; then
    SPEEDTEST_RETRANS_TRACE_KEY="skb"
    return 0
  fi
  SPEEDTEST_RETRANS_TRACE_READY=0
  SPEEDTEST_RETRANS_TRACE_DISABLED=1
  return 1
}

speedtest_retrans_trace_stop() {
  local pid="${SPEEDTEST_RETRANS_TRACE_PID:-}" status=0 attempt
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill -INT "$pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for attempt in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
      done
    fi
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 130 ] || {
      SPEEDTEST_RETRANS_TRACE_READY=0
    }
  fi
  SPEEDTEST_RETRANS_TRACE_PID=""
}

speedtest_retrans_trace_count_ipv4() {
  local trace_file="$1" server_ip="$2" a b c d key="${SPEEDTEST_RETRANS_TRACE_KEY:-skb}"
  [ -s "$trace_file" ] || {
    printf '0\n'
    return 0
  }
  IFS=. read -r a b c d <<< "$server_ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
     "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || {
    printf -- '-\n'
    return 0
  }
  awk -F'|' -v a="$a" -v b="$b" -v c="$c" -v d="$d" -v key="$key" '
    $1 == 2 && $2 == a && $3 == b && $4 == c && $5 == d {
      if (key == "seq" && $18 ~ /^0x[0-9a-fA-F]+$/ &&
          $19 ~ /^[0-9]+$/ && $20 ~ /^[0-9]+$/ &&
          $18 != "0x0" && $19 != $20) {
        unique[$18 ":" $19 ":" $20] = 1
      } else if (key != "seq" && $18 ~ /^0x[0-9a-fA-F]+$/ &&
                 $19 ~ /^0x[0-9a-fA-F]+$/ &&
                 $18 != "0x0" && $19 != "0x0") {
        unique[$18 ":" $19] = 1
      }
    }
    END {
      count = 0
      for (key in unique) count++
      print count + 0
    }
  ' "$trace_file"
}

speedtest_counter_start() {
  local probe_type="$1" server_ip="$2" hook chain tool="iptables"
  speedtest_counter_stop_current
  [ -n "$server_ip" ] || return 1
  [[ "$server_ip" == *:* ]] && tool="ip6tables"
  command -v "$tool" &>/dev/null || return 1

  if [ "$probe_type" = "download" ]; then
    hook="INPUT"
  else
    hook="OUTPUT"
  fi
  chain="TCPQ_TOS_$$_$RANDOM"

  $USE_SUDO "$tool" -N "$chain" >/dev/null 2>&1 || return 1
  $USE_SUDO "$tool" -I "$hook" 1 -j "$chain" >/dev/null 2>&1 || {
    $USE_SUDO "$tool" -F "$chain" >/dev/null 2>&1 || true
    $USE_SUDO "$tool" -X "$chain" >/dev/null 2>&1 || true
    return 1
  }

  if [ "$probe_type" = "download" ]; then
    $USE_SUDO "$tool" -A "$chain" -p tcp -s "$server_ip" --sport 443 -j RETURN >/dev/null 2>&1 || {
      SPEEDTEST_COUNTER_CHAIN="$chain"
      SPEEDTEST_COUNTER_HOOK="$hook"
      SPEEDTEST_COUNTER_TOOL="$tool"
      speedtest_counter_stop_current
      return 1
    }
  else
    $USE_SUDO "$tool" -A "$chain" -p tcp -d "$server_ip" --dport 443 -j RETURN >/dev/null 2>&1 || {
      SPEEDTEST_COUNTER_CHAIN="$chain"
      SPEEDTEST_COUNTER_HOOK="$hook"
      SPEEDTEST_COUNTER_TOOL="$tool"
      speedtest_counter_stop_current
      return 1
    }
  fi

  SPEEDTEST_COUNTER_CHAIN="$chain"
  SPEEDTEST_COUNTER_HOOK="$hook"
  SPEEDTEST_COUNTER_TOOL="$tool"
  return 0
}

speedtest_counter_bytes() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] || {
    printf -- '-'
    return 0
  }
  $USE_SUDO "$tool" -L "$SPEEDTEST_COUNTER_CHAIN" -v -x -n 2>/dev/null | awk '
    NR > 2 && $3 == "RETURN" { print $2; found=1; exit }
    END { if (!found) print "-" }
  '
}

speedtest_counter_packets() {
  local tool="${SPEEDTEST_COUNTER_TOOL:-iptables}"
  [ -n "${SPEEDTEST_COUNTER_CHAIN:-}" ] || {
    printf -- '-'
    return 0
  }
  $USE_SUDO "$tool" -L "$SPEEDTEST_COUNTER_CHAIN" -v -x -n 2>/dev/null | awk '
    NR > 2 && $3 == "RETURN" { print $1; found=1; exit }
    END { if (!found) print "-" }
  '
}

speedtest_calc_mbps() {
  local bytes="$1" seconds="$2"
  awk -v b="$bytes" -v s="$seconds" 'BEGIN {
    mbps = b * 8 / s / 1000000;
    if (s <= 0 || b <= 0 || mbps < 0.05) printf "failed";
    else printf "%.1f", mbps;
  }'
}

speedtest_parse_cost_ms() {
  local label="$1"
  awk -v label="$label" '
    index(tolower($0), tolower(label)) {
      value = $0
      sub(/^.*:[[:space:]]*/, "", value)
      if (match(value, /-?[0-9]+/)) {
        print substr(value, RSTART, RLENGTH)
        found = 1
        exit
      }
    }
    END { if (!found) print "-" }
  '
}

speedtest_write_probe_meta() {
  local output_file="$1" probe_type="$2" server_ip="$3" exit_code="$4" result="$5" parsed="$6" connect_ms="$7" tls_ms="$8"
  local nstat_retrans="${9:--}" tcp_info_available="${10:-0}" tcp_info_retrans="${11:--}"
  local tcp_info_data_segs_out="${12:--}" tcp_info_segs_out="${13:--}" tcp_info_bytes_retrans="${14:--}"
  local tcp_info_ratio_denominator="${15:--}" tcp_info_ratio="${16:--}" retrans_source="${17:-nstat}"
  local trace_available="${18:-0}" trace_unique_retrans="${19:--}" trace_ratio_denominator="${20:--}"
  local trace_ratio="${21:--}" tcp_info_mode="${22:-none}" trace_key="${23:-skbaddr+skaddr}"
  local trace_valid="${24:-0}" tcp_info_reason="${25:-unknown}"
  {
    printf 'probe_type=%s\n' "$probe_type"
    printf 'server_ip=%s\n' "$server_ip"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'result=%s\n' "$result"
    printf 'parsed_rate_mbps=%s\n' "$parsed"
    printf 'connect_ms=%s\n' "$connect_ms"
    printf 'tls_ms=%s\n' "$tls_ms"
    printf 'nstat_retrans=%s\n' "$nstat_retrans"
    printf 'retrans_source=%s\n' "$retrans_source"
    printf 'tcp_info_available=%s\n' "$tcp_info_available"
    printf 'tcp_info_retrans=%s\n' "$tcp_info_retrans"
    printf 'tcp_info_data_segs_out=%s\n' "$tcp_info_data_segs_out"
    printf 'tcp_info_segs_out=%s\n' "$tcp_info_segs_out"
    printf 'tcp_info_bytes_retrans=%s\n' "$tcp_info_bytes_retrans"
    printf 'tcp_info_ratio_denominator=%s\n' "$tcp_info_ratio_denominator"
    printf 'tcp_info_ratio=%s\n' "$tcp_info_ratio"
    printf 'tcp_info_mode=%s\n' "$tcp_info_mode"
    printf 'tcp_info_reason=%s\n' "$tcp_info_reason"
    printf 'retrans_trace_available=%s\n' "$trace_available"
    printf 'retrans_trace_valid=%s\n' "$trace_valid"
    printf 'retrans_trace_unique=%s\n' "$trace_unique_retrans"
    printf 'retrans_trace_ratio_denominator=%s\n' "$trace_ratio_denominator"
    printf 'retrans_trace_ratio=%s\n' "$trace_ratio"
    printf 'retrans_trace_key=%s\n' "$trace_key"
    printf 'target_host=%s\n' "$(speedtest_tos_bucket_host "$SPEEDTEST_TOS_REGION" 2>/dev/null || true)"
    printf 'pin_method=curl--resolve\n'
    printf 'region=%s\n' "$SPEEDTEST_TOS_REGION"
    printf 'network=%s\n' "$SPEEDTEST_TOS_NETWORK"
    printf 'object_size=%s\n' "$SPEEDTEST_TOS_SIZE"
    printf 'timeout=%s\n' "$SPEEDTEST_TOS_TIMEOUT"
    printf 'recorded_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "${output_file}.meta" 2>/dev/null || true
}

speedtest_tos_bucket_host() {
  local region="$1" bucket
  case "$region" in
    cn-beijing) bucket="beijing" ;;
    cn-shanghai) bucket="shanghai" ;;
    cn-guangzhou) bucket="guangzhou" ;;
    *) return 1 ;;
  esac
  printf 'probe-bucket-%s.tos-%s.volces.com' "$bucket" "$region"
}

speedtest_tos_object_size_bytes() {
  local value="${SPEEDTEST_TOS_SIZE^^}" number unit multiplier
  if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]*([KMGT]?I?B?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$unit" in
    ""|B) multiplier=1 ;;
    K|KB|KI|KIB) multiplier=1024 ;;
    M|MB|MI|MIB) multiplier=1048576 ;;
    G|GB|GI|GIB) multiplier=1073741824 ;;
    T|TB|TI|TIB) multiplier=1099511627776 ;;
    *) return 1 ;;
  esac
  awk -v number="$number" -v multiplier="$multiplier" 'BEGIN {
    bytes = number * multiplier;
    if (bytes < 1) exit 1;
    printf "%.0f", bytes;
  }'
}

speedtest_tos_upload_key() {
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{16,}$ ]]; then
    uuid="$(date +%s%N)-$RANDOM"
  fi
  printf 'upload/%s' "$uuid"
}

speedtest_curl_seconds_ms() {
  awk -v value="$1" 'BEGIN {
    if (value !~ /^[0-9]+([.][0-9]+)?$/) print "-";
    else printf "%d", value * 1000 + 0.5;
  }'
}

speedtest_curl_delta_ms() {
  awk -v start="$1" -v end="$2" 'BEGIN {
    if (start !~ /^[0-9]+([.][0-9]+)?$/ || end !~ /^[0-9]+([.][0-9]+)?$/) {
      print "-";
      exit;
    }
    delta = (end - start) * 1000;
    if (delta < 0) delta = 0;
    printf "%d", delta + 0.5;
  }'
}

speedtest_curl_rate_mbps() {
  awk -v bytes_per_second="$1" 'BEGIN {
    if (bytes_per_second !~ /^[0-9]+([.][0-9]+)?$/ || bytes_per_second <= 0) {
      print "failed";
      exit;
    }
    printf "%.2f", bytes_per_second / 1000000;
  }'
}

speedtest_zero_stream() {
  local bytes="$1" full_blocks remainder
  full_blocks=$((bytes / 1048576))
  remainder=$((bytes % 1048576))
  [ "$full_blocks" -gt 0 ] && dd if=/dev/zero bs=1048576 count="$full_blocks" 2>/dev/null
  [ "$remainder" -gt 0 ] && dd if=/dev/zero bs=1 count="$remainder" 2>/dev/null
}

speedtest_tos_delete_object() {
  local host="$1" server_ip="$2" key="$3"
  [ -n "$host" ] && [ -n "$server_ip" ] && [ -n "$key" ] || return 0
  curl -4 --noproxy '*' --http1.1 -sS -o /dev/null \
    --connect-timeout 5 --max-time 10 \
    --resolve "$host:443:$server_ip" -X DELETE \
    "https://$host/$key" >/dev/null 2>&1 || true
}

speedtest_read_sysctl() {
  local key="$1" path
  path="/proc/sys/${key//./\/}"
  if [ -r "$path" ]; then
    tr '\t' ' ' < "$path" 2>/dev/null | awk '{$1=$1; print}'
  else
    sysctl -n "$key" 2>/dev/null | tr '\t' ' ' | awk '{$1=$1; print}'
  fi
}

speedtest_qdisc_name() {
  local iface="${SPEEDTEST_IFACE:-}" root_qdisc default_qdisc
  if [ -n "$iface" ]; then
    root_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root / {print $2; exit}')
  fi
  default_qdisc=$(speedtest_read_sysctl net.core.default_qdisc)
  if [ -n "$default_qdisc" ]; then
    printf '%s' "$default_qdisc"
  elif [ -n "$root_qdisc" ] && [ "$root_qdisc" != "noqueue" ]; then
    printf '%s' "$root_qdisc"
  elif [ -n "$root_qdisc" ]; then
    printf '%s' "$root_qdisc"
  else
    printf '-'
  fi
}

speedtest_tcp_window_bytes() {
  local values="$1"
  awk -v values="$values" 'BEGIN {
    n = split(values, parts, /[[:space:]]+/);
    if (n >= 3 && parts[3] ~ /^[0-9]+$/) print parts[3];
    else print "-";
  }'
}

speedtest_min_window_bytes() {
  local tcp_max="$1" endpoint_max="$2"
  awk -v tcp_max="$tcp_max" -v endpoint_max="$endpoint_max" 'BEGIN {
    if (tcp_max ~ /^[0-9]+$/ && endpoint_max ~ /^[0-9]+$/) print (tcp_max < endpoint_max ? tcp_max : endpoint_max);
    else if (tcp_max ~ /^[0-9]+$/) print tcp_max;
    else if (endpoint_max ~ /^[0-9]+$/) print endpoint_max;
    else print "-";
  }'
}

speedtest_append_tcp_config_csv() {
  local csv="$1" cc qdisc rmem wmem rwin swin tcp_rwin tcp_swin endpoint_window window_scaling moderate_rcvbuf
  cc=$(speedtest_read_sysctl net.ipv4.tcp_congestion_control)
  qdisc=$(speedtest_qdisc_name)
  rmem=$(speedtest_read_sysctl net.ipv4.tcp_rmem)
  wmem=$(speedtest_read_sysctl net.ipv4.tcp_wmem)
  window_scaling=$(speedtest_read_sysctl net.ipv4.tcp_window_scaling)
  moderate_rcvbuf=$(speedtest_read_sysctl net.ipv4.tcp_moderate_rcvbuf)
  endpoint_window=16777216
  tcp_rwin=$(speedtest_tcp_window_bytes "$rmem")
  tcp_swin=$(speedtest_tcp_window_bytes "$wmem")
  rwin=$(speedtest_min_window_bytes "$tcp_rwin" "$endpoint_window")
  swin=$(speedtest_min_window_bytes "$tcp_swin" "$endpoint_window")
  printf '三网单线程配置,TCP,%s,%s,,,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${cc:-}" "${qdisc:-}" "OK" "${rmem:-}" "${wmem:-}" "${rwin:-}" "${swin:-}" \
    "${window_scaling:-}" "${moderate_rcvbuf:-}" >> "$csv"
}

speedtest_safe_debug_name() {
  printf '%s' "$*" | tr -c 'A-Za-z0-9_.-' '_'
}

speedtest_record_failure_debug() {
  local group_label="$1" carrier="$2" direction="$3" server_id="$4" city="$5" result_file="$6"
  local debug_dir name meta_file
  debug_dir="$RESULT_DIR/speedtest-debug"
  mkdir -p "$debug_dir" 2>/dev/null || return 0
  name=$(speedtest_safe_debug_name "${group_label}_${carrier}_${direction}_${server_id:-unknown}")
  meta_file="$debug_dir/${name}.meta.txt"
  {
    printf 'group=%s\n' "$group_label"
    printf 'carrier=%s\n' "$carrier"
    printf 'direction=%s\n' "$direction"
    printf 'server_ip=%s\n' "${server_id:-}"
    printf 'city=%s\n' "${city:-}"
    printf 'selected_region=%s\n' "$SPEEDTEST_TOS_REGION"
    printf 'saved_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ -f "${result_file}.meta" ]; then
      printf '\n[probe_meta]\n'
      cat "${result_file}.meta" 2>/dev/null || true
    fi
  } > "$meta_file" 2>/dev/null || true
  [ -f "$result_file" ] && cp "$result_file" "$debug_dir/${name}.stdout.txt" 2>/dev/null || true
  [ -f "${result_file}.err" ] && cp "${result_file}.err" "$debug_dir/${name}.stderr.txt" 2>/dev/null || true
}

speedtest_record_manual_failure_debug() {
  local group_label="$1" carrier="$2" server_id="$3" city="$4" reason="$5"
  local debug_dir name
  debug_dir="$RESULT_DIR/speedtest-debug"
  mkdir -p "$debug_dir" 2>/dev/null || return 0
  name=$(speedtest_safe_debug_name "${group_label}_${carrier}_setup_${server_id:-unknown}")
  {
    printf 'group=%s\n' "$group_label"
    printf 'carrier=%s\n' "$carrier"
    printf 'server_ip=%s\n' "${server_id:-}"
    printf 'city=%s\n' "${city:-}"
    printf 'selected_region=%s\n' "$SPEEDTEST_TOS_REGION"
    printf 'reason=%s\n' "$reason"
    printf 'saved_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$debug_dir/${name}.meta.txt" 2>/dev/null || true
}

speedtest_run_probe() {
  local probe_type="$1" output_file="$2" server_ip="$3"
  local before after nstat_retrans retrans start_bytes end_bytes start_packets end_packets packet_delta delta_bytes counter_enabled
  local host key size timeout meta raw_file exit_code result parsed transfer_bytes partial_timeout probe_pid
  local tcp_info_file tcp_info_available=0 tcp_info_retrans=0
  local tcp_info_data_segs_out=0 tcp_info_segs_out=0 tcp_info_bytes_retrans=0 tcp_info_ratio="-"
  local tcp_info_ratio_denominator=0 retrans_source="nstat"
  local tcp_info_mode="none" tcp_info_reason="unknown" trace_unique_retrans=0 trace_ratio="-" trace_available=0 trace_valid=0
  local http_code bytes_download speed_download bytes_upload speed_upload
  local dns_time connect_time appconnect_time pretransfer_time starttransfer_time total_time remote_ip
  local dns_ms build_ms send_ms wait_ms total_ms rate_bytes_per_second rate_mb display_connect_ms display_tls_ms
  local reported_connect_ms reported_tls_ms
  local tcp_info_preload="" preload_value
  local -a curl_args

  host=$(speedtest_tos_bucket_host "$SPEEDTEST_TOS_REGION" 2>/dev/null || true)
  size=$(speedtest_tos_object_size_bytes 2>/dev/null || true)
  timeout="$SPEEDTEST_TOS_TIMEOUT"
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=15
  raw_file="${output_file}.curl"
  key=""

  if [ -z "$host" ] || ! [[ "$server_ip" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || [ -z "$size" ] || [ "$size" -le 0 ] || [ "$SPEEDTEST_TOS_NETWORK" != "public" ]; then
    printf 'Average %s rate: failed\n\nTime consuming details\n' "$probe_type" > "$output_file"
    printf 'Build connection cost: -1 ms\nTls handshake cost: -1 ms\n' >> "$output_file"
    : > "${output_file}.err"
    speedtest_write_probe_meta "$output_file" "$probe_type" "$server_ip" 2 failed failed -1 -1
    printf 'failed|0|-1|-1'
    return 0
  fi

  curl_args=(
    curl -4 --noproxy '*' --http1.1 -sS --fail
    --connect-timeout 5 --max-time "$timeout"
    --resolve "$host:443:$server_ip"
    -A 'TcpQuality fixed TOS probe'
    -w '%{http_code}|%{size_download}|%{speed_download}|%{size_upload}|%{speed_upload}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{remote_ip}'
    -o /dev/null
  )
  if [ "$probe_type" = "upload" ]; then
    key=$(speedtest_tos_upload_key)
    curl_args+=(
      -X PUT -H "Content-Length: $size" --upload-file -
      "https://$host/$key"
    )
  else
    curl_args+=(
      --range "0-$((size - 1))"
      "https://$host/download/test"
    )
  fi

  counter_enabled=0
  if speedtest_counter_start "$probe_type" "$server_ip"; then
    counter_enabled=1
    start_bytes=$(speedtest_counter_bytes)
    start_packets=$(speedtest_counter_packets)
  else
    SPEEDTEST_RANK_ELIGIBLE=0
    SPEEDTEST_RANK_DISABLED_REASON="target_counter_unavailable"
    start_bytes=$(speedtest_net_bytes "$probe_type")
    start_packets="-"
  fi
  before=$(speedtest_retrans_count)
  tcp_info_file="${output_file}.tcpinfo"
  speedtest_tcp_info_monitor_start "$server_ip" "$tcp_info_file" "-4" || true
  tcp_info_mode="${SPEEDTEST_TCP_INFO_ACTIVE_MODE:-none}"
  tcp_info_preload="${SPEEDTEST_TCP_INFO_ACTIVE_PRELOAD:-}"
  if [ "$tcp_info_mode" = "getsockopt" ] && [ -n "$tcp_info_preload" ]; then
    preload_value="$tcp_info_preload"
    [ -n "${LD_PRELOAD:-}" ] && preload_value="$preload_value:$LD_PRELOAD"
    curl_args=(
      env
      "LD_PRELOAD=$preload_value"
      "TCPQUALITY_TCP_INFO_FILE=$tcp_info_file"
      "TCPQUALITY_TCP_INFO_TARGET=$server_ip"
      "${curl_args[@]}"
    )
  fi
  if speedtest_retrans_trace_start "$output_file"; then
    trace_available=1
  fi
  set +e
  if [ "$probe_type" = "upload" ]; then
    (
      set +e
      speedtest_zero_stream "$size" | "${curl_args[@]}" > "$raw_file" 2>"${output_file}.err"
      pipeline_status=("${PIPESTATUS[@]}")
      exit "${pipeline_status[1]:-1}"
    ) &
    probe_pid=$!
  else
    (
      set +e
      "${curl_args[@]}" > "$raw_file" 2>"${output_file}.err"
    ) &
    probe_pid=$!
  fi
  wait "$probe_pid"
  exit_code=$?
  set -e
  speedtest_tcp_info_monitor_stop
  speedtest_retrans_trace_stop
  if [ "$trace_available" -ne 1 ] || [ "${SPEEDTEST_RETRANS_TRACE_READY:-0}" -ne 1 ]; then
    trace_available=0
  fi
  if [ -s "$tcp_info_file" ]; then
    IFS='|' read -r tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans < "$tcp_info_file" || true
    if [[ "$tcp_info_retrans" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_data_segs_out" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_segs_out" =~ ^[0-9]+$ ]] &&
       [[ "$tcp_info_bytes_retrans" =~ ^[0-9]+$ ]]; then
      tcp_info_available=1
      if [ "$tcp_info_data_segs_out" -gt 0 ]; then
        tcp_info_ratio_denominator="$tcp_info_data_segs_out"
      else
        tcp_info_ratio_denominator="$tcp_info_segs_out"
      fi
      tcp_info_ratio=$(awk -v retrans="$tcp_info_retrans" -v packets="$tcp_info_ratio_denominator" 'BEGIN {
        if (packets <= 0) print "-";
        else {
          ratio = retrans / packets * 100;
          if (ratio < 0) ratio = 0;
          if (ratio > 100) ratio = 100;
          printf "%.2f%%", ratio;
        }
      }')
    fi
  fi
  if [ "$tcp_info_available" -eq 1 ]; then
    tcp_info_reason="ok"
  elif [ "$tcp_info_mode" = "getsockopt" ]; then
    tcp_info_reason="getsockopt_no_valid_snapshot"
  elif [ "$tcp_info_mode" = "ss" ]; then
    tcp_info_reason="ss_no_valid_snapshot"
  else
    tcp_info_reason="${SPEEDTEST_TCP_INFO_FAILURE_REASON:-monitor_not_started}"
  fi
  if [ "$trace_available" -eq 1 ]; then
    trace_unique_retrans=$(speedtest_retrans_trace_count_ipv4 "$SPEEDTEST_RETRANS_TRACE_FILE" "$server_ip" 2>/dev/null || true)
    if [[ "$trace_unique_retrans" =~ ^[0-9]+$ ]] && [ "$tcp_info_available" -eq 1 ]; then
      if [ "$trace_unique_retrans" -gt 0 ] && [ "$trace_unique_retrans" -le "$tcp_info_retrans" ]; then
        trace_ratio_denominator=$(awk -v packets="$tcp_info_ratio_denominator" -v retrans="$tcp_info_retrans" 'BEGIN {
          if (packets !~ /^[0-9]+$/ || retrans !~ /^[0-9]+$/ || packets <= 0) print 0;
          else {
            value = packets - retrans;
            if (value <= 0) value = packets;
            print value;
          }
        }')
        trace_ratio=$(speedtest_unique_retrans_percent "$trace_unique_retrans" "$tcp_info_ratio_denominator" "$tcp_info_retrans")
        if [ "$trace_ratio" != "-" ]; then
          trace_valid=1
        fi
      else
        # A successfully attached trace can still be unusable when the
        # kernel/BTF layout makes seq/end_seq unreadable. Never let that
        # synthetic zero count override the socket-level TCP_INFO result.
        trace_ratio_denominator="-"
        trace_ratio="-"
      fi
    fi
  fi
  if [ "$counter_enabled" -eq 1 ]; then
    end_bytes=$(speedtest_counter_bytes)
    end_packets=$(speedtest_counter_packets)
    if [ "$start_bytes" = "-" ] || [ "$end_bytes" = "-" ]; then
      SPEEDTEST_RANK_ELIGIBLE=0
      SPEEDTEST_RANK_DISABLED_REASON="target_counter_read_failed"
    fi
  else
    end_bytes=$(speedtest_net_bytes "$probe_type")
    end_packets="-"
  fi
  speedtest_counter_stop_current
  after=$(speedtest_retrans_count)
  nstat_retrans=$((after - before))
  [ "$nstat_retrans" -ge 0 ] || nstat_retrans=0
  retrans="$nstat_retrans"
  if [ "$tcp_info_available" -eq 1 ]; then
    if [ "$trace_available" -eq 1 ] && [ "$trace_valid" -eq 1 ] && [ "$trace_ratio" != "-" ]; then
      retrans="$trace_ratio"
      if [ "$SPEEDTEST_RETRANS_TRACE_KEY" = "seq" ]; then
        retrans_source="ebpf_seq"
      else
        retrans_source="ebpf_skb"
      fi
    else
      retrans="$tcp_info_ratio"
      retrans_source="tcp_info_${tcp_info_mode}"
    fi
  else
    # nstat is host-global and cannot be attributed to this connection. Never
    # turn it into a percentage when the connection-level sample is missing.
    retrans="-"
    retrans_source="tcp_info_unavailable"
  fi

  meta=$(cat "$raw_file" 2>/dev/null || true)
  IFS='|' read -r http_code bytes_download speed_download bytes_upload speed_upload \
    dns_time connect_time appconnect_time pretransfer_time starttransfer_time total_time remote_ip <<< "$meta"
  dns_ms=$(speedtest_curl_seconds_ms "$dns_time")
  build_ms=$(speedtest_curl_delta_ms "$dns_time" "$connect_time")
  tls_ms=$(speedtest_curl_delta_ms "$connect_time" "$appconnect_time")
  total_ms=$(speedtest_curl_seconds_ms "$total_time")
  if [ "$probe_type" = "upload" ]; then
    wait_ms=0
    send_ms=$(speedtest_curl_delta_ms "$pretransfer_time" "$total_time")
    rate_bytes_per_second="${speed_upload:-0}"
    transfer_bytes="${bytes_upload:-0}"
  else
    send_ms=0
    wait_ms=$(speedtest_curl_delta_ms "$pretransfer_time" "$starttransfer_time")
    rate_bytes_per_second="${speed_download:-0}"
    transfer_bytes="${bytes_download:-0}"
  fi
  partial_timeout=0
  if speedtest_curl_partial_timeout_valid "$exit_code" "$total_time" "$timeout" "$transfer_bytes"; then
    partial_timeout=1
    # 达到 max-time 但未完成时，明确使用完整运行时长计算平均速率。
    rate_bytes_per_second=$(speedtest_curl_average_rate "$transfer_bytes" "$total_time")
  fi
  rate_mb=$(speedtest_curl_rate_mbps "$rate_bytes_per_second")
  {
    if [ "$rate_mb" = "failed" ]; then
      printf 'Average %s rate: failed\n' "$probe_type"
    else
      printf 'Average %s rate: %sMB/s\n' "$probe_type" "$rate_mb"
    fi
    printf '\nTime consuming details\n'
    printf 'Resolve dns cost: %s ms\n' "$dns_ms"
    printf 'Build connection cost: %s ms\n' "$build_ms"
    printf 'Tls handshake cost: %s ms\n' "$tls_ms"
    printf 'Send request cost: %s ms\n' "$send_ms"
    printf 'Wait response cost: %s ms\n' "$wait_ms"
    printf 'Total cost: %s ms\n' "$total_ms"
    printf 'Fixed target: %s (%s)\n' "$server_ip" "${remote_ip:-unknown}"
  } > "$output_file"

  parsed=$(speedtest_parse_rate_mbps < "$output_file" || true)
  result="$parsed"
  # 达到 max-time 且已传输数据属于有效的时间窗口样本；连接阶段超时、
  # 连接重置和其他非零退出码仍然判定为失败。
  if [ "$parsed" = "failed" ]; then
    result="failed"
  elif [ "$exit_code" -eq 0 ]; then
    ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && result="failed"
  elif [ "$partial_timeout" -ne 1 ]; then
    result="failed"
  fi

  if [ "$result" = "failed" ]; then
    # 失败方向没有有效的目标重传/延迟数据；nstat 是主机全局计数，不能作为该方向的结果。
    retrans="failed"
    reported_connect_ms="failed"
    reported_tls_ms="failed"
    sed -i \
      -e "s/^Average ${probe_type} rate: .*/Average ${probe_type} rate: failed/" \
      -e 's/^Build connection cost: .*/Build connection cost: failed/' \
      -e 's/^Tls handshake cost: .*/Tls handshake cost: failed/' \
      "$output_file"
  else
    reported_connect_ms="$build_ms"
    reported_tls_ms="$tls_ms"
  fi

  if [ "$counter_enabled" -eq 1 ]; then
    if [ "$start_bytes" = "-" ] || [ "$end_bytes" = "-" ]; then
      SPEEDTEST_RANK_ELIGIBLE=0
      SPEEDTEST_RANK_DISABLED_REASON="target_counter_read_failed"
    else
      delta_bytes=$((end_bytes - start_bytes))
      if [ "$delta_bytes" -le 0 ]; then
        SPEEDTEST_RANK_ELIGIBLE=0
        SPEEDTEST_RANK_DISABLED_REASON="target_counter_zero"
      fi
    fi
  fi

  if [ "$probe_type" = "upload" ] && [ -n "$key" ]; then
    speedtest_tos_delete_object "$host" "$server_ip" "$key"
  fi
  speedtest_write_probe_meta "$output_file" "$probe_type" "$server_ip" "$exit_code" "${result:-failed}" "${parsed:-failed}" "$reported_connect_ms" "$reported_tls_ms" \
    "$nstat_retrans" "$tcp_info_available" "$tcp_info_retrans" "$tcp_info_data_segs_out" \
    "$tcp_info_segs_out" "$tcp_info_bytes_retrans" "$tcp_info_ratio_denominator" "$tcp_info_ratio" "$retrans_source" \
    "$trace_available" "$trace_unique_retrans" "$trace_ratio_denominator" "$trace_ratio" "$tcp_info_mode" \
    "$( [ "$SPEEDTEST_RETRANS_TRACE_KEY" = "seq" ] && printf 'skaddr+seq+end_seq' || printf 'skaddr+skbaddr' )" \
    "$trace_valid" "$tcp_info_reason"
  rm -f "$raw_file"
  [ "${DEBUG_MODE:-0}" -eq 1 ] || rm -f "$tcp_info_file" "${tcp_info_file}.tmp" \
    "$SPEEDTEST_RETRANS_TRACE_FILE" "$SPEEDTEST_RETRANS_TRACE_ERR"
  display_connect_ms="$reported_connect_ms"
  display_tls_ms="$reported_tls_ms"
  # CSV/SVG 的现有兼容层会将连接/TLS字段除以 2；连接耗时保持旧兼容口径，
  # TLS 耗时保留原始 curl 值，使报告中的 TLS 延迟显示为握手耗时的一半。
  [[ "$display_connect_ms" =~ ^[0-9]+$ ]] && display_connect_ms=$((display_connect_ms * 2))
  printf '%s|%s|%s|%s' "${result:-failed}" "$retrans" "$display_connect_ms" "$display_tls_ms"
  return 0
}

speedtest_applecdn_timeout() {
  local timeout="$SPEEDTEST_TOS_TIMEOUT"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
    timeout=15
  fi
  printf '%s' "$timeout"
}

speedtest_applecdn_max_mb() {
  local max_mb="$SPEEDTEST_APPLECDN_MAX_MB"
  if ! [[ "$max_mb" =~ ^[0-9]+$ ]] || [ "$max_mb" -le 0 ]; then
    max_mb=2048
  fi
  printf '%s' "$max_mb"
}

speedtest_applecdn_calc_mbps() {
  local bytes_per_second="$1"
  awk -v bps="$bytes_per_second" 'BEGIN {
    if (bps <= 0) {
      printf "failed";
      exit;
    }
    mbps = bps * 8 / 1000000;
    if (mbps < 0.05) printf "failed";
    else printf "%.1f", mbps;
  }'
}

speedtest_applecdn_seconds_to_ms() {
  local seconds="$1"
  awk -v s="$seconds" 'BEGIN {
    if (s <= 0) printf "-";
    else printf "%d", int(s * 1000 + 0.5);
  }'
}

speedtest_ipv4_available() {
  ip -4 route get 17.253.144.10 >/dev/null 2>&1
}

speedtest_ipv6_available() {
  local response
  if [ "$SPEEDTEST_IPV6_CHECKED" -eq 1 ]; then
    [ "$SPEEDTEST_IPV6_AVAILABLE" -eq 1 ]
    return
  fi
  SPEEDTEST_IPV6_CHECKED=1
  SPEEDTEST_IPV6_AVAILABLE=0
  if ipv6_available; then
    SPEEDTEST_IPV6_AVAILABLE=1
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 1
  response=$(curl -6 -fsS --connect-timeout 5 --max-time 8 \
    "$SPEEDTEST_IPV6_PROBE_URL" 2>/dev/null | \
    awk 'NR == 1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
  if is_valid_ipv6 "$response"; then
    IPV6_PUBLIC="$response"
    IPV6_WORK=1
    SPEEDTEST_IPV6_AVAILABLE=1
    return 0
  fi
  return 1
}

speedtest_applecdn_curl_download() {
  local output_file="$1" ip_flag="$2" fixed_ip="${3:-}" strict_mode="${4:-0}" timeout meta exit_code http_code bytes total curl_speed connect appconnect starttransfer remote_ip
  local before after retrans speed latency partial_timeout=0
  local direction_failed=0
  local target_specific=1 tcp_info_file="" tcp_info_final="" tcp_info_monitor_started=0 tcp_info_snapshot_value
  local tcp_info_metrics tcp_info_ratio="-" tcp_info_retrans="-" tcp_info_data_segs_out="-" tcp_info_segs_out="-" tcp_info_bytes_retrans="-"
  local retrans_source="nstat"
  local -a resolve_args=()
  timeout=$(speedtest_applecdn_timeout)
  # Apple CDN retransmissions must be attributed to this connection. Pin
  # both address families to one resolved endpoint before starting ss.
  if [ "$ip_flag" = "-6" ]; then
    if [ -z "$fixed_ip" ]; then
      fixed_ip=$(resolve_first_public_ipv6 "$SPEEDTEST_APPLECDN_HOST" 2>/dev/null || true)
    fi
    [ -n "$fixed_ip" ] && resolve_args=(--resolve "$SPEEDTEST_APPLECDN_HOST:443:[$fixed_ip]")
    if is_valid_ipv6 "$fixed_ip"; then
      tcp_info_file="${output_file}.tcpinfo"
      tcp_info_final="${tcp_info_file}.final"
      if speedtest_tcp_info_monitor_start "$fixed_ip" "$tcp_info_file" "-6" 1; then
        tcp_info_monitor_started=1
      fi
    fi
  else
    if [ -z "$fixed_ip" ]; then
      fixed_ip=$(resolve_first_public_ipv4 "$SPEEDTEST_APPLECDN_HOST" 2>/dev/null || true)
    fi
    [ -n "$fixed_ip" ] && resolve_args=(--resolve "$SPEEDTEST_APPLECDN_HOST:443:$fixed_ip")
    if is_public_ipv4 "$fixed_ip"; then
      tcp_info_file="${output_file}.tcpinfo"
      tcp_info_final="${tcp_info_file}.final"
      if speedtest_tcp_info_monitor_start "$fixed_ip" "$tcp_info_file" "-4" 1; then
        tcp_info_monitor_started=1
      fi
    fi
  fi
  before=0
  set +e
  meta=$(curl "$ip_flag" -sS -L \
    --connect-timeout 5 --max-time "$timeout" \
    "${resolve_args[@]}" \
    -A "$SPEEDTEST_APPLECDN_USER_AGENT" \
    -H 'Accept: */*' \
    -H 'Accept-Language: zh-CN,zh-Hans;q=0.9' \
    -H 'Accept-Encoding: identity' \
    -o /dev/null \
    -w '%{size_download}|%{time_total}|%{speed_download}|%{remote_ip}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{http_code}' \
    "$SPEEDTEST_APPLECDN_DOWNLOAD_URL" 2>"${output_file}.err")
  exit_code=$?
  set -e
  if [ "$tcp_info_monitor_started" -eq 1 ]; then
    tcp_info_snapshot_value=$(speedtest_tcp_info_ss_snapshot "$fixed_ip" "$ip_flag" 2>/dev/null || true)
    if [ -n "$tcp_info_snapshot_value" ]; then
      printf '%s\n' "$tcp_info_snapshot_value" > "$tcp_info_final" 2>/dev/null || true
    fi
    speedtest_tcp_info_monitor_stop
    if [ -s "$tcp_info_final" ]; then
      mv -f "$tcp_info_final" "$tcp_info_file"
    fi
    tcp_info_monitor_started=0
  fi
  if [ "$target_specific" -eq 1 ]; then
    tcp_info_metrics=""
    if [ -n "$tcp_info_file" ]; then
      tcp_info_metrics=$(speedtest_tcp_info_metrics "$tcp_info_file" 2>/dev/null || true)
    fi
    if [ -n "$tcp_info_metrics" ]; then
      IFS='|' read -r tcp_info_ratio tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans <<<"$tcp_info_metrics"
      retrans="$tcp_info_ratio"
      retrans_source="tcp_info_ss"
    else
      retrans="-"
      retrans_source="tcp_info_unavailable"
    fi
  else
    after=$(speedtest_retrans_count)
    retrans=$((after - before))
    [ "$retrans" -ge 0 ] || retrans=0
  fi
  IFS='|' read -r bytes total curl_speed remote_ip connect appconnect starttransfer http_code <<<"$meta"
  if [ "$strict_mode" = "1" ] &&
     speedtest_curl_partial_timeout_valid "$exit_code" "$total" "$timeout" "${bytes:-0}"; then
    partial_timeout=1
    curl_speed=$(speedtest_curl_average_rate "${bytes:-0}" "$total")
  fi
  speed=$(speedtest_applecdn_calc_mbps "${curl_speed:-0}")
  latency=$(speedtest_applecdn_seconds_to_ms "${appconnect:-0}")
  [ "$latency" = "-" ] && latency=$(speedtest_applecdn_seconds_to_ms "${starttransfer:-0}")
  if [ "$speed" = "failed" ]; then
    direction_failed=1
  elif [ "$strict_mode" = "1" ]; then
    if [ "$exit_code" -eq 0 ]; then
      if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        direction_failed=1
      fi
    elif [ "$partial_timeout" -ne 1 ]; then
      direction_failed=1
    fi
  elif [ "$exit_code" -ne 0 ] && [ "${bytes:-0}" -le 0 ] 2>/dev/null; then
    direction_failed=1
  fi
  if [ "$direction_failed" -eq 1 ]; then
    printf 'failed|%s|%s|%s' "$retrans" "$(speedtest_applecdn_seconds_to_ms "${connect:-0}")" "$latency"
  else
    printf '%s|%s|%s|%s' "$speed" "$retrans" "$(speedtest_applecdn_seconds_to_ms "${connect:-0}")" "$latency"
  fi
  {
    printf 'type=download\n'
    printf 'exit_code=%s\n' "$exit_code"
    printf 'http_code=%s\n' "${http_code:-}"
    printf 'remote_ip=%s\n' "${remote_ip:-}"
    printf 'bytes=%s\n' "${bytes:-}"
    printf 'time_total=%s\n' "${total:-}"
    printf 'speed_download=%s\n' "${curl_speed:-}"
    printf 'time_connect=%s\n' "${connect:-}"
    printf 'time_appconnect=%s\n' "${appconnect:-}"
    printf 'time_starttransfer=%s\n' "${starttransfer:-}"
    printf 'fixed_ip=%s\n' "${fixed_ip:-}"
    printf 'retrans=%s\n' "$retrans"
    printf 'retrans_source=%s\n' "$retrans_source"
    printf 'tcp_info_retrans=%s\n' "$tcp_info_retrans"
    printf 'tcp_info_data_segs_out=%s\n' "$tcp_info_data_segs_out"
    printf 'tcp_info_segs_out=%s\n' "$tcp_info_segs_out"
    printf 'tcp_info_bytes_retrans=%s\n' "$tcp_info_bytes_retrans"
    printf 'tcp_info_ratio=%s\n' "$tcp_info_ratio"
  } > "${output_file}.meta.txt" 2>/dev/null || true
  printf '%s\n' "$meta" > "$output_file" 2>/dev/null || true
}

speedtest_applecdn_curl_upload() {
  local output_file="$1" ip_flag="$2" fixed_ip="${3:-}" ratio_mode="${4:-0}" timeout max_mb meta exit_code http_code bytes total curl_speed connect appconnect starttransfer remote_ip
  local before after retrans speed latency partial_timeout=0 partial_http=0
  local counter_enabled=0 start_packets="-" end_packets="-" packet_delta direction_failed=0
  local target_specific=1 tcp_info_file="" tcp_info_final="" tcp_info_monitor_started=0 tcp_info_snapshot_value
  local tcp_info_metrics tcp_info_ratio="-" tcp_info_retrans="-" tcp_info_data_segs_out="-" tcp_info_segs_out="-" tcp_info_bytes_retrans="-"
  local retrans_source="nstat"
  local -a resolve_args=()
  timeout=$(speedtest_applecdn_timeout)
  max_mb=$(speedtest_applecdn_max_mb)
  # Apple CDN retransmissions must be attributed to this connection. Pin
  # both address families to one resolved endpoint before starting ss.
  if [ "$ip_flag" = "-6" ]; then
    if [ -z "$fixed_ip" ]; then
      fixed_ip=$(resolve_first_public_ipv6 "$SPEEDTEST_APPLECDN_HOST" 2>/dev/null || true)
    fi
    [ -n "$fixed_ip" ] && resolve_args=(--resolve "$SPEEDTEST_APPLECDN_HOST:443:[$fixed_ip]")
    if is_valid_ipv6 "$fixed_ip"; then
      tcp_info_file="${output_file}.tcpinfo"
      tcp_info_final="${tcp_info_file}.final"
      if speedtest_tcp_info_monitor_start "$fixed_ip" "$tcp_info_file" "-6" 1; then
        tcp_info_monitor_started=1
      fi
    fi
  else
    if [ -z "$fixed_ip" ]; then
      fixed_ip=$(resolve_first_public_ipv4 "$SPEEDTEST_APPLECDN_HOST" 2>/dev/null || true)
    fi
    [ -n "$fixed_ip" ] && resolve_args=(--resolve "$SPEEDTEST_APPLECDN_HOST:443:$fixed_ip")
    if is_public_ipv4 "$fixed_ip"; then
      tcp_info_file="${output_file}.tcpinfo"
      tcp_info_final="${tcp_info_file}.final"
      if speedtest_tcp_info_monitor_start "$fixed_ip" "$tcp_info_file" "-4" 1; then
        tcp_info_monitor_started=1
      fi
    fi
  fi
  if [ "$ratio_mode" = "1" ] && [ "$target_specific" -eq 0 ] && [ -n "$fixed_ip" ] && speedtest_counter_start upload "$fixed_ip"; then
    counter_enabled=1
    start_packets=$(speedtest_counter_packets)
  fi
  before=0
  set +e
  meta=$(
    dd if=/dev/zero bs=1M count="$max_mb" 2>/dev/null | \
      curl "$ip_flag" -sS -L \
        --connect-timeout 5 --max-time "$timeout" \
        "${resolve_args[@]}" \
        -T - \
        -A "$SPEEDTEST_APPLECDN_USER_AGENT" \
        -H 'Accept: */*' \
        -H 'Accept-Language: zh-CN,zh-Hans;q=0.9' \
        -H 'Accept-Encoding: identity' \
        -H 'Upload-Draft-Interop-Version: 6' \
        -H 'Upload-Complete: ?1' \
        -o /dev/null \
        -w '%{size_upload}|%{time_total}|%{speed_upload}|%{remote_ip}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{http_code}' \
        "$SPEEDTEST_APPLECDN_UPLOAD_URL" 2>"${output_file}.err"
  )
  exit_code=$?
  set -e
  if [ "$tcp_info_monitor_started" -eq 1 ]; then
    tcp_info_snapshot_value=$(speedtest_tcp_info_ss_snapshot "$fixed_ip" "$ip_flag" 2>/dev/null || true)
    if [ -n "$tcp_info_snapshot_value" ]; then
      printf '%s\n' "$tcp_info_snapshot_value" > "$tcp_info_final" 2>/dev/null || true
    fi
    speedtest_tcp_info_monitor_stop
    if [ -s "$tcp_info_final" ]; then
      mv -f "$tcp_info_final" "$tcp_info_file"
    fi
    tcp_info_monitor_started=0
  fi
  if [ "$counter_enabled" -eq 1 ]; then
    end_packets=$(speedtest_counter_packets)
  fi
  speedtest_counter_stop_current
  if [ "$target_specific" -eq 1 ]; then
    tcp_info_metrics=""
    if [ -n "$tcp_info_file" ]; then
      tcp_info_metrics=$(speedtest_tcp_info_metrics "$tcp_info_file" 2>/dev/null || true)
    fi
    if [ -n "$tcp_info_metrics" ]; then
      IFS='|' read -r tcp_info_ratio tcp_info_retrans tcp_info_data_segs_out tcp_info_segs_out tcp_info_bytes_retrans <<<"$tcp_info_metrics"
      retrans="$tcp_info_ratio"
      retrans_source="tcp_info_ss"
    else
      retrans="-"
      retrans_source="tcp_info_unavailable"
    fi
  else
    after=$(speedtest_retrans_count)
    retrans=$((after - before))
    [ "$retrans" -ge 0 ] || retrans=0
    if [ "$ratio_mode" = "1" ]; then
      if [ "$counter_enabled" -eq 1 ] &&
         [[ "$start_packets" =~ ^[0-9]+$ ]] && [[ "$end_packets" =~ ^[0-9]+$ ]]; then
        packet_delta=$((end_packets - start_packets))
        retrans=$(speedtest_retrans_percent "$retrans" "$packet_delta")
      else
        retrans="-"
      fi
    fi
  fi
  IFS='|' read -r bytes total curl_speed remote_ip connect appconnect starttransfer http_code <<<"$meta"
  if [ "$ratio_mode" = "1" ] &&
     speedtest_curl_partial_timeout_valid "$exit_code" "$total" "$timeout" "${bytes:-0}"; then
    partial_timeout=1
    curl_speed=$(speedtest_curl_average_rate "${bytes:-0}" "$total")
  fi
  if [ "$ratio_mode" = "1" ] &&
     speedtest_curl_partial_http_valid "$http_code" "$total" "${bytes:-0}"; then
    partial_http=1
    # Apple CDN may reject the remaining body with 413 after accepting a
    # substantial prefix. Keep that measured prefix as a valid throughput
    # sample instead of reporting a false direction failure.
    curl_speed=$(speedtest_curl_average_rate "${bytes:-0}" "$total")
  fi
  speed=$(speedtest_applecdn_calc_mbps "${curl_speed:-0}")
  latency=$(speedtest_applecdn_seconds_to_ms "${appconnect:-0}")
  [ "$latency" = "-" ] && latency=$(speedtest_applecdn_seconds_to_ms "${starttransfer:-0}")
  if [ "$speed" = "failed" ]; then
    direction_failed=1
  elif [ "$ratio_mode" = "1" ]; then
    if [ "$partial_http" -eq 1 ]; then
      :
    elif [ "$exit_code" -eq 0 ]; then
      if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        direction_failed=1
      fi
    elif [ "$partial_timeout" -ne 1 ]; then
      direction_failed=1
    fi
  elif [ "$exit_code" -ne 0 ] && [ "${bytes:-0}" -le 0 ] 2>/dev/null; then
    direction_failed=1
  fi
  if [ "$direction_failed" -eq 1 ]; then
    printf 'failed|%s|%s|%s' "$retrans" "$(speedtest_applecdn_seconds_to_ms "${connect:-0}")" "$latency"
  else
    printf '%s|%s|%s|%s' "$speed" "$retrans" "$(speedtest_applecdn_seconds_to_ms "${connect:-0}")" "$latency"
  fi
  {
    printf 'type=upload\n'
    printf 'exit_code=%s\n' "$exit_code"
    printf 'http_code=%s\n' "${http_code:-}"
    printf 'remote_ip=%s\n' "${remote_ip:-}"
    printf 'bytes=%s\n' "${bytes:-}"
    printf 'time_total=%s\n' "${total:-}"
    printf 'speed_upload=%s\n' "${curl_speed:-}"
    printf 'time_connect=%s\n' "${connect:-}"
    printf 'time_appconnect=%s\n' "${appconnect:-}"
    printf 'time_starttransfer=%s\n' "${starttransfer:-}"
    printf 'fixed_ip=%s\n' "${fixed_ip:-}"
    printf 'retrans=%s\n' "$retrans"
    printf 'retrans_source=%s\n' "$retrans_source"
    printf 'tcp_info_retrans=%s\n' "$tcp_info_retrans"
    printf 'tcp_info_data_segs_out=%s\n' "$tcp_info_data_segs_out"
    printf 'tcp_info_segs_out=%s\n' "$tcp_info_segs_out"
    printf 'tcp_info_bytes_retrans=%s\n' "$tcp_info_bytes_retrans"
    printf 'tcp_info_ratio=%s\n' "$tcp_info_ratio"
    if [ "$partial_http" -eq 1 ]; then
      printf 'result_mode=partial_http_413\n'
    else
      printf 'result_mode=complete\n'
    fi
  } > "${output_file}.meta.txt" 2>/dev/null || true
  printf '%s\n' "$meta" > "$output_file" 2>/dev/null || true
}

speedtest_collect_applecdn() {
  local workdir result_file family_name ip_flag download download_retrans download_connect download_tls upload upload_retrans upload_connect upload_tls
  local apple_values=()
  local apple_families=("Apple IPv4:-4")
  speedtest_applecdn_tests_enabled || return 0
  if speedtest_applecdn6_tests_enabled; then
    apple_families+=("Apple IPv6:-6")
  fi
  for family_name in "${apple_families[@]}"; do
    ip_flag="${family_name##*:}"
    family_name="${family_name%%:*}"
    if [ "$ip_flag" = "-4" ] && ! speedtest_ipv4_available; then
      apple_values+=("-|-|-|$SPEEDTEST_APPLECDN_HOST|$family_name|-|-|-|-")
      continue
    fi
    workdir=$(mktemp -d "$RESULT_DIR/speedtest-applecdn.XXXXXX")
    result_file="$workdir/result"
    IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_applecdn_curl_download "$result_file.download" "$ip_flag")"
    IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_applecdn_curl_upload "$result_file.upload" "$ip_flag")"

    [ "$download" = "failed" ] && speedtest_record_failure_debug "AppleCDN" "$family_name" "download" "$SPEEDTEST_APPLECDN_HOST" "$family_name" "$result_file.download"
    [ "$upload" = "failed" ] && speedtest_record_failure_debug "AppleCDN" "$family_name" "upload" "$SPEEDTEST_APPLECDN_HOST" "$family_name" "$result_file.upload"

    if speedtest_result_valid "$upload" || speedtest_result_valid "$download"; then
      apple_values+=("$(speedtest_format_mbps "$upload")|$download_retrans|$(speedtest_format_mbps "$download")|$SPEEDTEST_APPLECDN_HOST|$family_name|$upload_connect|$upload_tls|$download_connect|$download_tls")
    else
      apple_values+=("failed|failed|failed|$SPEEDTEST_APPLECDN_HOST|$family_name|$upload_connect|$upload_tls|$download_connect|$download_tls")
    fi
    [ "${DEBUG_MODE:-0}" -eq 1 ] || rm -rf "$workdir"
  done
  SPEEDTEST_ROWS+=("AppleCDN;${apple_values[0]};${apple_values[1]:-};")
}

speedtest_collect_applecdn6() {
  local node label candidates candidate workdir result_file
  local download download_retrans download_connect download_tls upload upload_retrans upload_connect upload_tls
  local node_value partial_node_value candidate_value selected_ip
  local candidate_valid_count partial_valid_count
  local values=()
  speedtest_applecdn6_tests_enabled || return 0
  load_remote_applecdn6_nodes || true

  for node in "${SPEEDTEST_APPLECDN6_NODES[@]}"; do
    label="${node%%|*}"
    candidates="${node#*|}"
    node_value=""
    partial_node_value=""
    selected_ip=""
    partial_valid_count=0
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      workdir=$(mktemp -d "$RESULT_DIR/speedtest-applecdn6.XXXXXX")
      result_file="$workdir/result"
      IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_applecdn_curl_download "$result_file.download" "-6" "$candidate" 1)"
      IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_applecdn_curl_upload "$result_file.upload" "-6" "$candidate" 1)"

      [ "$download" = "failed" ] && speedtest_record_failure_debug "IPv6" "$label" "download" "$candidate" "$label" "$result_file.download"
      [ "$upload" = "failed" ] && speedtest_record_failure_debug "IPv6" "$label" "upload" "$candidate" "$label" "$result_file.upload"
      candidate_value="$(speedtest_format_mbps "$upload")|$upload_retrans|$(speedtest_format_mbps "$download")|$candidate|$label|$upload_connect|$upload_tls|$download_connect|$download_tls"
      candidate_valid_count=0
      speedtest_result_valid "$upload" && candidate_valid_count=$((candidate_valid_count + 1))
      speedtest_result_valid "$download" && candidate_valid_count=$((candidate_valid_count + 1))
      if [ "$candidate_valid_count" -eq 2 ]; then
        # Prefer a node that completed both directions. Do not stop at the
        # first node merely because its other direction happened to work.
        node_value="$candidate_value"
        selected_ip="$candidate"
        [ "${DEBUG_MODE:-0}" -eq 1 ] || rm -rf "$workdir"
        break
      elif [ "$candidate_valid_count" -gt "$partial_valid_count" ]; then
        partial_node_value="$candidate_value"
        partial_valid_count="$candidate_valid_count"
      fi
      [ "${DEBUG_MODE:-0}" -eq 1 ] || rm -rf "$workdir"
    done < <(printf '%s\n' "$candidates" | tr '|' '\n')

    if [ -z "$node_value" ] && [ -n "$partial_node_value" ]; then
      node_value="$partial_node_value"
    fi
    if [ -z "$node_value" ]; then
      selected_ip="${candidates%%|*}"
      node_value="failed|failed|failed|$selected_ip|$label|-|-|-|-"
    fi
    values+=("$node_value")
  done

  [ "${#values[@]}" -gt 0 ] || return 0
  SPEEDTEST_ROWS+=("IPv6;${values[0]};${values[1]};")
}

speedtest_format_mbps() {
  local bandwidth="$1"
  printf '%s' "$bandwidth"
}

speedtest_carrier_title() {
  local carrier="$1" city
  city=$(speedtest_selected_city "$carrier")
  if [ -n "$(speedtest_selected_id "$carrier")" ]; then
    printf '%s%s' "$city" "$carrier"
  else
    printf '%s失败' "$carrier"
  fi
}

speedtest_display_width() {
  local text="$1" char width=0
  while [ -n "$text" ]; do
    char=${text:0:1}
    text=${text:1}
    case "$char" in
      [[:ascii:]]) width=$((width + 1)) ;;
      *) width=$((width + 2)) ;;
    esac
  done
  printf '%s' "$width"
}

speedtest_pad_left() {
  local width="$1" text="$2" actual padding
  actual=$(speedtest_display_width "$text")
  padding=$((width - actual))
  [ "$padding" -gt 0 ] && printf '%*s' "$padding" ''
  printf '%s' "$text"
}

speedtest_pad_center() {
  local width="$1" text="$2" actual padding left right
  actual=$(speedtest_display_width "$text")
  padding=$((width - actual))
  [ "$padding" -lt 0 ] && padding=0
  left=$((padding / 2))
  right=$((padding - left))
  [ "$left" -gt 0 ] && printf '%*s' "$left" ''
  printf '%s' "$text"
  [ "$right" -gt 0 ] && printf '%*s' "$right" ''
}

speedtest_print_group_header() {
  local column_label="${2:-IPv4}" retrans_label="${3:-回程重传}"

  # The terminal formatter counts UTF-8 bytes, so align CJK headings by display width.
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 "$column_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 "$retrans_label"; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '回程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '去程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '回程延迟'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '去程延迟'; printf '%b' "$NC"
  printf '\n'
}

speedtest_print_applecdn_header() {
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '国际方向'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '下载重传'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '下载速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '上传速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '下载延迟'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '上传延迟'; printf '%b' "$NC"
  printf '\n'
}

speedtest_metric_failed() {
  case "${1,,}" in
    ""|-|failed|fail)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

speedtest_speed_text() {
  local value="$1"
  if speedtest_metric_failed "$value"; then
    printf 'failed'
  else
    printf '%sMbps' "$value"
  fi
}

speedtest_latency_text() {
  local value="$1"
  case "${value,,}" in
    failed|fail)
      printf 'failed'
      return
      ;;
  esac
  if [[ "$value" =~ ^-?[0-9]+$ ]] && [ "$value" -ge 0 ]; then
    awk -v value="$value" 'BEGIN { printf "%dms", int(value / 2 + 0.5) }'
  else
    printf '-'
  fi
}

speedtest_direction_latency_text() {
  local latency="$1" speed="$2"
  if speedtest_metric_failed "$speed"; then
    printf 'failed'
  else
    speedtest_latency_text "$latency"
  fi
}

speedtest_latency_color() {
  local value="$1" latency
  if ! [[ "$value" =~ ^-?[0-9]+$ ]] || [ "$value" -lt 0 ]; then
    printf '%s' "$RED"
    return
  fi
  latency=$(awk -v value="$value" 'BEGIN { printf "%d", int(value / 2 + 0.5) }')
  if [ "$latency" -gt 240 ]; then
    printf '%s' "$RED"
  elif [ "$latency" -gt 150 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

speedtest_show_progress() {
  local done="$1" total="$2"
  if [ "${SPEEDTEST_BACKGROUND:-0}" -eq 1 ]; then
    printf '%s/%s\n' "$done" "$total" > "$SPEEDTEST_PROGRESS_FILE"
    return
  fi
  echo -ne "\r  ${CYAN}测速进度${NC} "
  bar "$done" "$total"
  echo -ne "   "
}

speedtest_speed_color() {
  local value="$1" label="$2" level_name
  if [ "$value" = "failed" ]; then
    printf '%s' "$RED"
  elif [ "$label" = "不限" ] || [[ "$label" != *Mbps ]]; then
    level_name=$(awk -v value="$value" 'BEGIN {
      if (value <= 20) print "bad"
      else if (value <= 150) print "warn"
      else print "ok"
    }')
    case "$level_name" in
      ok) printf '%s' "$GREEN" ;;
      warn) printf '%s' "$YELLOW" ;;
      *) printf '%s' "$RED" ;;
    esac
  else
    level_name=$(awk -v value="$value" -v target="${label%Mbps}" 'BEGIN {
      if (value >= target * 0.8) print "ok"
      else if (value >= target * 0.6) print "warn"
      else print "bad"
    }')
    case "$level_name" in
      ok) printf '%s' "$GREEN" ;;
      warn) printf '%s' "$YELLOW" ;;
      *) printf '%s' "$RED" ;;
    esac
  fi
}

speedtest_retrans_color() {
  local value="$1"
  if [[ "$value" == *% ]]; then
    value="${value%\%}"
    if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s' "$RED"
    elif awk -v value="$value" 'BEGIN { exit !(value >= 20) }'; then
      printf '%s' "$RED"
    elif awk -v value="$value" 'BEGIN { exit !(value > 10) }'; then
      printf '%s' "$YELLOW"
    else
      printf '%s' "$GREEN"
    fi
    return
  fi
  if [ "$value" = "failed" ] || [ "$value" -gt 999 ] 2>/dev/null; then
    printf '%s' "$RED"
  elif [ "$value" -ge 100 ] 2>/dev/null; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

collect_speedtest_results() {
  local group group_region rate label carrier workdir result_file index candidate server_id city candidate_region
  local upload upload_retrans upload_connect upload_tls download download_retrans download_connect download_tls done total offset apple_steps apple_ipv6_steps
  local carriers=(电信 联通 移动)
  local carrier_values=()
  offset=${SPEEDTEST_PROGRESS_OFFSET:-0}
  done="$offset"
  total=${SPEEDTEST_PROGRESS_TOTAL:-0}
  apple_steps=0
  apple_ipv6_steps=0
  if speedtest_applecdn_tests_enabled; then
    apple_steps=1
    if speedtest_applecdn6_tests_enabled; then
      apple_steps=2
      load_remote_applecdn6_nodes || true
      apple_ipv6_steps=${#SPEEDTEST_APPLECDN6_NODES[@]}
    fi
  fi
  [ "$total" -gt 0 ] 2>/dev/null || total=$((offset + $(speedtest_group_count) * ${#carriers[@]} + apple_steps + apple_ipv6_steps))

  if [ "${SPEEDTEST_APPEND_STATE:-0}" -eq 1 ]; then
    speedtest_load_background_state || true
  else
    SPEEDTEST_ROWS=()
  fi

  [ "$(uname)" = "Linux" ] || {
  echo -e "${RED}[X] 单线程测速目前仅支持 Linux${NC}"
    exit 1
  }
  require_raw_socket_privilege
  check_curl
  speedtest_dependencies_ready || install_speedtest_dependencies || {
    echo -e "${RED}[X] 测速依赖安装失败${NC}"
    exit 1
  }
  load_remote_speedtest_nodes || true
  ensure_public_ips_for_rank
  install_speedtest_counter_dependency || true
  if ! command -v iptables &>/dev/null; then
    SPEEDTEST_RANK_ELIGIBLE=0
    SPEEDTEST_RANK_DISABLED_REASON="iptables_unavailable"
  fi
  if [ "$DEBUG_MODE" -eq 1 ]; then
    if [ "$SPEEDTEST_TOS_REMOTE_LOADED" -eq 1 ]; then
      echo -e "${DIM}[debug] TOS 节点入口来自 getNodes scope=tos${NC}" >&2
    else
      echo -e "${DIM}[debug] TOS 节点入口使用内置 fallback IP${NC}" >&2
    fi
    echo -e "${DIM}[debug] 固定 IP: 电信 $SPEEDTEST_TOS_CT_IP / 联通 $SPEEDTEST_TOS_CU_IP / 移动 $SPEEDTEST_TOS_CM_IP${NC}" >&2
    echo -e "${DIM}[debug] 传输方式: curl --resolve（保留 TOS Host/SNI）${NC}" >&2
    if [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" = "1" ] && [ -r "${SPEEDTEST_TCP_INFO_PRELOAD:-}" ]; then
      echo -e "${DIM}[debug] 重传统计: curl 目标 socket getsockopt(TCP_INFO)，可选 eBPF 序列去重；不可用时回退 ss/nstat${NC}" >&2
    elif [ "${SPEEDTEST_TCP_INFO_ENABLED:-1}" = "1" ] && command -v ss >/dev/null 2>&1; then
      echo -e "${DIM}[debug] 重传统计: 目标连接 TCP_INFO（ss retrans:X/Y），可选 eBPF 序列去重；不可用时回退 nstat${NC}" >&2
    else
      echo -e "${DIM}[debug] 重传统计: nstat 回退（目标连接 TCP_INFO 不可用）${NC}" >&2
    fi
    if [ "${SPEEDTEST_RETRANS_TRACE_ENABLED:-1}" = "1" ] && command -v bpftrace >/dev/null 2>&1; then
      echo -e "${DIM}[debug] 重传去重: bpftrace tcp_retransmit_skb，优先按 TCP seq/end_seq 去重，BTF 不可用时按 skb 身份回退${NC}" >&2
    else
      echo -e "${DIM}[debug] 重传去重: eBPF 不可用，使用 TCP_INFO/nstat 原始重传事件${NC}" >&2
    fi
  fi
  if request_rank_session; then
    [ "$DEBUG_MODE" -eq 1 ] && echo -e "${DIM}[debug] rank session 已获取${NC}" >&2
  else
    [ -n "$SPEEDTEST_RANK_DISABLED_REASON" ] || SPEEDTEST_RANK_DISABLED_REASON="rank_session_request_failed"
    [ "$DEBUG_MODE" -eq 1 ] && echo -e "${DIM}[debug] rank session 获取失败：$SPEEDTEST_RANK_DISABLED_REASON，本次报告不会进入排名${NC}" >&2
  fi
  SPEEDTEST_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$SPEEDTEST_IFACE" ] || {
    echo -e "${RED}[X] 无法识别默认网络接口${NC}"
    exit 1
  }
  if [ "${SPEEDTEST_BACKGROUND:-0}" -eq 1 ]; then
    trap 'speedtest_cleanup' EXIT
    trap 'speedtest_cleanup; exit 130' INT TERM
  fi

  echo -e "${BOLD}${CYAN}单线程测速${NC}"
  echo
  speedtest_show_progress 0 "$total"

  while IFS='|' read -r label group_region rate; do
    [ -n "$label" ] || continue
    carrier_values=()

    for carrier in "${carriers[@]}"; do
      workdir=$(mktemp -d "$RESULT_DIR/speedtest.XXXXXX")
      result_file="$workdir/result"
      candidate=$(speedtest_pick_candidate "$carrier" "$group_region")
      server_id=${candidate%%|*}
      city=${candidate#*|}
      city=${city%%|*}
      candidate_region=${candidate##*|}
      [ -n "$candidate_region" ] && [ "$candidate_region" != "$candidate" ] || candidate_region="$group_region"
      [ -n "$city" ] || city=$(speedtest_region_title "$group_region")
      SPEEDTEST_TOS_REGION="$candidate_region"
      speedtest_set_selected "$carrier" "$server_id" "$city"

      IFS='|' read -r download download_retrans download_connect download_tls <<<"$(speedtest_run_probe download "$result_file.download" "$server_id")"
      IFS='|' read -r upload upload_retrans upload_connect upload_tls <<<"$(speedtest_run_probe upload "$result_file.upload" "$server_id")"

      [ "$download" = "failed" ] && speedtest_record_failure_debug "$label" "$carrier" "download" "$server_id" "$city" "$result_file.download"
      [ "$upload" = "failed" ] && speedtest_record_failure_debug "$label" "$carrier" "upload" "$server_id" "$city" "$result_file.upload"

      if speedtest_result_valid "$upload" || speedtest_result_valid "$download"; then
        carrier_values+=("$(speedtest_format_mbps "$upload")|$upload_retrans|$(speedtest_format_mbps "$download")|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      else
        carrier_values+=("failed|failed|failed|$server_id|$city|$upload_connect|$upload_tls|$download_connect|$download_tls")
      fi
      # debug 模式下保留固定 IP 的 curl 输出文件，方便排查测速异常
      [ "${DEBUG_MODE:-0}" -eq 1 ] || rm -rf "$workdir"
      done=$((done + 1))
      speedtest_show_progress "$done" "$total"
    done

    SPEEDTEST_ROWS+=("$label;${carrier_values[0]};${carrier_values[1]};${carrier_values[2]}")
  done < <(speedtest_group_specs)

  speedtest_cleanup
  if speedtest_applecdn_tests_enabled; then
    if [ "$apple_ipv6_steps" -gt 0 ]; then
      speedtest_collect_applecdn6
      done=$((done + apple_ipv6_steps))
      speedtest_show_progress "$done" "$total"
    fi
    speedtest_collect_applecdn
    done=$((done + apple_steps))
    speedtest_show_progress "$done" "$total"
  fi

  speedtest_cleanup
  if [ "$SPEEDTEST_RANK_ELIGIBLE" -ne 1 ]; then
    RANK_SESSION_ID=""
    RANK_SESSION_TOKEN=""
    RANK_SESSION_STARTED_AT=""
    RANK_SESSION_EXPIRES_AT=""
    RANK_SESSION_IP4=""
    [ "$DEBUG_MODE" -eq 1 ] && [ -n "$SPEEDTEST_RANK_DISABLED_REASON" ] && \
      printf '%s\n' "$SPEEDTEST_RANK_DISABLED_REASON" > "$RESULT_DIR/rank_disabled_reason.txt"
    [ "$DEBUG_MODE" -eq 1 ] && [ -n "$SPEEDTEST_RANK_DISABLED_REASON" ] && \
      echo -e "${DIM}[debug] 排名凭证已清除：$SPEEDTEST_RANK_DISABLED_REASON${NC}" >&2
  fi
  if [ -n "${SPEEDTEST_STATE_FILE:-}" ]; then
    {
      printf 'META\t%s|%s|%s|%s|%s|%s\n' \
        "$SPEEDTEST_TELECOM_ID" "$SPEEDTEST_TELECOM_CITY" \
        "$SPEEDTEST_UNICOM_ID" "$SPEEDTEST_UNICOM_CITY" \
        "$SPEEDTEST_MOBILE_ID" "$SPEEDTEST_MOBILE_CITY"
      printf 'RANK\t%s|%s|%s|%s|%s|%s|%s\n' \
        "${RANK_SESSION_ID:-}" "${RANK_SESSION_TOKEN:-}" \
        "${RANK_SESSION_STARTED_AT:-}" "${RANK_SESSION_EXPIRES_AT:-}" \
        "${RANK_SESSION_IP4:-}" "${SPEEDTEST_RANK_ELIGIBLE:-0}" \
        "${SPEEDTEST_RANK_DISABLED_REASON:-}"
      printf 'ROW\t%s\n' "${SPEEDTEST_ROWS[@]}"
    } > "$SPEEDTEST_STATE_FILE"
  fi
  echo
}

speedtest_set_failed_rows() {
  SPEEDTEST_ROWS=()
  local label region rate node node_label node_candidates apple_row
  local ipv6_values=()
  while IFS='|' read -r label region rate; do
    [ -n "$label" ] || continue
    SPEEDTEST_ROWS+=("$label;failed|failed|failed|||-|-|-|-;failed|failed|failed|||-|-|-|-;failed|failed|failed|||-|-|-|-")
  done < <(speedtest_group_specs)
  if speedtest_applecdn_tests_enabled; then
    if speedtest_applecdn6_tests_enabled; then
      load_remote_applecdn6_nodes || true
      for node in "${SPEEDTEST_APPLECDN6_NODES[@]}"; do
        node_label="${node%%|*}"
        node_candidates="${node#*|}"
        ipv6_values+=("failed|failed|failed|${node_candidates%%|*}|$node_label|-|-|-|-")
      done
      [ "${#ipv6_values[@]}" -gt 0 ] && SPEEDTEST_ROWS+=("IPv6;${ipv6_values[0]};${ipv6_values[1]};")
    fi
    apple_row="AppleCDN;failed|failed|failed|$SPEEDTEST_APPLECDN_HOST|Apple IPv4|-|-|-|-"
    if speedtest_applecdn6_tests_enabled; then
      apple_row+=";failed|failed|failed|$SPEEDTEST_APPLECDN_HOST|Apple IPv6|-|-|-|-"
    fi
    SPEEDTEST_ROWS+=("$apple_row;")
  fi
}

speedtest_load_background_state() {
  local type value a b c d e f g
  SPEEDTEST_ROWS=()
  [ -s "$SPEEDTEST_STATE_FILE" ] || {
    speedtest_set_failed_rows
    return 1
  }

  while IFS=$'\t' read -r type value; do
    case "$type" in
      META)
        IFS='|' read -r a b c d e f <<<"$value"
        SPEEDTEST_TELECOM_ID="$a"
        SPEEDTEST_TELECOM_CITY="$b"
        SPEEDTEST_UNICOM_ID="$c"
        SPEEDTEST_UNICOM_CITY="$d"
        SPEEDTEST_MOBILE_ID="$e"
        SPEEDTEST_MOBILE_CITY="$f"
        ;;
      RANK)
        IFS='|' read -r a b c d e f g <<<"$value"
        RANK_SESSION_ID="$a"
        RANK_SESSION_TOKEN="$b"
        RANK_SESSION_STARTED_AT="$c"
        RANK_SESSION_EXPIRES_AT="$d"
        RANK_SESSION_IP4="$e"
        SPEEDTEST_RANK_ELIGIBLE="${f:-0}"
        SPEEDTEST_RANK_DISABLED_REASON="$g"
        ;;
      ROW)
        SPEEDTEST_ROWS+=("$value")
        ;;
    esac
  done < "$SPEEDTEST_STATE_FILE"

  [ "${#SPEEDTEST_ROWS[@]}" -gt 0 ] || speedtest_set_failed_rows
}

start_speedtest_background() {
  local offset="${1:-0}" append="${2:-0}"
  shift 2 || true
  SPEEDTEST_STATE_FILE="$RESULT_DIR/speedtest.state"
  SPEEDTEST_PROGRESS_FILE="$RESULT_DIR/speedtest.progress"
  printf '%s/%s\n' "$offset" "$SPEEDTEST_PROGRESS_TOTAL" > "$SPEEDTEST_PROGRESS_FILE"
  SPEEDTEST_BACKGROUND=1 SPEEDTEST_APPEND_STATE="$append" \
    SPEEDTEST_PROGRESS_OFFSET="$offset" collect_speedtest_results "$@" \
    >"$RESULT_DIR/speedtest.log" 2>&1 &
  SPEEDTEST_BACKGROUND_PID=$!
}

wait_speedtest_background() {
  local progress done total
  [ -n "${SPEEDTEST_BACKGROUND_PID:-}" ] || return 0
  while kill -0 "$SPEEDTEST_BACKGROUND_PID" 2>/dev/null; do
    if [ "${MULTI_PROGRESS_MODE:-0}" -eq 1 ]; then
      show_all_progress
    else
      progress=$(cat "$SPEEDTEST_PROGRESS_FILE" 2>/dev/null || true)
      done=${progress%%/*}
      total=${progress#*/}
      if [ -n "$done" ] && [ "$done" != "$progress" ] && [ -n "$total" ]; then
        echo -ne "\r  ${CYAN}测速进度${NC} "
        bar "$done" "$total"
        echo -ne "   "
      else
        echo -ne "\r  ${CYAN}测速准备中...${NC}   "
      fi
    fi
    sleep 0.2
  done
  wait "$SPEEDTEST_BACKGROUND_PID" 2>/dev/null || true
  speedtest_load_background_state || true
  [ "${MULTI_PROGRESS_MODE:-0}" -eq 1 ] || echo
}

show_speedtest_results() {
  local row label result1 result2 result3 result upload retrans download server_id city upload_connect upload_tls download_connect download_tls index carrier region upload_text download_text upload_tls_text download_tls_text
  local speed_color retrans_color tls_color
  local carriers=(电信 联通 移动)
  local results=()
  echo -e "${BOLD}${CYAN}单线程测速${NC}"
  echo
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -r label result1 result2 result3 <<<"$row"
    if [ "$label" = "AppleCDN" ]; then
      speedtest_print_applecdn_header
      for result in "$result1" "$result2"; do
        [ -n "$result" ] || continue
        IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
        printf '  '
        printf '%b' "$CYAN"; speedtest_pad_left 12 "${city:-AppleCDN}"; printf '%b' "$NC"
        printf '  '
        if [ "$retrans" = "-" ]; then
          printf '%b' "$DIM"; speedtest_pad_left 10 '-'; printf '%b' "$NC"
        elif speedtest_metric_failed "$download"; then
          printf '%b' "$RED"; speedtest_pad_left 10 'failed'; printf '%b' "$NC"
        else
          retrans_color=$(speedtest_retrans_color "$retrans")
          printf '%b' "$retrans_color"; speedtest_pad_left 10 "$retrans"; printf '%b' "$NC"
        fi
        printf '  '
        if [ "$download" = "-" ]; then
          download_text="-"
          speed_color="$DIM"
        else
          download_text=$(speedtest_speed_text "$download")
          speed_color=$(speedtest_speed_color "$download" "不限")
        fi
        printf '%b' "$speed_color"; speedtest_pad_left 12 "$download_text"; printf '%b' "$NC"
        printf '  '
        if [ "$upload" = "-" ]; then
          upload_text="-"
          speed_color="$DIM"
        else
          upload_text=$(speedtest_speed_text "$upload")
          speed_color=$(speedtest_speed_color "$upload" "不限")
        fi
        printf '%b' "$speed_color"; speedtest_pad_left 12 "$upload_text"; printf '%b' "$NC"
        printf '  '
        if [ "$download" = "-" ]; then
          download_tls_text="-"
        else
          download_tls_text=$(speedtest_direction_latency_text "$download_tls" "$download")
        fi
        if speedtest_metric_failed "$download"; then
          tls_color="$RED"
        elif [ "$download_tls" = "-" ]; then
          if [ "$download" = "-" ]; then
            tls_color="$DIM"
          else
            tls_color="$RED"
          fi
        else
          tls_color=$(speedtest_latency_color "$download_tls")
        fi
        printf '%b' "$tls_color"; speedtest_pad_left 10 "$download_tls_text"; printf '%b' "$NC"
        printf '  '
        if [ "$upload" = "-" ]; then
          upload_tls_text="-"
        else
          upload_tls_text=$(speedtest_direction_latency_text "$upload_tls" "$upload")
        fi
        if speedtest_metric_failed "$upload"; then
          tls_color="$RED"
        elif [ "$upload_tls" = "-" ]; then
          if [ "$upload" = "-" ]; then
            tls_color="$DIM"
          else
            tls_color="$RED"
          fi
        else
          tls_color=$(speedtest_latency_color "$upload_tls")
        fi
        printf '%b' "$tls_color"; speedtest_pad_left 10 "$upload_tls_text"; printf '%b' "$NC"
        printf '\n'
      done
      printf '\n'
      continue
    fi
    if [ "$label" = "IPv6" ]; then
      carriers=(深圳移动 重庆移动)
      speedtest_print_group_header "IPv6" "IPv6"
    else
      carriers=(电信 联通 移动)
      speedtest_print_group_header "$label" "IPv4"
    fi
    if [ "$label" = "IPv6" ]; then
      results=("$result1" "$result2")
    else
      results=("$result1" "$result2" "$result3")
    fi
    for index in "${!results[@]}"; do
      result="${results[$index]}"
      carrier="${carriers[$index]}"
      IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
      if [ "$label" = "IPv6" ]; then
        region="${city:-$carrier}"
      else
        region="${city:-$(speedtest_selected_city "$carrier")}${carrier}"
        [ -n "${city:-$(speedtest_selected_city "$carrier")}" ] || region="${carrier}失败"
      fi
      printf '  '
      printf '%b' "$CYAN"; speedtest_pad_left 12 "$region"; printf '%b' "$NC"
      printf '  '
      retrans_color=$(speedtest_retrans_color "$retrans")
      printf '%b' "$retrans_color"; speedtest_pad_left 10 "$retrans"; printf '%b' "$NC"
      printf '  '
      upload_text=$(speedtest_speed_text "$upload")
      speed_color=$(speedtest_speed_color "$upload" "$label")
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$upload_text"; printf '%b' "$NC"
      printf '  '
      download_text=$(speedtest_speed_text "$download")
      speed_color=$(speedtest_speed_color "$download" "$label")
      printf '%b' "$speed_color"; speedtest_pad_left 12 "$download_text"; printf '%b' "$NC"
      printf '  '
      upload_tls_text=$(speedtest_direction_latency_text "$upload_tls" "$upload")
      if speedtest_metric_failed "$upload"; then
        tls_color="$RED"
      else
        tls_color=$(speedtest_latency_color "$upload_tls")
      fi
      printf '%b' "$tls_color"; speedtest_pad_left 10 "$upload_tls_text"; printf '%b' "$NC"
      printf '  '
      download_tls_text=$(speedtest_direction_latency_text "$download_tls" "$download")
      if speedtest_metric_failed "$download"; then
        tls_color="$RED"
      else
        tls_color=$(speedtest_latency_color "$download_tls")
      fi
      printf '%b' "$tls_color"; speedtest_pad_left 10 "$download_tls_text"; printf '%b' "$NC"
      printf '\n'
    done
    echo
  done
  echo -e "  ${DIM}注：代理速度由回程速度+下载速度的短板决定。${NC}"
}

append_speedtest_csv() {
  local csv="$1" row label result1 result2 result3 result upload retrans download server_id city upload_connect upload_tls download_connect download_tls index carrier
  local carriers=(电信 联通 移动)
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -r label result1 result2 result3 <<<"$row"
    if [ "$label" = "IPv6" ]; then
      for result in "$result1" "$result2"; do
        [ -n "$result" ] || continue
        IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
        city="${city:-IPv6}"
        if [ "$upload" = "failed" ] || [ "$download" = "failed" ]; then
          printf '三网单线程速度,%s,%s,%s,,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
            "$label" "$city" "$city" "FAIL" "$upload" "$retrans" "$download" \
            "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
        else
          printf '三网单线程速度,%s,%s,%s,%s,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
            "$label" "$city" "$city" "$server_id" \
            "OK" "$upload" "$retrans" "$download" \
            "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
        fi
      done
      continue
    fi
    if [ "$label" = "AppleCDN" ]; then
      for result in "$result1" "$result2"; do
        [ -n "$result" ] || continue
        IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
        if [ "$upload" = "-" ] && [ "$download" = "-" ]; then
          printf '三网单线程速度,%s,%s,%s,%s,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
            "$label" "${city:-AppleCDN}" "${city:-AppleCDN}" "${server_id:-$SPEEDTEST_APPLECDN_HOST}" \
            "SKIP" "$upload" "$retrans" "$download" \
            "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
        elif [ "$upload" = "failed" ] || [ "$download" = "failed" ]; then
          printf '三网单线程速度,%s,%s,%s,,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
            "$label" "${city:-AppleCDN}" "${city:-AppleCDN}" "FAIL" "$upload" "$retrans" "$download" \
            "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
        else
          printf '三网单线程速度,%s,%s,%s,%s,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
            "$label" "${city:-AppleCDN}" "${city:-AppleCDN}" "${server_id:-$SPEEDTEST_APPLECDN_HOST}" \
            "OK" "$upload" "$retrans" "$download" \
            "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
        fi
      done
      continue
    fi
    index=0
    for result in "$result1" "$result2" "$result3"; do
      carrier="${carriers[$index]}"
      IFS='|' read -r upload retrans download server_id city upload_connect upload_tls download_connect download_tls <<<"$result"
      city="${city:-$(speedtest_selected_city "$carrier")}"
      server_id="${server_id:-$(speedtest_selected_id "$carrier")}"
      if [ "$upload" = "failed" ] || [ "$download" = "failed" ]; then
        printf '三网单线程速度,%s,%s,%s,,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
          "$label" "$carrier" "$city" "FAIL" "$upload" "$retrans" "$download" \
          "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
      else
        printf '三网单线程速度,%s,%s,%s,%s,,%s,%s,%s,%s,,,%s,%s,%s,%s\n' \
          "$label" "$carrier" "$city" "$server_id" \
          "OK" "$upload" "$retrans" "$download" \
          "${upload_connect:--}" "${upload_tls:--}" "${download_connect:--}" "${download_tls:--}" >> "$csv"
      fi
      index=$((index + 1))
    done
  done
  speedtest_append_tcp_config_csv "$csv"
}

run_speedtest_mode() {
  local report_time csv
  check_curl
  detect_ip_stack
  if ipv6_available; then
    echo -e "${GREEN}[√] 单线程测速检测到可用 IPv6${NC}"
  else
    echo -e "${YELLOW}[!] 单线程测速未检测到可用 IPv6，跳过 IPv6 测速${NC}"
  fi
  collect_speedtest_results
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  csv="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$csv"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路,回程连接耗时ms,回程TLS握手耗时ms,去程连接耗时ms,去程TLS握手耗时ms,iPerf3重传次数,iPerf3方向" >> "$csv"
  append_speedtest_csv "$csv"
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo
  show_speedtest_results
  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    echo
    upload_report "$csv" "${report_time%%（*}"
  fi
  echo
}

# ===================== 主流程 =====================
main() {
  clear
  print_header

  init_privilege

  if [ "$INTERNATIONAL_ONLY" -eq 1 ]; then
    [ "$COUNT_EXPLICIT" -eq 1 ] && INTERNATIONAL_PACKETS="$PACKETS"
    run_international_mode
    exit 0
  fi

  if [ "$SPEEDTEST_ONLY" -eq 1 ]; then
    run_speedtest_mode
    exit 0
  fi

  if [ "$ROUTE_MODE" -eq 1 ]; then
    check_curl
    detect_ip_stack
    echo -e "  ${DIM}报告时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')${NC}"
    echo ""
    if [ "$ONLY_IPV6" -ne 1 ]; then
      run_route_mode 4
    fi
    if [ "$ONLY_IPV4" -ne 1 ]; then
      run_route_mode 6
    fi
    exit 0
  fi

  require_raw_socket_privilege
  check_curl
  require_remote_nodes
  check_nping
  detect_ip_stack

  local ipv4_enabled=0 ipv6_enabled=0 test_cdn=1 normal_cdn_enabled=1 test_edu=0 want_ipv4=1 want_ipv6=1
  local large_packet_enabled=0 large_packet_route_enabled=0 large_packet_probe_enabled=0 large_node_count=0
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

  if [ "$TEST_CERNET" -eq 1 ] && [ "$TEST_ALL" -eq 0 ] && [ "$INCLUDE_DEFAULT_ROUTE" -eq 0 ]; then
    test_cdn=0
    normal_cdn_enabled=0
    test_edu=1
  elif [ "$TEST_CERNET" -eq 1 ] || [ "$TEST_ALL" -eq 1 ]; then
    test_edu=1
  fi
  if [ "$ONLY_LARGE" -eq 1 ]; then
    normal_cdn_enabled=0
    test_edu=0
    INTERNATIONAL_ENABLED=0
  fi
  if [ "$want_ipv4" -eq 0 ] || [ "$ipv4_enabled" -eq 0 ]; then
    INTERNATIONAL_ENABLED=0
  fi

  local cdn_node_count cernet_node_count cernet2_node_count
  local cdn4_node_count cdn6_node_count
  cdn4_node_count=$(count_cdn_nodes 4)
  cdn6_node_count=$(count_cdn_nodes 6)
  cdn_node_count="$cdn4_node_count"
  cernet_node_count=$(count_cernet_nodes)
  cernet2_node_count=$(count_cernet2_nodes)

  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_cdn" -eq 1 ]; then
    large_packet_enabled=1
    large_node_count="$cdn4_node_count"
    if ! check_nexttrace; then
      large_packet_enabled=0
      large_packet_route_enabled=0
      large_packet_probe_enabled=0
    else
      # IPv4 大包的 nexttrace 属于回程识别；大包 nping 预检延后到路由阶段之后。
      large_packet_route_enabled=1
      large_packet_probe_enabled=1
    fi
  fi

  TOTAL=0
  if [ "$ipv4_enabled" -eq 1 ] && [ "$normal_cdn_enabled" -eq 1 ]; then TOTAL=$((TOTAL + cdn4_node_count)); fi
  if [ "$large_packet_probe_enabled" -eq 1 ] || { [ "$ONLY_LARGE" -eq 1 ] && [ "$large_packet_enabled" -eq 1 ]; }; then TOTAL=$((TOTAL + large_node_count)); fi
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + cernet_node_count)); fi
  if [ "$want_ipv6" -eq 1 ] && ipv6_available; then
    ipv6_enabled=1
    # IPv6 的 nping 预检会产生探测流量，延后到所有回程识别完成后执行。
    if [ "$normal_cdn_enabled" -eq 1 ]; then TOTAL=$((TOTAL + cdn6_node_count)); fi
    if [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + cernet2_node_count)); fi
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
  if [ "$INTERNATIONAL_ENABLED" -eq 1 ]; then
    [ "$COUNT_EXPLICIT" -eq 1 ] && INTERNATIONAL_PACKETS="$PACKETS"
    INTERNATIONAL_PROGRESS_TOTAL=$(international_total_task_count)
  fi
  local family entry prov isp host fixed_ip port backup_host backup_ip backup_port
  local -a families=()
  if [ "$normal_cdn_enabled" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then families+=(4); fi
    if [ "$ipv6_enabled" -eq 1 ]; then families+=(6); fi
  fi
  if [ "$normal_cdn_enabled" -eq 1 ] || [ "$test_edu" -eq 1 ]; then
    check_traceroute
  fi

  local sorted_v4 sorted_v6 sorted_large_v4 sorted_cernet sorted_cernet2 route_labels_v4 route_labels_v6 route_labels_large_v4 edu_route_labels_v4 edu_route_labels_v6 sorted_file f i status ip snd rcv loss lat route_label route_file
  sorted_v4=$(mktemp)
  sorted_v6=$(mktemp)
  sorted_large_v4=$(mktemp)
  sorted_cernet=$(mktemp)
  sorted_cernet2=$(mktemp)
  route_labels_v4=$(mktemp)
  route_labels_v6=$(mktemp)
  route_labels_large_v4=$(mktemp)
  edu_route_labels_v4=$(mktemp)
  edu_route_labels_v6=$(mktemp)

  # 回程识别先执行；完成后再做延迟/丢包、国际互联和测速，避免前置探测流量影响路由响应。
  SPEEDTEST_PROGRESS_TOTAL=0
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    SPEEDTEST_PROGRESS_TOTAL=$(($(speedtest_group_count) * 3))
    if speedtest_applecdn_tests_enabled; then
      speedtest_applecdn6_tests_enabled || true
      SPEEDTEST_PROGRESS_TOTAL=$((SPEEDTEST_PROGRESS_TOTAL + $(speedtest_applecdn6_count) + 1))
      [ "$SPEEDTEST_IPV6_AVAILABLE" -eq 1 ] && SPEEDTEST_PROGRESS_TOTAL=$((SPEEDTEST_PROGRESS_TOTAL + 1))
    fi
  fi
  if [ "$INTERNATIONAL_ENABLED" -eq 1 ]; then
    INTERNATIONAL_PROGRESS_TOTAL=$(international_total_task_count)
  fi
  if [ "$normal_cdn_enabled" -eq 1 ] || [ "$test_edu" -eq 1 ] || [ "$large_packet_route_enabled" -eq 1 ]; then
    set_route_progress_total "$ipv4_enabled" "$ipv6_enabled" "$normal_cdn_enabled" "$test_edu" "$large_packet_route_enabled"
  fi
  echo -e "  ${DIM}正在检测，请稍候...${NC}"
  MULTI_PROGRESS_MODE=1

  local idx=0
  show_progress

  # 第一阶段：只做回程路由识别。所有 nping 延迟/丢包探测都在此阶段结束后执行。
  if [ "$normal_cdn_enabled" -eq 1 ] || [ "$test_edu" -eq 1 ] || [ "$large_packet_route_enabled" -eq 1 ]; then
    start_route_background "$route_labels_v4" "$route_labels_v6" "$ipv4_enabled" "$ipv6_enabled" "$normal_cdn_enabled" "$test_edu" "$edu_route_labels_v4" "$edu_route_labels_v6" "$route_labels_large_v4" "$large_packet_route_enabled"
    wait_route_background
  fi

  # 路由识别结束后，才进行会影响网络响应的预检和延迟/丢包测试。
  if [ "$ipv6_enabled" -eq 1 ]; then
    ipv6_nping_precheck
    export IPV6_NPING_FORCE_L2
  fi
  if [ "$large_packet_probe_enabled" -eq 1 ] && ! large_packet_precheck; then
    large_packet_probe_enabled=0
  fi

  if [ "$normal_cdn_enabled" -eq 1 ]; then
    for family in "${families[@]}"; do
      while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
        port=${port:-80}
        province_selected "$prov" || continue
        idx=$((idx + 1))
        while [ $((idx - $(count_results))) -gt "$PARALLEL" ]; do
          show_progress
          sleep 0.2
        done
        test_one "cdn${family}" "$family" "$prov" "$isp" "$host" "$idx" "$fixed_ip" "$port" "$backup_host" "$backup_ip" "${backup_port:-80}" &
        show_progress
      done < <(print_cdn_entries "$family")
    done
  fi
  if [ "$large_packet_probe_enabled" -eq 1 ]; then
    while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
      port=${port:-80}
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ $((idx - $(count_results))) -gt "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_large_one "large4" 4 "$prov" "$isp" "$host" "$idx" "$fixed_ip" "$port" "$backup_host" "$backup_ip" "${backup_port:-80}" &
      show_progress
    done < <(print_cdn_entries 4)
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      port=${port:-80}
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ $((idx - $(count_results))) -gt "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet" 4 "$prov" "教育网" "$host" "$idx" "$fixed_ip" "$port" "$backup_host" "$backup_ip" "${backup_port:-443}" &
      show_progress
    done < <(print_cernet_entries)
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    while IFS='|' read -r prov host fixed_ip port backup_host backup_ip backup_port; do
      port=${port:-80}
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ $((idx - $(count_results))) -gt "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet2" 6 "$prov" "教育网" "$host" "$idx" "$fixed_ip" "$port" "$backup_host" "$backup_ip" "${backup_port:-443}" &
      show_progress
    done < <(print_cernet2_entries)
  fi
  while [ $((idx - $(count_results))) -gt 0 ]; do
    show_progress
    sleep 0.2
  done
  show_progress

  if [ "$large_packet_enabled" -eq 1 ] && [ "$large_packet_probe_enabled" -eq 0 ]; then
    i=0
    while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
      province_selected "$prov" || continue
      i=$((i + 1))
      write_large_skip_result "$prov" "$isp" "$host" "$fixed_ip" "$i"
    done < <(print_cdn_entries 4)
    show_progress
  fi
  if [ "$INTERNATIONAL_ENABLED" -eq 1 ]; then
    run_international_tests
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    start_speedtest_background 0 0
    wait_speedtest_background
  fi
  show_progress
  printf '\n'

  # 收集结果并写入 CSV
  local report_time
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  local CSV="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$CSV"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路,回程连接耗时ms,回程TLS握手耗时ms,去程连接耗时ms,去程TLS握手耗时ms,iPerf3重传次数,iPerf3方向" >> "$CSV"

  if [ "$normal_cdn_enabled" -eq 1 ]; then
    for family in "${families[@]}"; do
      if [ "$family" = "4" ]; then sorted_file="$sorted_v4"; else sorted_file="$sorted_v6"; fi
      if [ "$family" = "4" ]; then route_file="$route_labels_v4"; else route_file="$route_labels_v6"; fi
      for i in $(seq 1 "$TOTAL"); do
        f="${RESULT_DIR}/cdn${family}_${i}"
        if [ -f "$f" ]; then
          IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
          route_label=$(awk -F'|' -v p="$prov" -v i="$isp" '$2 == p && $3 == i { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$route_file")
          if [ "$status" != "OK" ] && [ "$status" != "SKIP" ]; then route_label="failed"; fi
          echo "三网,IPv${family},$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat,$route_label" >> "$CSV"
          echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_file"
        fi
      done
    done
  fi
  if [ "$large_packet_enabled" -eq 1 ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
      if [ "$large_packet_probe_enabled" -eq 1 ]; then
        route_label=$(awk -F'|' -v p="$prov" -v i="$isp" '$2 == p && $3 == i { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$route_labels_large_v4")
      else
        route_label="Hidden"
      fi
      route_label=${route_label:-Hidden}
      if [ "$status" != "OK" ] && [ "$status" != "SKIP" ]; then route_label="failed"; fi
      echo "IPv4大包,IPv4,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat,$route_label" >> "$CSV"
      echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_large_v4"
    done < <(find "$RESULT_DIR" -maxdepth 1 -type f -name 'large4_[0-9]*' | awk -F_ '{ print $NF "|" $0 }' | sort -t'|' -k1,1n | cut -d'|' -f2-)
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/cernet_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        route_label=$(awk -F'|' -v p="$prov" '$2 == p { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$edu_route_labels_v4")
        route_label=${route_label:-Hidden}
        if [ "$status" != "OK" ] && [ "$status" != "SKIP" ]; then route_label="failed"; fi
        echo "CERNET,IPv4,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat,$route_label" >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat|$route_label" >> "$sorted_cernet"
      fi
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/cernet2_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        route_label=$(awk -F'|' -v p="$prov" '$2 == p { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$edu_route_labels_v6")
        route_label=${route_label:-Hidden}
        if [ "$status" != "OK" ] && [ "$status" != "SKIP" ]; then route_label="failed"; fi
        echo "CERNET2,IPv6,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat,$route_label" >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat|$route_label" >> "$sorted_cernet2"
      fi
    done
  fi
  if [ "$INTERNATIONAL_ENABLED" -eq 1 ]; then
    append_international_csv "$CSV"
    append_international_latency_csv "$CSV"
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    append_speedtest_csv "$CSV"
  fi

  # ---- TUI 结果展示 ----
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo ""

  if [ "$normal_cdn_enabled" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then
      show_family_results "IPv4回程" "$sorted_v4" "$route_labels_v4"
    fi
    if [ "$large_packet_enabled" -eq 1 ]; then
      show_large_packet_results "IPv4大包回程" "$sorted_large_v4" "$route_labels_large_v4" "$LARGE_PACKET_FIREWALL_LIMITED"
    fi
    if [ "$ipv6_enabled" -eq 1 ]; then
      show_family_results "IPv6回程" "$sorted_v6" "$route_labels_v6"
    fi
  fi
  if [ "$test_edu" -eq 1 ] && [ -s "$sorted_cernet" ] && [ -s "$sorted_cernet2" ]; then
    show_education_combined "$sorted_cernet" "$sorted_cernet2"
  else
    if [ "$test_edu" -eq 1 ] && [ -s "$sorted_cernet" ]; then
      show_education_results "CERNET-IPv4" "$sorted_cernet"
    fi
    if [ "$test_edu" -eq 1 ] && [ -s "$sorted_cernet2" ]; then
      show_education_results "CERNET2-IPv6" "$sorted_cernet2"
    fi
  fi

  if [ "$INTERNATIONAL_ENABLED" -eq 1 ]; then
    show_international_results
  fi

  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    show_speedtest_results
    echo
  fi

  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    upload_report "$CSV" "${report_time%%（*}"
  fi
  echo ""

  rm -f "$sorted_v4" "$sorted_v6" "$sorted_large_v4" "$sorted_cernet" "$sorted_cernet2" "$route_labels_v4" "$route_labels_v6" "$route_labels_large_v4" "$edu_route_labels_v4" "$edu_route_labels_v6"
}

parse_args "$@"
apply_auto_parallel
main
