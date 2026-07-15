#!/bin/bash
#
# TcpQuality 节点 TCP 丢包探测脚本
# 用法: bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
#
# 每节点发送 60 个裸 TCP SYN 包，无内核重传
# TUI 风格实时展示省份/运营商丢包率
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
      --speedtest|--only-speedtest) need_speedtest=1 ;;
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
    nixpkgs#jq
    nixpkgs#kmod
    nixpkgs#ncurses
    nixpkgs#nmap
    nixpkgs#traceroute
  )
  if [ "$need_speedtest" -eq 1 ]; then
    # 官方 Ookla CLI 在 nixpkgs 中是 unfree 包，仅测速模式加载。
    nix_packages+=(nixpkgs#ookla-speedtest)
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

require_raw_socket_privilege() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
    exit 1
  fi
}

# ===================== 远端节点 =====================
# 节点域名、真实 IP 与端口统一由 GET_NODES_URL 提供，脚本不再内置探测节点或备用节点。

PACKETS=30
PACKET_SIZES=(40 80 160 320 640 1200)
# 默认使用标准 TCP SYN，不携带数据；仅在显式指定 -s/--size 时构造指定长度报文。
PACKET_SIZE_OVERRIDE="0"
TOTAL=0
PARALLEL=16
TEST_CERNET=0
TEST_ALL=0
UPLOAD_REPORT=1
ONLY_IPV4=0
ONLY_IPV6=0
ROUTE_MODE=0
ROUTE_PROTOCOL="tcp"
SELECTED_PROVINCES=""
DEBUG_MODE=0
SPEEDTEST_ENABLED=0
SPEEDTEST_ONLY=0
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
RESULT_DIR=$(mktemp -d)
cleanup_result_dir() {
  if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    echo -e "${DIM}Debug 目录：$RESULT_DIR${NC}"
  else
    rm -rf "$RESULT_DIR"
  fi
  case "${TCPQUALITY_NIX_TEMP_SCRIPT:-}" in
    /tmp/tcpquality-nixos.*.sh) rm -f -- "$TCPQUALITY_NIX_TEMP_SCRIPT" ;;
  esac
}
trap cleanup_result_dir EXIT

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
  if [ "$TEST_ALL" -eq 1 ]; then
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
  local tmp line type family prov isp host ip port target backup_host backup_ip backup_port backup_target url sep
  command -v curl &>/dev/null || return 1
  tmp=$(mktemp)
  sep="?"
  [[ "$GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${GET_NODES_URL}${sep}format=tsv&scope=${scope}"
  if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  REMOTE_CDN4_NODES=()
  REMOTE_CDN6_NODES=()
  REMOTE_CERNET_NODES=()
  REMOTE_CERNET2_NODES=()

  while IFS=$'\t' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target; do
    [ "$type" = "type" ] && continue
    [ -n "$ip" ] || continue
    port=${port:-80}
    case "$type:$family" in
      cdn:4) REMOTE_CDN4_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cdn:6) REMOTE_CDN6_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cernet:4) REMOTE_CERNET_NODES+=("$prov|$host|$ip|$port") ;;
      cernet2:6) REMOTE_CERNET2_NODES+=("$prov|$host|$ip|$port") ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  if [ "${#REMOTE_CDN4_NODES[@]}" -gt 0 ] || [ "${#REMOTE_CDN6_NODES[@]}" -gt 0 ] ||
     [ "${#REMOTE_CERNET_NODES[@]}" -gt 0 ] || [ "${#REMOTE_CERNET2_NODES[@]}" -gt 0 ]; then
    REMOTE_NODES_LOADED=1
    [ "$DEBUG_MODE" -eq 1 ] && echo -e "${DIM}  getNodes: 已加载远端节点 IP+端口（scope=${scope}）${NC}"
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
  echo -e "${DIM}    getNodes: ${GET_NODES_URL}  scope=${scope}${NC}"
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
  使用 --speedtest/--only-speedtest 时会临时加载 unfree 的 ookla-speedtest。

选项:
  -h, --help        显示帮助信息并退出
  -c, --count NUM   设置每节点发包数，默认 ${PACKETS}
  -s, --size NUM    指定 IP 包总长度（单位 B），0 为标准无负载 SYN；默认 0
                     小于协议头部的数值按最小头部长度发送
  -p, --parallel NUM
                     设置并行节点数，范围 1-31，默认 ${PARALLEL}
  -v4, --v4         仅探测 IPv4
  -v6, --v6         仅探测 IPv6
  --cernet          仅探测 CERNET IPv4 和 CERNET2 IPv6
  --all             探测三网、CERNET 和 CERNET2
  --speedtest       追加国内三网分阶段 Speedtest（避免影响延迟探测）
  --only-speedtest  仅运行国内三网分阶段 Speedtest
  --province CODE   仅检测指定省份，可重复；也支持简写参数如 -bj、-sh、-gd
                     注意: 山西使用 -sx，陕西使用 -sn
  --debug           保留临时文件并输出调试信息，便于排查线路识别问题

示例:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -c 100
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -bj -v4 --cernet
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) --speedtest

依赖:
  - nping: 随 nmap 安装
  - curl: 用于检测公网 IPv4/IPv6 与上传报告
  - traceroute: 用于自动识别三网 TCP 回程线路
  - speedtest/iproute2: 分阶段测速使用
  - awk/sed/grep: 用于结果解析和展示

