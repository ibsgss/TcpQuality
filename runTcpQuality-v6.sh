#!/usr/bin/env bash
#
# TcpQuality IPv6 补充工具: 大包回程 + 单线程测速
#
# 本工具补齐 TcpQuality(github.com/ibsgss/TcpQuality) 暂未覆盖的两项 IPv6 能力,
# 方法论与其 IPv4 实现保持一致:
#   --large : nping -6 TCP SYN 携带 payload(on-wire ≤1200B)分尺寸丢包/时延统计
#             —— 对应 IPv4 大包回程(LARGE_PACKET_SIZES / --only-large)
#             —— v6 裸 SYN 源地址为 :: 必丢, 需 L2 模式(-S/-e/--source-mac/--dest-mac),
#                与核心脚本 IPV6_NPING_FORCE_L2 的处理一致
#   --route : nexttrace-tiny TCP 1200B 回程路由识别(同 IPv4 大包回程用法)
#   --speed : curl -6 单线程下行/上行测速, 固定目标(speed.cloudflare.com __down/__up)
#             —— 对应 IPv4 单线程测速(curl --resolve 固定目标), 每次仅一个连接
#
# 依赖: nmap(np) curl; nexttrace-tiny 可选(--route 用)
# 用法: runTcpQuality-v6.sh [--large] [--speed] [--route] [--all] [--debug]
#
# Copyright (C) 2026 mlzship
# License: GPL-3.0 (与 TcpQuality 主仓库一致)
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
DEBUG=0
RUN_LARGE=0; RUN_SPEED=0; RUN_ROUTE=0

for a in "$@"; do
  case "$a" in
    --large) RUN_LARGE=1 ;;
    --speed) RUN_SPEED=1 ;;
    --route) RUN_ROUTE=1 ;;
    --all) RUN_LARGE=1; RUN_SPEED=1; RUN_ROUTE=1 ;;
    --debug) DEBUG=1 ;;
    -h|--help) grep '^#' "$0" | head -8; exit 0 ;;
  esac
done
[ "$RUN_LARGE" = 0 ] && [ "$RUN_SPEED" = 0 ] && [ "$RUN_ROUTE" = 0 ] && RUN_LARGE=1 RUN_SPEED=1

