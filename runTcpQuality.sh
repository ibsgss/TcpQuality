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

USE_SUDO=""
IPV4_PUBLIC=""
IPV6_PUBLIC=""
IPV4_WORK=0
IPV6_WORK=0

# ===================== 依赖与权限检查 =====================
init_privilege() {
  USE_SUDO=""
  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
      USE_SUDO="sudo"
    fi
  fi
}

install_with_package_manager() {
  local dep="$1"
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
  echo -e "${YELLOW}[!] $desc 未安装，正在自动安装...${NC}"
  if install_with_package_manager "$desc" "$apt_pkg" "$dnf_pkg" "$yum_pkg" "$apk_pkg" "$pacman_pkg" "$brew_pkg" && command -v "$cmd" &>/dev/null; then
    echo -e "${GREEN}[√] $desc 安装成功${NC}"
  else
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
  echo -e "${YELLOW}[!] nping 未安装，正在自动安装...${NC}"
  if command -v apk &>/dev/null; then
    if ! install_with_package_manager nping nmap nmap nmap nmap-nping nmap nmap; then
      install_with_package_manager nping nmap nmap nmap nmap nmap nmap || true
    fi
  else
    install_with_package_manager nping nmap nmap nmap nmap nmap nmap || true
  fi
  if command -v nping &>/dev/null; then
    echo -e "${GREEN}[√] nping 安装成功${NC}"
  else
    echo -e "${RED}[X] nping 安装失败${NC}"
    exit 1
  fi
}

check_dig() {
  if command -v dig &>/dev/null; then
    return 0
  fi
  echo -e "${YELLOW}[!] dig 未安装，正在自动安装...${NC}"
  if install_with_package_manager dig dnsutils bind-utils bind-utils bind-tools bind bind; then
    if ! command -v dig &>/dev/null && command -v brew &>/dev/null; then
      export PATH="$(brew --prefix bind)/bin:$PATH"
    fi
  fi
  if ! command -v dig &>/dev/null && command -v brew &>/dev/null; then
    export PATH="$(brew --prefix bind)/bin:$PATH"
  fi
  if command -v dig &>/dev/null; then
    echo -e "${GREEN}[√] dig 安装成功${NC}"
  else
    echo -e "${RED}[X] dig 安装失败${NC}"
    exit 1
  fi
}

check_traceroute() {
  check_command traceroute traceroute traceroute traceroute traceroute traceroute traceroute traceroute
}

require_raw_socket_privilege() {
  if [ "$(uname)" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[X] 运行权限不足，请切换到 root 用户后运行${NC}"
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

fallback_city_codes() {
  case "$1" in
    河北) echo "sjz ts qhd hd xt bd zjk cd cz lf hs" ;;
    山西) echo "ty dt yq cz jc sz jz yc xz lf ll" ;;
    辽宁) echo "sy dl as fs bx dd jz yk fx ly pj tl cy hl" ;;
    吉林) echo "cc jl sp ly th bs ss bc yb" ;;
    黑龙江) echo "hrb qqhr jx hegang sys dq yc jms qth mdj hh suihua dxal" ;;
    江苏) echo "nj wx xz cz sz nt lyg ha yc yz zj tz sq" ;;
    浙江) echo "hz nb wz jx huz sx jh qz zs tz ls" ;;
    安徽) echo "hf wh bb hn mas hb tl aq hs cz fy sz la ha cz2 xc" ;;
    福建) echo "fz xm pt sm qz zz np ly nd" ;;
    江西) echo "nc jdz px jj xy yt gz ja yc fz sr" ;;
    山东) echo "jn qd zb zz dy yt wf jn2 ta wh rz lw ly dz lc bz hz" ;;
    河南) echo "zz kf ly pds ay hb xx jz py xc lh smx ny sq xy zk zmd" ;;
    湖北) echo "wh hs sy yc xf ez jm xg hg xn sz es" ;;
    湖南) echo "cs zz xt hy sy yy cd zjj yyi cz yz hh ld xx" ;;
    广东) echo "gz sz zh st fs sg zj mm hz mz sw hy yj qy dg zs cz jy yf" ;;
    海南) echo "hk sy dz qh wzs" ;;
    四川) echo "cd zg pzh lz dy my gy sn nj ls nc yb ga dz bz ya ms zy ab gz lsz" ;;
    贵州) echo "gy lps zy as tr qxn bj qdn qn" ;;
    云南) echo "km qj yx bs zt lj pe lc cx hh ws xsbn dl dh nj dq" ;;
    陕西) echo "xa xian xy wn yl ak hz bj tc sl" ;;
    甘肃) echo "lz jy jc by ts ww zy pl jq qx dx ln gn" ;;
    青海) echo "xn hd hb hn hainan gl ys hx" ;;
    内蒙古) echo "hhht bt wh cf tl eeds hlbe byne wlcb xlgl als" ;;
    广西) echo "nn lz gl wz bh fcg qz gg yl bs hz hc lb cz" ;;
    西藏) echo "ls rkz cd lz sn nq al" ;;
    宁夏) echo "yc szs wz gy zw" ;;
    新疆) echo "wlmq klmy tlf hami changji bozhou bygl aks kzls ks ht yl tc altay" ;;
    北京) echo "bj" ;;
    天津) echo "tj" ;;
    上海) echo "sh" ;;
    重庆) echo "cq" ;;
  esac
}