安装提示:
  - NixOS:          无需安装，脚本自动进入临时 nix shell
  - Debian/Ubuntu: apt-get install -y curl nmap traceroute
  - RHEL/Fedora:   dnf install -y curl nmap traceroute
  - Alpine Linux:  apk add curl nmap-nping traceroute
  - Arch Linux:    pacman -S curl nmap traceroute
  - macOS:         brew install curl nmap traceroute

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
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
          echo -e "${RED}[X] 发包数必须是大于 0 的整数${NC}" >&2
          exit 1
        fi
        PACKETS="$2"
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
      --cernet)
        TEST_CERNET=1
        shift
        ;;
      --all)
        TEST_ALL=1
        shift
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
    find "$RESULT_DIR" -type f -name 'route_[0-9]*' 2>/dev/null | wc -l | tr -d ' '
  else
    find "$RESULT_DIR" -maxdepth 1 -type f \( -name 'cdn4_[0-9]*' -o -name 'cdn6_[0-9]*' -o -name 'cernet_[0-9]*' -o -name 'cernet2_[0-9]*' \) 2>/dev/null | wc -l | tr -d ' '
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
  find "$RESULT_DIR" -maxdepth 1 -type f -name 'summary_route[46]_[0-9]*' ! -name '*.ips' 2>/dev/null | wc -l | tr -d ' '
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
  local latency_done route_done speed_done speed_total speed_progress now state complete force
  force=${1:-0}
  latency_done=$(count_results)
  [ "$latency_done" -gt "$TOTAL" ] && latency_done="$TOTAL"
  route_done=$(count_route_progress)
  [ "$route_done" -gt "$ROUTE_PROGRESS_TOTAL" ] && route_done="$ROUTE_PROGRESS_TOTAL"
  speed_progress=$(read_speedtest_progress)
  speed_done=${speed_progress%%|*}
  speed_total=${speed_progress#*|}
  now=$(date +%s)
  state="all:${latency_done}/${TOTAL}:${route_done}/${ROUTE_PROGRESS_TOTAL}:${speed_done}/${speed_total}"
  complete=0
  if [ "$latency_done" -ge "$TOTAL" ] \
    && { [ "$ROUTE_PROGRESS_TOTAL" -eq 0 ] || [ "$route_done" -ge "$ROUTE_PROGRESS_TOTAL" ]; } \
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
  printf '\r\033[2K  %b延迟重传%b ' "$CYAN" "$NC"
  bar "$latency_done" "$TOTAL"
  printf '\n'
  if [ "$ROUTE_PROGRESS_TOTAL" -gt 0 ]; then
    printf '\r\033[2K  %b回程识别%b ' "$CYAN" "$NC"
    bar "$route_done" "$ROUTE_PROGRESS_TOTAL"
    printf '\n'
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    printf '\r\033[2K  %b分段测速%b ' "$CYAN" "$NC"
    bar "$speed_done" "$speed_total"
    printf '\n'
  fi
  PROGRESS_LINES_PRINTED=$((1 + (SPEEDTEST_ENABLED == 1) + (ROUTE_PROGRESS_TOTAL > 0)))
}

show_progress() {
  local force=${1:-0}
  if [ "${MULTI_PROGRESS_MODE:-0}" -eq 1 ]; then
    show_all_progress "$force"
  else
    show_single_progress "$force"
  fi
}