say()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ===================== 环境 =====================
V6_ADDR=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -vE '^(fe80|fd|fc)' | head -1)
[ -n "$V6_ADDR" ] || die "本机没有公网 IPv6 地址"
have curl || die "需要 curl"
V6_EGRESS=$(curl -6 -s --max-time 6 https://api64.ipify.org 2>/dev/null || true)
[ -n "$V6_EGRESS" ] || die "IPv6 出站不可用(curl -6 失败)"
say "本机 v6: $V6_ADDR   出站 IP: $V6_EGRESS"
have nping || warn "未安装 nping(大包回程需要): apt-get install -y nmap"
have nexttrace || warn "未安装 nexttrace, --route 回程路由识别将跳过"

# ===================== 目标 =====================
# Telegram DC 固定 v6(取自 TcpQuality 引导列表) + 双栈 CDN/测速域名(运行时解析 AAAA)
TG_DC6=(
  'TG-DC1-MIA|2001:b28:f23d:f001::a|443'
  'TG-DC2-AMS|2001:67c:4e8:f002::a|443'
  'TG-DC3-MIA|2001:b28:f23d:f003::a|443'
  'TG-DC4-AMS|2001:67c:4e8:f004::a|443'
  'TG-DC5-SIN|2001:b28:f23f:f005::a|443'
)
CDN6_DOMAINS=(www.cloudflare.com cdn.jsdelivr.net speed.cloudflare.com)
IPERF6_DOMAINS=(speedtest.hkg12.hk.leaseweb.net speedtest.sin1.sg.leaseweb.net speedtest.lax12.us.leaseweb.net)

resolve_aaaa() { # $1=域名 → 第一个全局 v6 地址
  getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | grep -vE '^(fe80|fd|fc|::1$)' | head -1
}

build_targets6() {
  TARGETS6=()
  local t ip d
  for t in "${TG_DC6[@]}"; do TARGETS6+=("$t"); done
  for d in "${CDN6_DOMAINS[@]}"; do
    ip=$(resolve_aaaa "$d" || true)
    [ -n "$ip" ] && TARGETS6+=("CDN-$d|$ip|443") || warn "解析 $d AAAA 失败, 跳过"
  done
  for d in "${IPERF6_DOMAINS[@]}"; do
    ip=$(resolve_aaaa "$d" || true)
    [ -n "$ip" ] && TARGETS6+=("LW-$d|$ip|80") || warn "解析 $d AAAA 失败, 跳过"
  done
}

# ===================== v6 路由(L2 回退用, 对齐 TcpQuality) =====================
get_ipv6_route() { # $1=目标v6 → dev|src|smac|dmac(下一跳取 via 网关, 与 TcpQuality 行为一致)
  local ip=$1 dev src smac dmac nexthop
  local route
  route=$(ip -6 route get "$ip" 2>/dev/null | head -1)
  dev=$(printf '%s' "$route" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  nexthop=$(printf '%s' "$route" | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -1)
  [ -n "$dev" ] || return 1
  [ -n "$nexthop" ] || nexthop="$ip"   # on-link 目标直接用其 MAC
  src=$(ip -6 addr show dev "$dev" scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -vE '^(fe80|fd|fc)' | head -1)
  smac=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
  ping -6 -c1 -W1 "$nexthop" >/dev/null 2>&1 || true
  dmac=$(ip -6 neigh show "$nexthop" dev "$dev" 2>/dev/null | grep -oE 'lladdr [0-9a-fA-F:]{17}' | awk '{print $2}' | head -1)
  [ -n "$src" ] && [ -n "$smac" ] && [ -n "$dmac" ] || return 1
  printf '%s|%s|%s|%s\n' "$dev" "$src" "$smac" "$dmac"
}

tcp6_reachable() { # $1=ip $2=port → TCP 可连通返回 0
  python3 - "$1" "${2:-443}" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.settimeout(4)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print("ok")
except Exception:
    print("fail")
PY
}

# ===================== 大包回程 =====================
# TcpQuality 语义: TCP SYN 携带 payload(--data-length), on-wire 1200B
# v6 头部=60B(TCP20+IPv640), 故 payload 阶梯 60/420/840/1140 → on-wire 120/480/900/1200
PAYLOADS=(60 420 840 1140)
COUNT=6

nping_large6() { # $1=目标v6 $2=port $3=payload $4=可选L2路由串 → 输出 sent|rcv|avgrtt|minrtt
  local ip=$1 port=$2 pl=$3 l2=${4:-} raw sent rcv avg min
  local -a args=(-6 --tcp -p "$port" --flags syn --data-length "$pl" -c "$COUNT")
  if [ -n "$l2" ]; then
    IFS='|' read -r dev src smac dmac <<< "$l2"
    args=(-6 -e "$dev" -S "$src" --source-mac "$smac" --dest-mac "$dmac" --tcp -p "$port" --flags syn --data-length "$pl" -c "$COUNT")
  fi
  raw=$(nping "${args[@]}" "$ip" 2>&1 || true)
  [ "$DEBUG" = 1 ] && printf '%s\n' "$raw" >&2
  sent=$(printf '%s\n' "$raw" | sed -nE 's/.*[Ss]ent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  rcv=$(printf '%s\n' "$raw"  | sed -nE 's/.*[Rr]cvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  avg=$(printf '%s\n' "$raw"  | sed -nE 's/.*Avg rtt: ([0-9.]+)ms.*/\1/p' | head -1)
  min=$(printf '%s\n' "$raw"  | sed -nE 's/.*Min rtt: ([0-9.]+)ms.*/\1/p' | head -1)
  printf '%s|%s|%s|%s\n' "${sent:-0}" "${rcv:-0}" "${avg:--}" "${min:--}"
}

run_large6() {
  LARGE6_FAIL=0
  echo -e "\n${BOLD}══════ IPv6 大包回程(nping -6 TCP SYN+payload, on-wire ≤1200B) ══════${NC}"
  printf "  ${CYAN}%-34s${NC}" "目标"
  for p in "${PAYLOADS[@]}"; do printf " %6sB" "$((p+60))"; done
  echo "    verdict"
  local entry name ip port l2="" l2_ready=0 sent rcv avg rmin loss p
  for entry in "${TARGETS6[@]}"; do
    name=${entry%%|*}; port=${entry##*|}; ip=$(printf '%s' "$entry" | cut -d'|' -f2)
    # 预检: TCP 不可达的目标与"大包"无关, 直接标记跳过(如被对端封锁的 TG DC)
    if [ "$(tcp6_reachable "$ip" "$port")" != "ok" ]; then
      printf "  %-36s" "$name"
      for p in "${PAYLOADS[@]}"; do printf " ${DIM}   -  ${NC}"; done
      echo -e "   ${DIM}目标不可达(跳过)${NC}"
      continue
    fi
    # v6 裸 SYN 源地址为 :: 必丢, 直接构建 L2 参数(对齐 TcpQuality 的 FORCE_L2 结论)
    if [ "$l2_ready" = 0 ]; then
      l2=$(get_ipv6_route "$ip" || true)
      [ -n "$l2" ] && l2_ready=1
    fi
    printf "  %-36s" "$name"
    local verdict="${GREEN}正常${NC}" line_loss_max=0
    for p in "${PAYLOADS[@]}"; do
      IFS='|' read -r sent rcv avg rmin <<< "$(nping_large6 "$ip" "$port" "$p" "$l2")"
      loss=$(( sent > 0 ? 100 * (sent - rcv) / sent : 100 ))
      [ "$loss" -gt "$line_loss_max" ] && line_loss_max=$loss
      if [ "$loss" -ge 80 ]; then printf " ${RED}%3d%%L${NC}" "$loss"; verdict="${RED}大包不通${NC}"
      elif [ "$loss" -gt 0 ]; then printf " ${YELLOW}%3d%%%s${NC}" "$loss" "$avg"; verdict="${YELLOW}有丢包${NC}"
      else printf " ${GREEN}%3d%%%s${NC}" "$loss" "$avg"; fi
    done
    echo "   $verdict"
    [ "$line_loss_max" -ge 80 ] && LARGE6_FAIL=$((LARGE6_FAIL+1))
  done
  echo -e "  ${DIM}列含义: 丢包% + 平均RTT(ms); on-wire 尺寸 = payload+60(v6头)${NC}"
  [ "${LARGE6_FAIL:-0}" -gt 0 ] && warn "$LARGE6_FAIL 个目标大包丢包≥80%, 回程可能存在 MTU/分片问题"
}

# ===================== 回程路由(nexttrace TCP, 可选) =====================
run_route6() {
  have nexttrace || { warn "无 nexttrace, 跳过回程路由识别"; return 0; }
  echo -e "\n${BOLD}══════ IPv6 大包回程路由识别(nexttrace TCP 1200B) ══════${NC}"
  local entry name ip port
  for entry in "${TARGETS6[@]:0:4}"; do
    name=${entry%%|*}; ip=$(printf '%s' "$entry" | cut -d'|' -f2); port=$(printf '%s' "$entry" | cut -d'|' -f3)
    echo -e "\n  ${CYAN}$name ($ip)${NC}"
    nexttrace -T -p "$port" --psize 1200 "$ip" 2>/dev/null || nexttrace -T -p "$port" "$ip" 2>/dev/null || warn "nexttrace 执行失败"
  done
}

# ===================== 单线程测速 =====================
DOWN_BYTES=${DOWN_BYTES:-50000000}   # 50MB
UP_BYTES=${UP_BYTES:-25000000}       # 25MB
RUNS=3

speed_once() { # $1=down|up → 输出 mbps|connect_ms|tls_ms|ttfb_ms
  local mode=$1 out
  if [ "$mode" = down ]; then
    out=$(curl -6 --noproxy '*' --http1.1 -sS -o /dev/null \
      -w '%{speed_download}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{remote_ip}' \
      --connect-timeout 5 --max-time 60 \
      "https://speed.cloudflare.com/__down?bytes=$DOWN_BYTES" 2>/dev/null || true)
  else
    out=$(head -c "$UP_BYTES" /dev/zero | curl -6 --noproxy '*' -sS -o /dev/null -X POST \
      -w '%{speed_upload}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{remote_ip}' \
      --connect-timeout 5 --max-time 60 --data-binary @- \
      "https://speed.cloudflare.com/__up" 2>/dev/null || true)
  fi
  echo "${out:-0|0|0|0|-}"
}

run_speed6() {
  echo -e "\n${BOLD}══════ IPv6 单线程测速(curl -6 → speed.cloudflare.com, 各 ${RUNS} 次) ══════${NC}"
  local i out mb conn tls ttfb ip sum_mb=0 max_mb=0 sum_ttfb=0
  echo -e "  ${CYAN}下行${NC} ($((DOWN_BYTES/1000000))MB/次):"
  for i in $(seq 1 "$RUNS"); do
    IFS='|' read -r mb conn tls ttfb ip <<< "$(speed_once down)"
    mb=$(awk -v b="$mb" 'BEGIN{printf "%.1f", b*8/1000000}')
    printf "    第%d次: %8s Mbps   连接%sms TLS%sms 首包%sms   %s\n" "$i" "$mb" \
      "$(awk -v t="$conn" 'BEGIN{printf "%.1f", t*1000}')" \
      "$(awk -v t="$tls"  'BEGIN{printf "%.1f", (t>0?t*1000:0)}')" \
      "$(awk -v t="$ttfb" 'BEGIN{printf "%.1f", t*1000}')" "$ip"
    sum_mb=$(awk -v a="$sum_mb" -v b="$mb" 'BEGIN{print a+b}')
    max_mb=$(awk -v a="$max_mb" -v b="$mb" 'BEGIN{print (b>a)?b:a}')
    sum_ttfb=$(awk -v a="$sum_ttfb" -v b="$ttfb" 'BEGIN{print a+b}')
  done
  echo -e "    ${GREEN}下行均值: $(awk -v s="$sum_mb" -v n="$RUNS" 'BEGIN{printf "%.1f", s/n}') Mbps  峰值: $max_mb Mbps  平均首包: $(awk -v s="$sum_ttfb" -v n="$RUNS" 'BEGIN{printf "%.1f", s/n*1000}')ms${NC}"

  echo -e "  ${CYAN}上行${NC} ($((UP_BYTES/1000000))MB/次):"
  sum_mb=0; max_mb=0
  for i in $(seq 1 "$RUNS"); do
    IFS='|' read -r mb conn tls ttfb ip <<< "$(speed_once up)"
    mb=$(awk -v b="$mb" 'BEGIN{printf "%.1f", b*8/1000000}')
    printf "    第%d次: %8s Mbps\n" "$i" "$mb"
    sum_mb=$(awk -v a="$sum_mb" -v b="$mb" 'BEGIN{print a+b}')
    max_mb=$(awk -v a="$max_mb" -v b="$mb" 'BEGIN{print (b>a)?b:a}')
  done
  echo -e "    ${GREEN}上行均值: $(awk -v s="$sum_mb" -v n="$RUNS" 'BEGIN{printf "%.1f", s/n}') Mbps  峰值: $max_mb Mbps${NC}"
  echo -e "  ${DIM}单线程 = 每次仅一个 curl; 目标固定(speed.cloudflare.com)可横向复测${NC}"
}

# ===================== 主流程 =====================
build_targets6
echo "目标(${#TARGETS6[@]}个): $(printf '%s ' "${TARGETS6[@]%%|*}")"
[ "$RUN_LARGE" = 1 ] && have nping && run_large6
[ "$RUN_ROUTE" = 1 ] && run_route6
[ "$RUN_SPEED" = 1 ] && run_speed6
echo