isp_code() {
  case "$1" in
    电信) echo "ct" ;;
    联通) echo "cu" ;;
    移动) echo "cm" ;;
    *) return 1 ;;
  esac
}

fallback_hosts() {
  local prov="$1" isp="$2" family="$3" primary_host="$4" code isp_suffix host
  isp_suffix=$(isp_code "$isp") || return 0
  for code in $(fallback_city_codes "$prov"); do
    host="${code}-${isp_suffix}-v${family}.ip.zstaticcdn.com"
    [ "$host" = "$primary_host" ] && continue
    printf "%s\n" "$host"
  done
}

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
PACKET_SIZES=(40 80 160 320 640 1200)
NODE_TOTAL=${#NODES[@]}
TOTAL=$NODE_TOTAL
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
REPORT_API=${TCPQUALITY_REPORT_API:-https://tcpquality.ibsgss.uk/generate}
RESULT_DIR=$(mktemp -d)
cleanup_result_dir() {
  if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    echo -e "${DIM}Debug 目录：$RESULT_DIR${NC}"
  else
    rm -rf "$RESULT_DIR"
  fi
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
  local entry prov isp host count=0
  for entry in "${NODES[@]}"; do
    read -r prov isp host <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

count_cernet_nodes() {
  local entry prov host ip count=0
  for entry in "${CERNET_NODES[@]}"; do
    read -r prov host ip <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

count_cernet2_nodes() {
  local entry prov host ip count=0
  for entry in "${CERNET2_NODES[@]}"; do
    read -r prov host ip <<< "$entry"
    province_selected "$prov" && count=$((count + 1))
  done
  echo "$count"
}

# ===================== 参数与帮助 =====================
show_help() {
  cat <<EOF
TcpQuality 节点 TCP 丢包探测脚本

用法:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) [选项]

选项:
  -h, --help        显示帮助信息并退出
  -c, --count NUM   设置每节点发包数，默认 ${PACKETS}
                     每次随机目标包长: ${PACKET_SIZES[*]}B
  -p, --parallel NUM
                     设置并行节点数，范围 1-31，默认 ${PARALLEL}
  -v4, --v4         仅探测 IPv4
  -v6, --v6         仅探测 IPv6
  --cernet          仅探测 CERNET IPv4 和 CERNET2 IPv6
  --all             探测三网、CERNET 和 CERNET2
  --province CODE   仅检测指定省份，可重复；也支持简写参数如 -bj、-sh、-gd
                     注意: 山西使用 -sx，陕西使用 -sn
  --debug           保留临时文件并输出调试信息，便于排查线路识别问题

示例:
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -c 100
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh) -bj -v4 --cernet

依赖:
  - nping: 随 nmap 安装
  - curl: 用于检测公网 IPv4/IPv6 与上传报告
  - dig: 用于解析节点域名
  - traceroute: 用于自动识别三网 TCP 回程线路
  - awk/sed/grep: 用于结果解析和展示

安装提示:
  - Debian/Ubuntu: apt-get install -y curl nmap dnsutils traceroute
  - RHEL/Fedora:   dnf install -y curl nmap bind-utils traceroute
  - Alpine Linux:  apk add curl nmap-nping bind-tools traceroute
  - Arch Linux:    pacman -S curl nmap bind traceroute
  - macOS:         brew install curl nmap bind traceroute

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
    find "$RESULT_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
  fi
}

show_progress() {
  local done
  done=$(count_results)
  [ "$done" -gt "$TOTAL" ] && done="$TOTAL"
  echo -ne "\r  ${CYAN}探测进度${NC} "
  bar "$done" "$TOTAL"
  echo -ne "   "
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

resolve_route_target_ip() {
  local family="$1" host="$2" rr="A"
  [ "$family" = "6" ] && rr="AAAA"
  dig +time=3 +tries=1 +short "$host" "$rr" 2>/dev/null | awk '
    /^[0-9.]+$/ || /^[0-9a-fA-F:]+$/ { print; exit }
  '
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
  local family="$1" protocol="$2" prov="$3" isp="$4" host="$5" idx="$6"
  local outfile="${RESULT_DIR}/route_${idx}" trace_file="${RESULT_DIR}/route_trace_${idx}"
  local probe_arg="-T"
  [ "$protocol" = "udp" ] && probe_arg="-U"
  local -a args=(-n "-${family}" "$probe_arg" -p 80 -q 3 -w 2 -m 30 "$host" 44)
  local output rc target_ip

  target_ip=$(resolve_route_target_ip "$family" "$host")

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

  check_dig
  check_traceroute
  if ! ipv4_available; then
    echo -e "${RED}[X] 未检测到可用 IPv4，暂不执行线路识别${NC}"
    exit 1
  fi

  local route_node_count
  route_node_count=$(count_cdn_nodes)
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
    for entry in "${NODES[@]}"; do
      read -r prov isp host <<< "$entry"
      province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
        show_progress
        sleep 0.2
      done
      route_trace_one "$family" "$protocol" "$prov" "$isp" "$host" "$idx" &
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
  local family="$1" out_file="$2" idx=0 entry prov isp host route_total route_raw_file ip_file cymru_file asn_map_file trace_ip_file status protocol value label
  local route_parallel="$PARALLEL"
  route_total=$(count_cdn_nodes)
  [ "$route_total" -eq 0 ] && return 0

  check_traceroute
  echo -e "  ${DIM}正在识别 IPv${family} TCP 回程线路，请稍候...${NC}"
  for entry in "${NODES[@]}"; do
    read -r prov isp host <<< "$entry"
    province_selected "$prov" || continue
    if [ "$family" = "6" ]; then
      host=${host/-v4./-v6.}
    fi
    idx=$((idx + 1))
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$route_parallel" ]; do
      sleep 0.2
    done
    route_trace_one "$family" tcp "$prov" "$isp" "$host" "$idx" &
  done
  wait

  route_raw_file=$(mktemp)
  ip_file=$(mktemp)
  cymru_file=$(mktemp)
  asn_map_file=$(mktemp)
  for idx in $(seq 1 "$route_total"); do
    [ -f "${RESULT_DIR}/route_${idx}" ] && cat "${RESULT_DIR}/route_${idx}" >> "$route_raw_file"
    [ -f "${RESULT_DIR}/route_trace_${idx}" ] && extract_trace_ips "${RESULT_DIR}/route_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    query_cymru_asn "$ip_file" "$cymru_file"
    build_asn_map "$cymru_file" "$asn_map_file"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = "TRACE" ] && [ -f "${RESULT_DIR}/route_trace_${value}" ]; then
      trace_ip_file="${RESULT_DIR}/route_trace_${value}.ips"
      extract_trace_ips "${RESULT_DIR}/route_trace_${value}" > "$trace_ip_file"
      label=$(route_label_from_ip_trace "${RESULT_DIR}/route_trace_${value}" "$asn_map_file" "$trace_ip_file")
      echo "OK|$prov|$isp|tcp|$host|$label" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|tcp|$host|${value:-Hidden}" >> "$out_file"
    fi
  done < "$route_raw_file"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    cp "$route_raw_file" "${RESULT_DIR}/route_raw_summary.txt"
    cp "$ip_file" "${RESULT_DIR}/route_ips_summary.txt"
    cp "$cymru_file" "${RESULT_DIR}/route_cymru_summary.txt"
    cp "$asn_map_file" "${RESULT_DIR}/route_asn_map_summary.txt"
    cp "$out_file" "${RESULT_DIR}/route_final_summary.txt"
  fi

  rm -f "$route_raw_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

export -f route_trace_one
export -f extract_trace_ips
export -f resolve_route_target_ip

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

  local sent=0 rcvd=0 loss_pct avg_rtt rtt_sum="0" one_sent one_rcvd one_rtt one_success i packet_size payload_size header_size
  header_size=40
  [ "$family" = "6" ] && header_size=60
  for ((i = 1; i <= PACKETS; i++)); do
    packet_size="${PACKET_SIZES[$((RANDOM % ${#PACKET_SIZES[@]}))]}"
    payload_size=$((packet_size - header_size))
    [ "$payload_size" -lt 0 ] && payload_size=0
    if raw=$(nping "${nping_base_args[@]}" --data-length "$payload_size" -c 1 "$ip" 2>&1); then
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

should_retry_result() {
  local status="$1" loss="$2"
  [ "$status" != "OK" ] && return 0
  awk -v loss="$loss" 'BEGIN { exit !(loss + 0 >= 100) }'
}

retry_cdn_failures() {
  local family="$1" max_idx="$2" retried=0 i f status prov isp host ip snd rcv loss lat
  local fallback_host retry_file retry_status retry_loss original_status

  for i in $(seq 1 "$max_idx"); do
    f="${RESULT_DIR}/cdn${family}_${i}"
    [ -f "$f" ] || continue
    IFS='|' read -r status prov isp host ip snd rcv loss lat < "$f"
    should_retry_result "$status" "$loss" || continue

    original_status="$status"
    for fallback_host in $(fallback_hosts "$prov" "$isp" "$family" "$host"); do
      retry_file="${RESULT_DIR}/cdn${family}_fallback_${i}"
      test_one "cdn${family}_fallback" "$family" "$prov" "$isp" "$fallback_host" "$i"
      [ -f "$retry_file" ] || continue
      IFS='|' read -r retry_status _ _ _ _ _ _ retry_loss _ < "$retry_file"
      retried=$((retried + 1))

      if [ "$retry_status" = "OK" ]; then
        mv "$retry_file" "$f"
        break
      fi

      if [ "$original_status" != "OK" ]; then
        mv "$retry_file" "$f"
      else
        rm -f "$retry_file"
      fi
    done
  done

  if [ "$retried" -gt 0 ]; then
    echo -e "  ${DIM}备用节点重测: ${retried} 次${NC}"
  fi
}

export -f test_one
export -f get_ipv6_route
export -f dig_short
export -f is_public_ipv4
export -f resolve_ipv4
export RESULT_DIR PACKETS PACKET_SIZES

# ===================== 主流程 =====================
main() {
  clear
  print_header

  init_privilege

  if [ "$ROUTE_MODE" -eq 1 ]; then
    check_curl
    check_dig
    detect_ip_stack
    run_route_mode
    exit 0
  fi

  require_raw_socket_privilege
  check_curl
  check_nping
  check_dig
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
  cdn_node_count=$(count_cdn_nodes)
  cernet_node_count=$(count_cernet_nodes)
  cernet2_node_count=$(count_cernet2_nodes)

  TOTAL=0
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + cdn_node_count)); fi
  if [ "$ipv4_enabled" -eq 1 ] && [ "$test_edu" -eq 1 ]; then TOTAL=$((TOTAL + cernet_node_count)); fi
  if [ "$want_ipv6" -eq 1 ] && ipv6_available; then
    ipv6_enabled=1
    if [ "$test_cdn" -eq 1 ]; then TOTAL=$((TOTAL + cdn_node_count)); fi
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
  echo -e "${DIM}  检测范围: $(province_filter_text)  探测节点: $TOTAL  每节点发包: $PACKETS  并行: $PARALLEL  端口: 80/tcp${NC}"
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
        province_selected "$prov" || continue
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
      province_selected "$prov" || continue
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
      province_selected "$prov" || continue
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

  if [ "$test_cdn" -eq 1 ]; then
    for family in "${families[@]}"; do
      retry_cdn_failures "$family" "$idx"
    done
  fi

  local sorted_v4 sorted_v6 sorted_cernet sorted_cernet2 route_labels_v4 route_labels_v6 sorted_file f i status ip snd rcv loss lat route_label route_file
  sorted_v4=$(mktemp)
  sorted_v6=$(mktemp)
  sorted_cernet=$(mktemp)
  sorted_cernet2=$(mktemp)
  route_labels_v4=$(mktemp)
  route_labels_v6=$(mktemp)
  if [ "$test_cdn" -eq 1 ] && [ "$ipv4_enabled" -eq 1 ]; then
    collect_route_labels 4 "$route_labels_v4"
  fi
  if [ "$test_cdn" -eq 1 ] && [ "$ipv6_enabled" -eq 1 ]; then
    collect_route_labels 6 "$route_labels_v6"
  fi

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

  if [ "$UPLOAD_REPORT" -eq 1 ]; then
    upload_report "$CSV" "${report_time%%（*}"
  fi
  echo ""

  rm -f "$sorted_v4" "$sorted_v6" "$sorted_cernet" "$sorted_cernet2" "$route_labels_v4" "$route_labels_v6"
}

parse_args "$@"
main