show_provider_summary() {
  local file="$1" route_file="${2:-}"
  awk -F'|' -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function fail_cell() {
    return red "failed     " nc
  }
  function latency_color(v) {
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat, rcv,   l, v, color) {
    l = loss + 0
    v = lat + 0
    if (status != "OK") {
      return fail_cell()
    }

    return latency_color(v) sprintf("%4.0fms", v) nc " " loss_color(l) sprintf("%4s", compact_loss(loss) "%") nc
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
    if (!(prov in seen)) {
      seen[prov] = 1
      order[++n] = prov
    }
    data[prov SUBSEP isp] = cell(status, loss, lat, rcv)
  }
  END {
    printf "  %s%s三网概览%s %s(%s       电信       %s / %s       联通       %s / %s       移动       %s)%s\n", bold, cyan, nc, dim, cyan, dim, cyan, dim, cyan, dim, nc
    for (i = 1; i <= n; i++) {
      prov = order[i]
      prov_pad = (prov == "黑龙江" || prov == "内蒙古") ? "  " : "    "
      printf "  %s%s%s%s  %-6s %s / %-6s %s / %-6s %s\n", cyan, prov, nc, prov_pad, route_label(prov, "电信"), data[prov SUBSEP "电信"], route_label(prov, "联通"), data[prov SUBSEP "联通"], route_label(prov, "移动"), data[prov SUBSEP "移动"]
    }
    printf "  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n\n", dim, green, dim, yellow, dim, red, dim
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

show_education_results() {
  local title="$1" file="$2"
  awk -F'|' -v title="$title" -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v cyan="$CYAN" -v dim="$DIM" -v bold="$BOLD" -v nc="$NC" '
  function compact_loss(v) {
    return int(v + 0.5)
  }
  function latency_color(v) {
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat,   l, v, color) {
    if (status != "OK") return red "failed       " nc
    l = loss + 0
    v = lat + 0
    return latency_color(v) sprintf("%4.0fms", v) nc " / " loss_color(l) sprintf("%4s", compact_loss(loss) "%") nc
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
  function latency_color(v) {
    if (v > 240) return red
    if (v > 150) return yellow
    return green
  }
  function loss_color(l) {
    if (l > 20) return red
    if (l > 0) return yellow
    return green
  }
  function cell(status, loss, lat,   l, v, color) {
    if (status != "OK") return red "failed       " nc
    l = loss + 0
    v = lat + 0
    return latency_color(v) sprintf("%4.0fms", v) nc " / " loss_color(l) sprintf("%4s", compact_loss(loss) "%") nc
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
  local apis=("ip.sb" "ping0.cc" "icanhazip.com" "api64.ipify.org" "ifconfig.co" "ident.me")
  for api in "${apis[@]}"; do
    response=$(curl -s4 --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
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
  local apis=("ip.sb" "ping0.cc" "icanhazip.com" "api64.ipify.org" "ifconfig.co" "ident.me")
  for api in "${apis[@]}"; do
    response=$(curl -s6k --max-time 8 "$api" 2>/dev/null | awk 'NR==1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
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

upload_report() {
  local csv="$1" report_time="${2:-}" response_file http_code report_url today_uses total_uses
  if ! command -v curl &>/dev/null; then
    echo -e "  ${YELLOW}[!] 依赖不完整，已跳过 SVG 报告上传${NC}"
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
      if (asn ~ /^[0-9]+$/ && ip ~ /^[0-9A-Fa-f:.]+$/) print ip "|" asn
    }
  ' "$cymru_file" > "$map_file"
}

route_label_from_ip_trace() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3"
  awk -F'|' '
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
      if (ip ~ /^162\.219\.85\./ || ip ~ /^118\.26\.151\./) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./) return "9929"
      if (ip ~ /^101\.4\./ || ip ~ /^202\.112\./) return "4538"
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
    function is_163_ip(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./
    }
    function classify(   hop, first_cn2, has_ctgnet, has_cn2) {
      for (hop = 1; hop <= max_hop; hop++) {
        if (asns[hop] == "23764" || is_ctgnet_ip(ips[hop])) has_ctgnet = 1
        if (asns[hop] == "4809" || ips[hop] ~ /^59\.43\./) {
          has_cn2 = 1
          if (first_cn2 == 0) first_cn2 = hop
        }
      }
      if (has_asn("58807")) return "CMIN2"
      if (has_asn("10099")) return "10099"
      if (has_asn("9929")) return "9929"
      if (has_cn2) {
        if (has_ctgnet) return "CTGGIA"
        return "CN2GIA"
      }
      if (has_asn("4837") || has_asn("4808")) return "4837"
      if (has_asn("4134") || has_asn("4847")) return "163"
      if (has_asn("58453") || has_asn("9808") || has_asn("56040") || has_asn("56041") || has_asn("56042") || has_asn("56044") || has_asn("56045") || has_asn("56046") || has_asn("56047") || has_asn("56048")) return "CMI"
      if (has_ctgnet || has_asn("23764")) return "CTGGIA"
      if (has_asn("4538")) return "CERNET"
      if (has_asn("7497")) return "CSTNET"
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

route_trace_one() {
  local family="$1" protocol="$2" prov="$3" isp="$4" host="$5" idx="$6" port="${7:-80}" fixed_ip="${8:-}" prefix="${9:-route}"
  local outfile="${RESULT_DIR}/${prefix}_${idx}" trace_file="${RESULT_DIR}/${prefix}_trace_${idx}"
  local probe_arg="-T"
  [ "$protocol" = "udp" ] && probe_arg="-U"
  local -a args
  local output rc target_ip target

  target_ip="$fixed_ip"
  if [ -z "$target_ip" ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|NO_NODE_IP" > "$outfile"
    return
  fi
  target="$target_ip"
  args=(-n "-${family}" "$probe_arg" -p "$port" -q 3 -w 2 -m 30 "$target" 44)

  if output=$(traceroute "${args[@]}" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  {
    printf "# %s|%s|%s|%s|%s|%s\n" "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
    [ -n "$target_ip" ] && printf "target %s\n" "$target_ip"
    printf "%s\n" "$output"
  } > "$trace_file"
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
      return c sprintf("%-10s", label) nc
    }
    {
      status = $1
      prov = $2
      isp = $3
      proto = toupper($4)
      label = $6
      if (status == "LIMIT") label = "LIMIT"
      if (status == "FAIL") label = label == "" ? "FAIL" : label
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
  local family=4 idx=0 entry prov isp host protocol route_raw_file route_file ip_file cymru_file asn_map_file
  local route_parallel="$PARALLEL"
  local -a protocols=()
  if [ "$ROUTE_PROTOCOL" = "both" ]; then
    protocols=(tcp udp)
  else
    protocols=("$ROUTE_PROTOCOL")
  fi

  check_curl
  require_remote_nodes v4
  check_traceroute
  if ! ipv4_available; then
    echo -e "${RED}[X] 未检测到可用 IPv4，暂不执行线路识别${NC}"
    exit 1
  fi

  local route_node_count
  route_node_count=$(count_cdn_nodes "$family")
  TOTAL=$((route_node_count * ${#protocols[@]}))
  if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}[X] 指定省份没有可执行的线路检测任务${NC}"
    exit 1
  fi
  echo -e "${DIM}  检测范围: $(province_filter_text)  线路检测节点: $TOTAL  协议: $ROUTE_PROTOCOL  并行: $route_parallel${NC}"
  echo -e "${YELLOW}  [!] 线路检测使用 traceroute，本地探测完成后批量查询 Team Cymru ASN。${NC}"
  echo ""

  show_progress
  for protocol in "${protocols[@]}"; do
    while IFS='|' read -r prov isp host fixed_ip port; do
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
        show_progress
        sleep 0.2
      done
      port=${port:-80}
      route_trace_one "$family" "$protocol" "$prov" "$isp" "$host" "$idx" "$port" "$fixed_ip" &
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
    [ -f "${RESULT_DIR}/route_${idx}" ] && cat "${RESULT_DIR}/route_${idx}" >> "$route_raw_file"
    [ -f "${RESULT_DIR}/route_trace_${idx}" ] && extract_trace_ips "${RESULT_DIR}/route_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    query_cymru_asn "$ip_file" "$cymru_file"
    build_asn_map "$cymru_file" "$asn_map_file"
  fi

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_raw_file" "${RESULT_DIR}/route_raw.txt"
    cp "$ip_file" "${RESULT_DIR}/route_ips.txt"
    cp "$cymru_file" "${RESULT_DIR}/route_cymru.txt"
    cp "$asn_map_file" "${RESULT_DIR}/route_asn_map.txt"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = "TRACE" ] && [ -f "${RESULT_DIR}/route_trace_${value}" ]; then
      trace_ip_file="${RESULT_DIR}/route_trace_${value}.ips"
      extract_trace_ips "${RESULT_DIR}/route_trace_${value}" > "$trace_ip_file"
      label=$(route_label_from_ip_trace "${RESULT_DIR}/route_trace_${value}" "$asn_map_file" "$trace_ip_file")
      echo "OK|$prov|$isp|$protocol|$host|$label" >> "$route_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|$protocol|$host|$value" >> "$route_file"
    fi
  done < "$route_raw_file"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_file" "${RESULT_DIR}/route_final.txt"
  fi

  clear
  print_header
  echo -e "  ${DIM}报告时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')${NC}"
  echo ""
  show_route_results "$route_file"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo -e "  ${DIM}Debug: traces=$(ls "${RESULT_DIR}"/route_trace_* 2>/dev/null | wc -l | tr -d ' ') ips=$(wc -l < "$ip_file" | tr -d ' ') cymru=$(grep -c '|' "$cymru_file" 2>/dev/null || echo 0) asn_map=$(wc -l < "$asn_map_file" | tr -d ' ')${NC}"
    echo -e "  ${DIM}Debug 目录：$RESULT_DIR${NC}"
    echo ""
  fi
  rm -f "$route_raw_file" "$route_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

collect_route_labels() {
  local family="$1" out_file="$2" idx=0 entry prov isp host route_total route_raw_file ip_file cymru_file asn_map_file trace_ip_file status protocol value label prefix
  local route_parallel="$PARALLEL"
  prefix="summary_route${family}"
  route_total=0
  while IFS='|' read -r prov isp host _; do
    province_selected "$prov" && route_total=$((route_total + 1))
  done < <(print_cdn_entries "$family")
  [ "$route_total" -eq 0 ] && return 0

  while IFS='|' read -r prov isp host fixed_ip port; do
    province_selected "$prov" || continue
    port=${port:-80}
    idx=$((idx + 1))
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
      sleep 0.2
    done
    route_trace_one "$family" tcp "$prov" "$isp" "$host" "$idx" "$port" "$fixed_ip" "$prefix" &
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
      label=$(route_label_from_ip_trace "${RESULT_DIR}/${prefix}_trace_${value}" "$asn_map_file" "$trace_ip_file")
      echo "OK|$prov|$isp|tcp|$host|$label" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|tcp|$host|${value:-Hidden}" >> "$out_file"
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

set_route_progress_total() {
  local has_v4="$1" has_v6="$2"
  ROUTE_PROGRESS_TOTAL=0
  if [ "$has_v4" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_selected_cdn_nodes 4)))
  fi
  if [ "$has_v6" -eq 1 ]; then
    ROUTE_PROGRESS_TOTAL=$((ROUTE_PROGRESS_TOTAL + $(count_selected_cdn_nodes 6)))
  fi
  return 0
}

start_route_background() {
  local route_labels_v4="$1" route_labels_v6="$2" has_v4="$3" has_v6="$4"
  [ "$ROUTE_PROGRESS_TOTAL" -gt 0 ] || return 0
  (
    if [ "$has_v4" -eq 1 ]; then
      collect_route_labels 4 "$route_labels_v4"
    fi
    if [ "$has_v6" -eq 1 ]; then
      collect_route_labels 6 "$route_labels_v6"
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
  if [ "$family" = "6" ]; then
    if ! route_data=$(get_ipv6_route "$ip"); then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|IPV6_ROUTE_ERROR"
      return
    fi
    IFS='|' read -r iface source_ip source_mac dest_mac <<< "$route_data"
    nping_base_args=(-6 -e "$iface" -S "$source_ip" --source-mac "$source_mac" --dest-mac "$dest_mac" "${nping_base_args[@]}")
  fi

  local sent=0 rcvd=0 loss_pct avg_rtt rtt_sum="0" one_sent one_rcvd one_rtt one_success i packet_size payload_size header_size
  header_size=40
  [ "$family" = "6" ] && header_size=60
  for ((i = 1; i <= PACKETS; i++)); do
    if [ -n "$PACKET_SIZE_OVERRIDE" ]; then
      packet_size="$PACKET_SIZE_OVERRIDE"
    else
      packet_size="${PACKET_SIZES[$((RANDOM % ${#PACKET_SIZES[@]}))]}"
    fi
    payload_size=0
    [ "$packet_size" -gt 0 ] && payload_size=$((packet_size - header_size))
    [ "$payload_size" -lt 0 ] && payload_size=0
    if [ "$packet_size" -eq 0 ]; then
      if raw=$(nping "${nping_base_args[@]}" -c 1 "$ip" 2>&1); then
        nping_rc=0
      else
        nping_rc=$?
      fi
    elif raw=$(nping "${nping_base_args[@]}" --data-length "$payload_size" -c 1 "$ip" 2>&1); then
      nping_rc=0
    else
      nping_rc=$?
    fi

    one_sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rtt=$(printf "%s\n" "$raw" | sed -nE 's/.*Avg rtt:[[:space:]]*([0-9.]+).*/\1/p' | head -1)

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

  if [ "$p_status" = "OK" ] && [ -n "$backup_ip" ] && awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 > 15) }'; then
    backup_result=$(probe_target "$group" "$family" "$prov" "$isp" "$backup_host" "$backup_ip" "$backup_port" "$idx" backup)
    IFS='|' read -r b_status _ _ _ _ _ _ b_loss _ <<< "$backup_result"
    if [ "$DEBUG_MODE" -eq 1 ]; then
      printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$group" "$idx" "$prov" "$isp" "$p_loss" "$backup_host" "$backup_ip" "$backup_result" >> "${RESULT_DIR}/backup_retry_meta.txt"
    fi
    if awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 >= 100) }'; then
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

export -f probe_target
export -f combine_probe_results
export -f test_one
export -f get_ipv6_route
export -f is_public_ipv4
export RESULT_DIR PACKETS PACKET_SIZES PACKET_SIZE_OVERRIDE

# ===================== 国内分阶段测速 =====================
SPEEDTEST_RATES=(10 200 unlimited)
SPEEDTEST_IFB="ifb_tqtest"
SPEEDTEST_IFACE=""
SPEEDTEST_CREATED_IFB=0
SPEEDTEST_TELECOM_ID=""
SPEEDTEST_TELECOM_CITY=""
SPEEDTEST_UNICOM_ID=""
SPEEDTEST_UNICOM_CITY=""
SPEEDTEST_MOBILE_ID=""
SPEEDTEST_MOBILE_CITY=""
SPEEDTEST_ROWS=()

speedtest_candidates() {
  case "$1" in
    电信)
      printf '%s\n' '59386|杭州' '59387|宁波' '5396|苏州' '36663|镇江'
      ;;
    联通)
      printf '%s\n' '43752|北京' '24447|上海' '37695|香港'
      ;;
    移动)
      printf '%s\n' '16204|苏州' '54312|杭州' '60584|深圳' '60794|广州' '4575|成都' '25858|北京'
      ;;
  esac
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
  if [ -n "${SPEEDTEST_IFACE:-}" ]; then
    tc qdisc del dev "$SPEEDTEST_IFACE" root 2>/dev/null || true
    tc qdisc del dev "$SPEEDTEST_IFACE" ingress 2>/dev/null || true
  fi
  tc qdisc del dev "$SPEEDTEST_IFB" root 2>/dev/null || true
  if [ "${SPEEDTEST_CREATED_IFB:-0}" -eq 1 ]; then
    ip link set "$SPEEDTEST_IFB" down 2>/dev/null || true
    ip link delete "$SPEEDTEST_IFB" type ifb 2>/dev/null || true
    SPEEDTEST_CREATED_IFB=0
  fi
}

speedtest_dependencies_ready() {
  local cmd
  for cmd in ip tc nstat modprobe jq curl; do
    command -v "$cmd" &>/dev/null || return 1
  done
}

install_speedtest_dependencies() {
  if is_nixos; then
    echo -e "${RED}[X] Nix 临时环境中的 Speedtest 依赖不完整${NC}" >&2
    return 1
  fi
  show_dependency_install_notice
  if command -v apt-get &>/dev/null; then
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq \
      iproute2 kmod jq curl ca-certificates gnupg >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then
    $USE_SUDO dnf install -y -q iproute kmod jq curl ca-certificates gnupg2 >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    $USE_SUDO yum install -y -q iproute kmod jq curl ca-certificates gnupg2 >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    $USE_SUDO apk add --no-cache iproute2 kmod jq curl ca-certificates gnupg >/dev/null 2>&1
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

is_ookla_speedtest() {
  local version
  command -v speedtest &>/dev/null || return 1
  version=$(speedtest --version 2>&1 || true)
  printf '%s' "$version" | grep -qi 'ookla'
}

install_ookla_speedtest() {
  local installer
  if is_nixos; then
    echo -e "${RED}[X] 未找到 Ookla Speedtest；请直接使用 --speedtest 重新运行脚本${NC}" >&2
    return 1
  fi
  show_dependency_install_notice

  if command -v apt-get &>/dev/null; then
    if dpkg-query -W -f='${Status}' speedtest-cli 2>/dev/null | grep -q 'install ok installed'; then
      $USE_SUDO apt-get purge -y -qq speedtest-cli >/dev/null 2>&1 || return 1
    fi
    installer=$(mktemp /tmp/ookla-repo.XXXXXX.sh)
    curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh \
      -o "$installer" || return 1
    $USE_SUDO bash "$installer" >/dev/null 2>&1 || return 1
    rm -f "$installer"
    $USE_SUDO apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive $USE_SUDO apt-get install -y -qq speedtest >/dev/null 2>&1 || return 1
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    installer=$(mktemp /tmp/ookla-repo.XXXXXX.sh)
    curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh \
      -o "$installer" || return 1
    $USE_SUDO bash "$installer" >/dev/null 2>&1 || return 1
    rm -f "$installer"
    if command -v dnf &>/dev/null; then
      $USE_SUDO dnf install -y -q speedtest >/dev/null 2>&1 || return 1
    else
      $USE_SUDO yum install -y -q speedtest >/dev/null 2>&1 || return 1
    fi
  else
    return 1
  fi
  hash -r
  if is_ookla_speedtest; then
    clear_dependency_install_notice
    return 0
  fi
  clear_dependency_install_notice
  return 1
}

speedtest_retrans_count() {
  nstat -az 2>/dev/null | awk '$1=="TcpRetransSegs"{print $2; found=1} END{if(!found) print 0}'
}

speedtest_apply_limit() {
  local rate="$1"
  speedtest_cleanup
  if [ "$rate" = "unlimited" ]; then
    return 0
  fi

  modprobe ifb >/dev/null 2>&1 || return 1
  if ! ip link show "$SPEEDTEST_IFB" >/dev/null 2>&1; then
    ip link add "$SPEEDTEST_IFB" type ifb >/dev/null 2>&1 || return 1
    SPEEDTEST_CREATED_IFB=1
  fi
  ip link set "$SPEEDTEST_IFB" up >/dev/null 2>&1 || return 1
  tc qdisc add dev "$SPEEDTEST_IFACE" root tbf rate "${rate}mbit" burst 1mb latency 500ms >/dev/null 2>&1 || return 1
  tc qdisc add dev "$SPEEDTEST_IFACE" handle ffff: ingress >/dev/null 2>&1 || return 1
  tc filter add dev "$SPEEDTEST_IFACE" parent ffff: protocol all u32 \
    match u32 0 0 action mirred egress redirect dev "$SPEEDTEST_IFB" >/dev/null 2>&1 || return 1
  tc qdisc add dev "$SPEEDTEST_IFB" root tbf rate "${rate}mbit" burst 1mb latency 500ms >/dev/null 2>&1 || return 1
}

speedtest_result_valid() {
  local file="$1"
  jq -e '.type == "result" and (.download.bandwidth | numbers) and (.upload.bandwidth | numbers)' \
    "$file" >/dev/null 2>&1
}

speedtest_run_node() {
  local server_id="$1" output_file="$2"
  speedtest --accept-license --accept-gdpr -s "$server_id" -f json --progress=no \
    >"$output_file" 2>"${output_file}.err" || return 1
  speedtest_result_valid "$output_file"
}

speedtest_run_carrier() {
  local carrier="$1" output_file="$2"
  local selected_id selected_city
  local candidate server_id city
  selected_id=$(speedtest_selected_id "$carrier")
  selected_city=$(speedtest_selected_city "$carrier")

  if [ -n "$selected_id" ] && speedtest_run_node "$selected_id" "$output_file"; then
    return 0
  fi
  speedtest_set_selected "$carrier" "" ""

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    server_id=${candidate%%|*}
    city=${candidate#*|}
    [ "$server_id" = "$selected_id" ] && continue
    if speedtest_run_node "$server_id" "$output_file"; then
      speedtest_set_selected "$carrier" "$server_id" "$city"
      return 0
    fi
  done < <(speedtest_candidates "$carrier")

  if [ -n "$selected_id" ]; then
    speedtest_set_selected "$carrier" "$selected_id" "$selected_city"
  fi
  return 1
}

speedtest_format_mbps() {
  local bandwidth="$1"
  awk -v bytes="$bandwidth" 'BEGIN{printf "%.1f", bytes*8/1000000}'
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
  local label="$1" title
  [ "$label" = "不限" ] && title='不限速' || title="限速 $label"

  # The terminal formatter counts UTF-8 bytes, so align CJK headings by display width.
  printf '  '
  printf '%b' "$CYAN"
  speedtest_pad_center 54 "$title"
  printf '%b' "$NC"
  printf '\n'
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '地区'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 10 '回程重传'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '回程速度'; printf '%b' "$NC"
  printf '  '
  printf '%b' "$CYAN"; speedtest_pad_left 12 '去程速度'; printf '%b' "$NC"
  printf '\n'
}

speedtest_speed_text() {
  local value="$1"
  if [ "$value" = "failed" ]; then
    printf 'failed'
  else
    printf '%sMbps' "$value"
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
  elif [ "$label" = "不限" ]; then
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
      diff = (value - target) / target
      if (diff < 0) diff = -diff
      if (diff <= 0.20) print "ok"
      else if (diff <= 0.50) print "warn"
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
  if [ "$value" = "failed" ] || [ "$value" -gt 999 ] 2>/dev/null; then
    printf '%s' "$RED"
  elif [ "$value" -ge 100 ] 2>/dev/null; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

collect_speedtest_results() {
  local rate label carrier workdir result_file before after retrans index
  local upload download result row done total offset
  local carriers=(电信 联通 移动)
  local carrier_values=()
  local rates=("$@")
  [ "${#rates[@]}" -gt 0 ] || rates=("${SPEEDTEST_RATES[@]}")
  offset=${SPEEDTEST_PROGRESS_OFFSET:-0}
  done="$offset"
  total=${SPEEDTEST_PROGRESS_TOTAL:-0}
  [ "$total" -gt 0 ] 2>/dev/null || total=$((offset + ${#rates[@]} * ${#carriers[@]}))

  if [ "${SPEEDTEST_APPEND_STATE:-0}" -eq 1 ]; then
    speedtest_load_background_state || true
  else
    SPEEDTEST_ROWS=()
  fi

  [ "$(uname)" = "Linux" ] || {
    echo -e "${RED}[X] 分阶段 Speedtest 目前仅支持 Linux${NC}"
    exit 1
  }
  require_raw_socket_privilege
  check_curl
  speedtest_dependencies_ready || install_speedtest_dependencies || {
    echo -e "${RED}[X] 测速依赖安装失败${NC}"
    exit 1
  }
  is_ookla_speedtest || install_ookla_speedtest || {
    echo -e "${RED}[X] Ookla Speedtest 安装失败${NC}"
    exit 1
  }

  SPEEDTEST_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$SPEEDTEST_IFACE" ] || {
    echo -e "${RED}[X] 无法识别默认网络接口${NC}"
    exit 1
  }
  if [ "${SPEEDTEST_BACKGROUND:-0}" -eq 1 ]; then
    trap 'speedtest_cleanup' EXIT
    trap 'speedtest_cleanup; exit 130' INT TERM
  fi

  echo -e "${BOLD}${CYAN}国内三网分阶段 Speedtest${NC}"
  echo
  speedtest_show_progress 0 "$total"

  for rate in "${rates[@]}"; do
    speedtest_apply_limit "$rate" || {
      echo -e "${RED}[X] 无法应用 ${rate} Mbps 限速${NC}"
      exit 1
    }
    sleep 2
    carrier_values=()

    for carrier in "${carriers[@]}"; do
      workdir=$(mktemp -d "$RESULT_DIR/speedtest.XXXXXX")
      result_file="$workdir/result.json"
      before=$(speedtest_retrans_count)
      if speedtest_run_carrier "$carrier" "$result_file"; then
        after=$(speedtest_retrans_count)
        retrans=$((after - before))
        [ "$retrans" -ge 0 ] || retrans=0
        upload=$(jq -r '.upload.bandwidth' "$result_file")
        download=$(jq -r '.download.bandwidth' "$result_file")
        carrier_values+=("$(speedtest_format_mbps "$upload")|$retrans|$(speedtest_format_mbps "$download")")
      else
        carrier_values+=("failed|failed|failed")
      fi
      done=$((done + 1))
      speedtest_show_progress "$done" "$total"
    done

    label="${rate}Mbps"
    [ "$rate" = "unlimited" ] && label="不限"
    SPEEDTEST_ROWS+=("$label;${carrier_values[0]};${carrier_values[1]};${carrier_values[2]}")
  done

  speedtest_cleanup
  if [ -n "${SPEEDTEST_STATE_FILE:-}" ]; then
    {
      printf 'META\t%s|%s|%s|%s|%s|%s\n' \
        "$SPEEDTEST_TELECOM_ID" "$SPEEDTEST_TELECOM_CITY" \
        "$SPEEDTEST_UNICOM_ID" "$SPEEDTEST_UNICOM_CITY" \
        "$SPEEDTEST_MOBILE_ID" "$SPEEDTEST_MOBILE_CITY"
      printf 'ROW\t%s\n' "${SPEEDTEST_ROWS[@]}"
    } > "$SPEEDTEST_STATE_FILE"
  fi
  echo
}

speedtest_set_failed_rows() {
  SPEEDTEST_ROWS=()
  local rate label
  for rate in "${SPEEDTEST_RATES[@]}"; do
    label="${rate}Mbps"
    [ "$rate" = "unlimited" ] && label="不限"
    SPEEDTEST_ROWS+=("$label;failed|failed|failed;failed|failed|failed;failed|failed|failed")
  done
}

speedtest_load_background_state() {
  local type value a b c d e f
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
  local row label result1 result2 result3 result upload retrans download index carrier region upload_text download_text
  local speed_color retrans_color
  local carriers=(电信 联通 移动)
  local results=()
  echo -e "${BOLD}${CYAN}国内三网分阶段 Speedtest${NC}"
  echo
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -r label result1 result2 result3 <<<"$row"
    speedtest_print_group_header "$label"
    results=("$result1" "$result2" "$result3")
    for index in "${!results[@]}"; do
      result="${results[$index]}"
      carrier="${carriers[$index]}"
      region=$(speedtest_carrier_title "$carrier")
      IFS='|' read -r upload retrans download <<<"$result"
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
      printf '\n'
    done
    echo
  done
}

append_speedtest_csv() {
  local csv="$1" row label result1 result2 result3 result upload retrans download index carrier
  local carriers=(电信 联通 移动)
  for row in "${SPEEDTEST_ROWS[@]}"; do
    IFS=';' read -r label result1 result2 result3 <<<"$row"
    index=0
    for result in "$result1" "$result2" "$result3"; do
      carrier="${carriers[$index]}"
      IFS='|' read -r upload retrans download <<<"$result"
      if [ "$upload" = "failed" ]; then
        printf 'Speedtest,%s,%s,%s,,,%s,%s,%s,%s,,\n' \
          "$label" "$carrier" "$(speedtest_selected_city "$carrier")" "FAIL" "$upload" "$retrans" "$download" >> "$csv"
      else
        printf 'Speedtest,%s,%s,%s,%s,,%s,%s,%s,%s,,\n' \
          "$label" "$carrier" "$(speedtest_selected_city "$carrier")" "$(speedtest_selected_id "$carrier")" \
          "OK" "$upload" "$retrans" "$download" >> "$csv"
      fi
      index=$((index + 1))
    done
  done
}

run_speedtest_mode() {
  local report_time csv
  collect_speedtest_results
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  csv="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$csv"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路" >> "$csv"
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

  if [ "$SPEEDTEST_ONLY" -eq 1 ]; then
    run_speedtest_mode
    exit 0
  fi

  if [ "$ROUTE_MODE" -eq 1 ]; then
    check_curl
    detect_ip_stack
    run_route_mode
    exit 0
  fi

  require_raw_socket_privilege
  check_curl
  require_remote_nodes
  check_nping
  detect_ip_stack

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

  if [ "$TEST_CERNET" -eq 1 ] && [ "$TEST_ALL" -eq 0 ]; then
    test_cdn=0
    test_edu=1
  elif [ "$TEST_CERNET" -eq 1 ] || [ "$TEST_ALL" -eq 1 ]; then
    test_edu=1
  fi

  local cdn_node_count cernet_node_count cernet2_node_count
  local cdn4_node_count cdn6_node_count
  cdn4_node_count=$(count_cdn_nodes 4)
  cdn6_node_count=$(count_cdn_nodes 6)
  cdn_node_count="$cdn4_node_count"
  cernet_node_count=$(count_cernet_nodes)
  cernet2_node_count=$(count_cernet2_nodes)

  TOTAL=0
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + cdn4_node_count)); fi
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + cernet_node_count)); fi
  if [ "$want_ipv6" -eq 1 ] && ipv6_available; then
    ipv6_enabled=1
    if [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + cdn6_node_count)); fi
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
  local size_text="${PACKET_SIZE_OVERRIDE}B"
  echo -e "${DIM}  检测范围: $(province_filter_text)  探测节点: $TOTAL  每节点发包: $PACKETS  包长: $size_text  并行: $PARALLEL  端口: 80/tcp${NC}"
  echo ""

  local family entry prov isp host fixed_ip port backup_host backup_ip backup_port
  local -a families=()
  if [ "$test_cdn" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then families+=(4); fi
    if [ "$ipv6_enabled" -eq 1 ]; then families+=(6); fi
    [ "${#families[@]}" -gt 0 ] && check_traceroute
  fi

  local sorted_v4 sorted_v6 sorted_cernet sorted_cernet2 route_labels_v4 route_labels_v6 sorted_file f i status ip snd rcv loss lat route_label route_file
  sorted_v4=$(mktemp)
  sorted_v6=$(mktemp)
  sorted_cernet=$(mktemp)
  sorted_cernet2=$(mktemp)
  route_labels_v4=$(mktemp)
  route_labels_v6=$(mktemp)

  # 三个阶段严格串行，避免路由与测速流量影响延迟重传结果。
  SPEEDTEST_PROGRESS_TOTAL=0
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    SPEEDTEST_PROGRESS_TOTAL=$((${#SPEEDTEST_RATES[@]} * 3))
  fi
  if [ "$test_cdn" -eq 1 ]; then
    set_route_progress_total "$ipv4_enabled" "$ipv6_enabled"
  fi
  echo -e "  ${DIM}正在检测，请稍候...${NC}"
  MULTI_PROGRESS_MODE=1

  local idx=0
  show_progress
  if [ "$test_cdn" -eq 1 ]; then
    for family in "${families[@]}"; do
      while IFS='|' read -r prov isp host fixed_ip port backup_host backup_ip backup_port; do
        port=${port:-80}
        province_selected "$prov" || continue
        idx=$((idx + 1))
        while [ $((idx - $(count_results))) -ge "$PARALLEL" ]; do
          show_progress
          sleep 0.2
        done
        test_one "cdn${family}" "$family" "$prov" "$isp" "$host" "$idx" "$fixed_ip" "$port" "$backup_host" "$backup_ip" "${backup_port:-80}" &
        show_progress
      done < <(print_cdn_entries "$family")
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    while IFS='|' read -r prov host fixed_ip port; do
      port=${port:-80}
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ $((idx - $(count_results))) -ge "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet" 4 "$prov" "教育网" "$host" "$idx" "$fixed_ip" "$port" &
      show_progress
    done < <(print_cernet_entries)
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    while IFS='|' read -r prov host fixed_ip port; do
      port=${port:-80}
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ $((idx - $(count_results))) -ge "$PARALLEL" ]; do
        show_progress
        sleep 0.2
      done
      test_one "cernet2" 6 "$prov" "教育网" "$host" "$idx" "$fixed_ip" "$port" &
      show_progress
    done < <(print_cernet2_entries)
  fi
  while [ $((idx - $(count_results))) -gt 0 ]; do
    show_progress
    sleep 0.2
  done
  show_progress

  if [ "$test_cdn" -eq 1 ]; then
    start_route_background "$route_labels_v4" "$route_labels_v6" "$ipv4_enabled" "$ipv6_enabled"
    wait_route_background
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    start_speedtest_background 0 0 "${SPEEDTEST_RATES[@]}"
    wait_speedtest_background
  fi
  show_progress
  printf '\n'

  # 收集结果并写入 CSV
  local report_time
  report_time=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')
  local CSV="/tmp/zstatic_nping_$(date +%Y%m%d_%H%M%S).csv"
  printf '\xEF\xBB\xBF' > "$CSV"
  echo "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路" >> "$CSV"

  if [ "$test_cdn" -eq 1 ]; then
    for family in "${families[@]}"; do
      if [ "$family" = "4" ]; then sorted_file="$sorted_v4"; else sorted_file="$sorted_v6"; fi
      if [ "$family" = "4" ]; then route_file="$route_labels_v4"; else route_file="$route_labels_v6"; fi
      for i in $(seq 1 "$TOTAL"); do
        f="${RESULT_DIR}/cdn${family}_${i}"
        if [ -f "$f" ]; then
          IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
          route_label=$(awk -F'|' -v p="$prov" -v i="$isp" '$2 == p && $3 == i { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$route_file")
          echo "三网,IPv${family},$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat,$route_label" >> "$CSV"
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
        echo "CERNET,IPv4,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat," >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_cernet"
      fi
    done
  fi
  if [ "$test_edu" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    for i in $(seq 1 "$TOTAL"); do
      f="${RESULT_DIR}/cernet2_${i}"
      if [ -f "$f" ]; then
        IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
        echo "CERNET2,IPv6,$prov,$isp,$host,$ip,$status,$snd,$rcv,$loss,$lat," >> "$CSV"
        echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat" >> "$sorted_cernet2"
      fi
    done
  fi
  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    append_speedtest_csv "$CSV"
  fi

  # ---- TUI 结果展示 ----
  clear
  print_header
  echo -e "  ${DIM}报告时间：${report_time}${NC}"
  echo ""

  if [ "$test_cdn" -eq 1 ]; then
    if [ "$ipv4_enabled" -eq 1 ]; then
      show_family_results "IPv4" "$sorted_v4" "$route_labels_v4"
    fi
    if [ "$ipv6_enabled" -eq 1 ]; then
      show_family_results "IPv6" "$sorted_v6" "$route_labels_v6"
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

  if [ "$SPEEDTEST_ENABLED" -eq 1 ]; then
    show_speedtest_results
    echo
  fi

  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    upload_report "$CSV" "${report_time%%（*}"
  fi
  echo ""

  rm -f "$sorted_v4" "$sorted_v6" "$sorted_cernet" "$sorted_cernet2" "$route_labels_v4" "$route_labels_v6"
}

parse_args "$@"
main
