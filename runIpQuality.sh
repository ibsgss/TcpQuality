#!/usr/bin/env bash
#
# TcpQuality IP 类型检测
#
# 默认检测当前公网 IPv4/IPv6，并输出基础信息、IP 类型、风险和服务可达性。
#

set -u
set -o pipefail

REQUESTED_IP=""
REQUESTED_FAMILY=""
REPORT_JSON_FILE=""

IPQUALITY_API_BASE="${IPQUALITY_API_BASE:-https://tcpquality.ibsgss.uk}"
IPQUALITY_PAID_LOOKUP="${IPQUALITY_PAID_LOOKUP:-0}"
INVALID_STATUS="无效"

C_CYAN=$'\033[36m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_RED=$'\033[0;31m'
C_BG_RED=$'\033[41m'
C_BG_YELLOW=$'\033[43m'
C_BG_GREEN=$'\033[42m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_NC=$'\033[0m'

usage() {
  cat <<'EOF'
TcpQuality IP 类型检测

用法：
  bash runIpQuality.sh [选项]
  bash <(curl -sL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runIpQuality.sh) [选项]

选项：
  --ip <ip>       检测指定公网 IP
  --ipv4          只检测当前公网 IPv4
  --ipv6          只检测当前公网 IPv6
  --json-file <path>
                  将每个 IP 的结果追加为一行 JSON（供 TcpQuality 报告使用）
  -h, --help      显示帮助

EOF
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
      if ($1 == 192 && $2 == 0 && ($3 == 0 || $3 == 2)) exit 1
      if ($1 == 198 && ($2 == 18 || $2 == 19)) exit 1
      if ($1 == 198 && $2 == 51 && $3 == 100) exit 1
      if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
      exit 0
    }
  ' <<< "$ip"
}

is_public_ipv6() {
  local ip="$1"
  [[ "$ip" =~ : ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  case "${ip,,}" in
    ""|::1|fe8:*|fe9:*|fea:*|feb:*|fc*|fd*|2001:db8:*|2002:*|::ffff:*) return 1 ;;
  esac
  return 0
}

is_public_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    is_public_ipv4 "$ip"
  else
    is_public_ipv6 "$ip"
  fi
}

mask_ipv4() {
  local ip="$1"
  local parts=()
  IFS='.' read -r -a parts <<< "$ip"
  if [ "${#parts[@]}" -eq 4 ]; then
    printf '%s.%s.*.*' "${parts[0]}" "${parts[1]}"
  else
    printf '%s' "$ip"
  fi
}

mask_ipv6() {
  local ip="$1" expanded_ip
  local ip_parts=()
  if [ -z "$ip" ]; then
    return 0
  fi

  expanded_ip=$(printf '%s' "$ip" \
    | sed 's/::/:0000:0000:0000:0000:0000:0000:0000:0000:/g' \
    | cut -d ':' -f1-8)
  IFS=':' read -r -a ip_parts <<< "$expanded_ip"
  while [ "${#ip_parts[@]}" -lt 8 ]; do
    ip_parts+=(0000)
  done

  printf '%s' "${ip_parts[0]:-0}:${ip_parts[1]:-0}:${ip_parts[2]:-0}:*:*:*:*:*" \
    | sed 's/:0\{1,\}/:/g' \
    | sed 's/::\+/:/g'
}

mask_ip() {
  local ip="$1"
  if [[ "$ip" == *:* ]]; then
    mask_ipv6 "$ip"
  else
    mask_ipv4 "$ip"
  fi
}

check_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s缺少依赖：%s%s\n' "$C_RED" "${missing[*]}" "$C_NC" >&2
    return 1
  fi
}

fetch_json() {
  local url="$1"
  curl -fsSL --connect-timeout 5 --max-time 12 \
    -H 'accept: application/json' \
    -H 'user-agent: TcpQuality-IPQuality/0.1' \
    "$url" 2>/dev/null
}

fetch_json_post() {
  local url="$1" body="$2" token="${3:-}" family="${4:-}"
  local args=(
    -sSL
    --connect-timeout 5
    --max-time 15
    -H 'accept: application/json'
    -H 'content-type: application/json'
    -H 'user-agent: TcpQuality-IPQuality/0.1'
    --data-raw "$body"
  )
  case "$family" in
    4) args+=(-4) ;;
    6) args+=(-6) ;;
  esac
  if [ -n "$token" ]; then
    args+=(-H "authorization: Bearer ${token}")
  fi
  curl "${args[@]}" "$url" 2>/dev/null
}

solve_ipquality_pow() {
  local nonce="$1" target_ip="$2" difficulty="$3"
  local max_iterations="${IPQUALITY_POW_MAX_ITERATIONS:-5000000}"

  if command -v node >/dev/null 2>&1; then
    export IPQUALITY_POW_NONCE="$nonce"
    export IPQUALITY_POW_TARGET="$target_ip"
    export IPQUALITY_POW_DIFFICULTY="$difficulty"
    export IPQUALITY_POW_MAX_ITERATIONS="$max_iterations"
    node --input-type=module <<'NODE'
import { createHash } from "node:crypto";

const nonce = process.env.IPQUALITY_POW_NONCE || "";
const target = process.env.IPQUALITY_POW_TARGET || "";
const difficulty = Number(process.env.IPQUALITY_POW_DIFFICULTY || 0);
const maxIterations = Number(process.env.IPQUALITY_POW_MAX_ITERATIONS || 0);
const fullNibbles = Math.floor(difficulty / 4);
const remainingBits = difficulty % 4;
const prefix = "0".repeat(fullNibbles);

function valid(hex) {
  if (!hex.startsWith(prefix)) return false;
  if (!remainingBits) return true;
  const nibble = Number.parseInt(hex[fullNibbles] || "f", 16);
  return nibble < (1 << (4 - remainingBits));
}

for (let solution = 0; solution < maxIterations; solution += 1) {
  const hex = createHash("sha256")
    .update(nonce + ":" + target + ":" + solution)
    .digest("hex");
  if (valid(hex)) {
    process.stdout.write(String(solution));
    process.exit(0);
  }
}
process.exit(1);
NODE
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    export IPQUALITY_POW_NONCE="$nonce"
    export IPQUALITY_POW_TARGET="$target_ip"
    export IPQUALITY_POW_DIFFICULTY="$difficulty"
    export IPQUALITY_POW_MAX_ITERATIONS="$max_iterations"
    python3 - <<'PY'
import hashlib
import os
import sys

nonce = os.environ.get("IPQUALITY_POW_NONCE", "")
target = os.environ.get("IPQUALITY_POW_TARGET", "")
difficulty = int(os.environ.get("IPQUALITY_POW_DIFFICULTY", "0"))
max_iterations = int(os.environ.get("IPQUALITY_POW_MAX_ITERATIONS", "0"))
full_nibbles, remaining_bits = divmod(difficulty, 4)
prefix = "0" * full_nibbles

for solution in range(max_iterations):
    digest = hashlib.sha256(
        f"{nonce}:{target}:{solution}".encode("utf-8")
    ).hexdigest()
    if not digest.startswith(prefix):
        continue
    if not remaining_bits:
        print(solution, end="")
        sys.exit(0)
    nibble = int(digest[full_nibbles] if len(digest) > full_nibbles else "f", 16)
    if nibble < (1 << (4 - remaining_bits)):
        print(solution, end="")
        sys.exit(0)
sys.exit(1)
PY
    return $?
  fi

  command -v sha256sum >/dev/null 2>&1 || return 1
  local full_nibbles=$((difficulty / 4))
  local remaining_bits=$((difficulty % 4))
  local prefix=""
  local solution digest nibble
  if [ "$full_nibbles" -gt 0 ]; then
    prefix=$(printf '%*s' "$full_nibbles" '' | tr ' ' '0')
  fi
  for ((solution = 0; solution < max_iterations; solution++)); do
    digest=$(printf '%s:%s:%s' "$nonce" "$target_ip" "$solution" | sha256sum | cut -c1-64)
    [[ "$digest" == "$prefix"* ]] || continue
    if [ "$remaining_bits" -eq 0 ]; then
      printf '%s' "$solution"
      return 0
    fi
    nibble=$((16#${digest:$full_nibbles:1}))
    if [ "$nibble" -lt $((1 << (4 - remaining_bits))) ]; then
      printf '%s' "$solution"
      return 0
    fi
  done
  return 1
}

fetch_ip2location_demo() {
  local ip="$1" response
  response=$(curl -fsSL --connect-timeout 5 --max-time 15 \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36' \
    "https://www.ip2location.com/demo/${ip}" 2>/dev/null || true)
  if [ -z "$response" ]; then
    response=$(curl -fsSL --connect-timeout 5 --max-time 15 \
      -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
      -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36' \
      "https://www.ip2location.com/${ip}" 2>/dev/null || true)
  fi
  [ -n "$response" ] && printf '%s' "$response"
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
    response=$(curl -fsS4L --connect-timeout 5 --max-time 8 "$api" 2>/dev/null \
      | awk 'NR == 1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if is_public_ipv4 "$response"; then
      printf '%s\n' "$response"
      return 0
    fi
  done
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
    response=$(curl -6 -fsSL --connect-timeout 5 --max-time 8 "$api" 2>/dev/null \
      | awk 'NR == 1 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    if is_public_ipv6 "$response"; then
      printf '%s\n' "$response"
      return 0
    fi
  done
  return 1
}

join_labels() {
  local current="$1" next="$2"
  if [ -z "$current" ]; then
    printf '%s' "$next"
  else
    printf '%s/%s' "$current" "$next"
  fi
}

ip2location_label() {
  local raw="$1" code label result=""
  IFS='/' read -r -a codes <<< "$raw"
  for code in "${codes[@]}"; do
    case "${code^^}" in
      COM) label="商业" ;;
      ORG) label="组织" ;;
      GOV) label="政府" ;;
      MIL) label="军事" ;;
      EDU) label="教育" ;;
      LIB) label="图书" ;;
      CDN) label="分发" ;;
      ISP) label="固网" ;;
      MOB) label="移动" ;;
      DCH) label="机房" ;;
      SES) label="爬虫" ;;
      AIC) label="智爬" ;;
      RSV) label="保留" ;;
      *) label="" ;;
    esac
    [ -n "$label" ] || continue
    case "/$result/" in
      *"/$label/"*) ;;
      *) result=$(join_labels "$result" "$label") ;;
    esac
  done
  printf '%s' "${result:-$raw}"
}

maxmind_label() {
  case "${1,,}" in
    business) printf '商业' ;;
    cafe) printf '咖网' ;;
    cellular) printf '移动' ;;
    college) printf '高校' ;;
    consumer_privacy_network) printf '隐网' ;;
    content_delivery_network) printf '分发' ;;
    government) printf '政府' ;;
    hosting) printf '机房' ;;
    library) printf '图书' ;;
    military) printf '军事' ;;
    residential) printf '家宽' ;;
    router) printf '路由' ;;
    school) printf '学校' ;;
    search_engine_spider) printf '爬虫' ;;
    traveler) printf '旅网' ;;
    *) printf '%s' "$1" ;;
  esac
}

ipinfo_label() {
  case "${1,,}" in
    business) printf '商业' ;;
    isp) printf '家宽' ;;
    hosting) printf '机房' ;;
    education) printf '教育' ;;
    cellular) printf '移动' ;;
    *) printf '%s' "$1" ;;
  esac
}

ipapi_label() {
  local value="$1"
  case "${value^^}" in
    BUSINESS) printf '商业' ;; ISP) printf '家宽' ;; HOSTING) printf '机房' ;;
    EDUCATION) printf '教育' ;; GOVERNMENT) printf '政府' ;; BANKING) printf '银行' ;;
    *) printf '%s' "$value" ;;
  esac
}

risk_score_valid() {
  local score="$1"
  [[ "$score" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v score="$score" 'BEGIN { exit !(score >= 0 && score <= 100) }'
}

risk_level_from_score() {
  local provider="$1" score="$2"
  risk_score_valid "$score" || {
    printf '%s' "$INVALID_STATUS"
    return 0
  }

  case "$provider" in
    ip2location)
      awk -v score="$score" 'BEGIN {
        if (score < 33) print "低风险";
        else if (score < 66) print "中风险";
        else print "高风险";
      }'
      ;;
    maxmind|scamalytics)
      awk -v score="$score" 'BEGIN {
        if (score < 20) print "低风险";
        else if (score < 60) print "中风险";
        else if (score < 90) print "高风险";
        else print "极高风险";
      }'
      ;;
    *)
      printf '%s' "$INVALID_STATUS"
      ;;
  esac
}

extract_ip2location_score() {
  local text="$1" score=""
  score=$(printf '%s' "$text" \
    | sed -n -E 's/.*"fraud_score"[[:space:]]*:[[:space:]]*([0-9]+([.][0-9]+)?).*/\1/p' \
    | sed -n '1p')
  if [ -z "$score" ]; then
    score=$(printf '%s' "$text" \
      | sed -n -E 's/.*[Ff][Rr][Aa][Uu][Dd][[:space:]_-]+[Ss][Cc][Oo][Rr][Ee][^0-9]*([0-9]+([.][0-9]+)?).*/\1/p' \
      | sed -n '1p')
  fi
  printf '%s' "$score"
}

MAXMIND_USAGE_RAW=""
MAXMIND_COMPANY_RAW=""
MAXMIND_USAGE_TYPE="无效"
MAXMIND_COMPANY_TYPE="无效"
MAXMIND_RISK_SCORE=""
MAXMIND_RISK_LEVEL="$INVALID_STATUS"
IP2LOCATION_USAGE_RAW=""
IP2LOCATION_COMPANY_RAW=""
IP2LOCATION_USAGE_TYPE="-"
IP2LOCATION_COMPANY_TYPE="-"
IP2LOCATION_IP_TYPE=""
IP2LOCATION_RISK_SCORE=""
IP2LOCATION_RISK_LEVEL="$INVALID_STATUS"
IPINFO_USAGE_RAW=""
IPINFO_COMPANY_RAW=""
IPINFO_USAGE_TYPE="-"
IPINFO_COMPANY_TYPE="-"
SCAMALYTICS_RISK_SCORE=""
SCAMALYTICS_RISK_LEVEL="$INVALID_STATUS"
IPAPI_USAGE_RAW=""
IPAPI_COMPANY_RAW=""
IPAPI_USAGE_TYPE="$INVALID_STATUS"
IPAPI_COMPANY_TYPE="$INVALID_STATUS"
IPAPI_RISK_RAW=""
IPAPI_RISK_SCORE=""
IPAPI_RISK_LEVEL="$INVALID_STATUS"
IPQUALITY_LOOKUP_RESPONSE=""
IPQUALITY_LOOKUP_TOKEN=""
IPQUALITY_LOOKUP_ERROR=""

AI_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/151 Safari/537.36"
AI_PROBE_TIMEOUT_SECONDS="${AI_PROBE_TIMEOUT_SECONDS:-8}"
AI_CHATGPT_STATUS="失败"
AI_CHATGPT_REGION="-"
AI_CHATGPT_METHOD="-"
AI_GEMINI_STATUS="失败"
AI_GEMINI_REGION="-"
AI_GEMINI_METHOD="-"
AI_GROK_STATUS="失败"
AI_GROK_REGION="-"
AI_GROK_METHOD="-"
AI_CLAUDE_STATUS="失败"
AI_CLAUDE_REGION="-"
AI_CLAUDE_METHOD="-"

PORT_25_STATUS="-"
PORT_80_STATUS="-"
PORT_443_STATUS="-"
ACTIVE_NEIGHBOR_VALUE="$INVALID_STATUS"
declare -a ACTIVE_NEIGHBOR_LABELS=()
declare -a ACTIVE_NEIGHBOR_SEGMENTS=()
declare -a ACTIVE_NEIGHBOR_ACTIVE=()
declare -a ACTIVE_NEIGHBOR_TOTAL=()
PORT_25_TARGETS=(smtp.gmail.com smtp.office365.com)
PORT_80_TARGETS=(example.com www.cloudflare.com)
PORT_443_TARGETS=(example.com www.cloudflare.com)

declare -a BASIC_FIELDS=(asn organization coordinates map city registered continent timezone location)
declare -A BASIC_MAXMIND=()
declare -A BASIC_IP2LOCATION=()
declare -A BASIC_IPINFO=()

basic_set() {
  local provider="$1" field="$2" value="$3"
  case "$provider" in
    maxmind) BASIC_MAXMIND["$field"]="$value" ;;
    ip2location) BASIC_IP2LOCATION["$field"]="$value" ;;
    ipinfo) BASIC_IPINFO["$field"]="$value" ;;
  esac
}

basic_get() {
  local provider="$1" field="$2" value=""
  case "$provider" in
    maxmind) value="${BASIC_MAXMIND[$field]:-}" ;;
    ip2location) value="${BASIC_IP2LOCATION[$field]:-}" ;;
    ipinfo) value="${BASIC_IPINFO[$field]:-}" ;;
  esac
  printf '%s' "${value:--}"
}

basic_value_available() {
  case "$1" in
    ""|"-"|"$INVALID_STATUS"|失败|未知) return 1 ;;
    *) return 0 ;;
  esac
}

basic_preferred_get() {
  local field="$1" value fallback
  value=$(basic_get ip2location "$field")
  if basic_value_available "$value"; then
    printf '%s' "$value"
    return 0
  fi

  fallback=$(basic_get maxmind "$field")
  if [ -n "$fallback" ] && [ "$fallback" != "-" ]; then
    printf '%s' "$fallback"
  else
    printf '%s' "-"
  fi
}

basic_mark_provider() {
  local provider="$1" value="$2" field
  for field in "${BASIC_FIELDS[@]}"; do
    basic_set "$provider" "$field" "$value"
  done
}

reset_basic_results() {
  BASIC_MAXMIND=()
  BASIC_IP2LOCATION=()
  BASIC_IPINFO=()
  basic_mark_provider maxmind "无效"
}

reset_ipapi_results() {
  IPAPI_USAGE_RAW=""
  IPAPI_COMPANY_RAW=""
  IPAPI_USAGE_TYPE="$INVALID_STATUS"
  IPAPI_COMPANY_TYPE="$INVALID_STATUS"
  IPAPI_RISK_RAW=""
  IPAPI_RISK_SCORE=""
  IPAPI_RISK_LEVEL="$INVALID_STATUS"
}

reset_results() {
  MAXMIND_USAGE_RAW=""
  MAXMIND_COMPANY_RAW=""
  MAXMIND_USAGE_TYPE="无效"
  MAXMIND_COMPANY_TYPE="无效"
  MAXMIND_RISK_SCORE=""
  MAXMIND_RISK_LEVEL="$INVALID_STATUS"
  IP2LOCATION_USAGE_RAW=""
  IP2LOCATION_COMPANY_RAW=""
  IP2LOCATION_USAGE_TYPE="-"
  IP2LOCATION_COMPANY_TYPE="-"
  IP2LOCATION_IP_TYPE=""
  IP2LOCATION_RISK_SCORE=""
  IP2LOCATION_RISK_LEVEL="$INVALID_STATUS"
  IPINFO_USAGE_RAW=""
  IPINFO_COMPANY_RAW=""
  IPINFO_USAGE_TYPE="-"
  IPINFO_COMPANY_TYPE="-"
  SCAMALYTICS_RISK_SCORE=""
  SCAMALYTICS_RISK_LEVEL="$INVALID_STATUS"
  reset_ipapi_results
  ACTIVE_NEIGHBOR_VALUE="$INVALID_STATUS"
  ACTIVE_NEIGHBOR_LABELS=()
  ACTIVE_NEIGHBOR_SEGMENTS=()
  ACTIVE_NEIGHBOR_ACTIVE=()
  ACTIVE_NEIGHBOR_TOTAL=()
  reset_ai_results
  reset_basic_results
}

reset_ai_results() {
  AI_CHATGPT_STATUS="失败"
  AI_CHATGPT_REGION="-"
  AI_CHATGPT_METHOD="-"
  AI_GEMINI_STATUS="失败"
  AI_GEMINI_REGION="-"
  AI_GEMINI_METHOD="-"
  AI_GROK_STATUS="失败"
  AI_GROK_REGION="-"
  AI_GROK_METHOD="-"
  AI_CLAUDE_STATUS="失败"
  AI_CLAUDE_REGION="-"
  AI_CLAUDE_METHOD="-"
}

jq_first_string() {
  local json="$1" filter="$2"
  printf '%s' "$json" \
    | jq -r "($filter) | select(. != null) | tostring" 2>/dev/null \
    | sed -n '1p'
}

ip2location_demo_text() {
  local html="$1" ip="${2:-}" text marker
  text=$(printf '%s' "$html" \
    | sed -E 's/<[^>]*>/ /g' \
    | sed \
        -e 's/&nbsp;/ /g' \
        -e 's/&amp;/\&/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e 's/&#8211;/-/g' \
        -e 's/&#x2013;/-/g' \
    | tr '\r\n\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g')

  # Demo 页面包含大量导航菜单，先从 IP Lookup Result 开始，避免
  # Country/Region/ASN 等字段命中菜单文字。
  if [[ "$text" == *"IP Lookup Result"* ]]; then
    text="${text#*IP Lookup Result}"
  fi

  # 页面可能把输入 IP 规范化成网段地址，不能只匹配调用方传入的 IP。
  # 同时兼容 `IP Address | 1.2.3.4` 和 `IP Address 1.2.3.4` 两种文本。
  if [ -n "$ip" ] && [[ "$text" == *"IP Address $ip"* ]]; then
    marker="IP Address $ip"
  elif [[ "$text" =~ IP[[:space:]]+Address[[:space:][:punct:]]+([0-9A-Fa-f:.]+) ]]; then
    marker="${BASH_REMATCH[0]}"
  else
    return 1
  fi
  text="${text#*"$marker"}"
  printf '%s' "$text"
}

ip2location_codes() {
  local value="$1" code result=""
  local codes=(COM ORG GOV MIL EDU LIB CDN ISP MOB DCH SES AIC RSV)
  for code in "${codes[@]}"; do
    if [[ "$value" =~ (^|[^[:alnum:]_])${code}([^[:alnum:]_]|$) ]]; then
      result=$(join_labels "$result" "$code")
    fi
  done
  printf '%s' "$result"
}

ip2location_demo_section() {
  local text="$1" start="$2" end="$3" section
  section="${text#*${start}}"
  [ "$section" != "$text" ] || return 1
  section="${section%%${end}*}"
  printf '%s' "$section"
}

trim_text() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

ip2location_demo_value() {
  local text="$1" start="$2" end="$3" value
  value=$(ip2location_demo_section "$text" "$start" "$end" || true)
  trim_text "$value"
}

coordinates_from_text() {
  local value="$1"
  local coordinate_pattern='^[[:space:]]*([+-]?[0-9]+([.][0-9]+)?)[,[:space:]]+([+-]?[0-9]+([.][0-9]+)?)'
  if [[ "$value" =~ $coordinate_pattern ]]; then
    printf '%s,%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  fi
}

ip2location_country_value() {
  local value="$1" code name
  if [[ "$value" =~ \[([A-Za-z]{2})\] ]]; then
    code="${BASH_REMATCH[1]^^}"
    name=$(trim_text "${value%%\[*}")
    if [ -n "$name" ]; then
      printf '[%s]%s' "$code" "$name"
    else
      printf '[%s]' "$code"
    fi
  else
    printf '%s' "$value"
  fi
}

country_code_from_value() {
  local value="$1"
  if [[ "$value" =~ \[([A-Za-z]{2})\] ]]; then
    printf '%s' "${BASH_REMATCH[1]^^}"
  elif [[ "$value" =~ ^[[:space:]]*([A-Za-z]{2})([[:space:]]|$) ]]; then
    printf '%s' "${BASH_REMATCH[1]^^}"
  fi
}

country_zh_name() {
  local code="${1^^}" name=""
  [ -n "$code" ] || return 0

  # Node 20 的 Intl.DisplayNames 覆盖完整 ISO 3166-1 国家/地区代码。
  if command -v node >/dev/null 2>&1; then
    name=$(COUNTRY_CODE="$code" node --input-type=module -e '
      const code = process.env.COUNTRY_CODE || "";
      let name = "";
      try {
        name = new Intl.DisplayNames(["zh-CN"], { type: "region" }).of(code) || "";
      } catch {}
      process.stdout.write(name === code ? "" : name);
    ' 2>/dev/null || true)
  fi

  # 无 Node 时保留常见国家的离线兜底；有 Node 时可覆盖全部国家/地区。
  if [ -z "$name" ]; then
    case "$code" in
      US) name="美国" ;; AU) name="澳大利亚" ;; BR) name="巴西" ;;
      CA) name="加拿大" ;; CN) name="中国" ;; DE) name="德国" ;;
      FR) name="法国" ;; GB) name="英国" ;; HK) name="中国香港" ;;
      IL) name="以色列" ;; IN) name="印度" ;; IT) name="意大利" ;;
      JP) name="日本" ;; KR) name="韩国" ;; MO) name="中国澳门" ;;
      MY) name="马来西亚" ;; NL) name="荷兰" ;; PH) name="菲律宾" ;;
      RU) name="俄罗斯" ;; SC) name="塞舌尔" ;; SG) name="新加坡" ;;
      ES) name="西班牙" ;; TW) name="中国台湾" ;; UA) name="乌克兰" ;;
    esac
  fi

  printf '%s' "$name"
}

normalize_country_location() {
  local value="$1" code name
  [ -n "$value" ] || return 0
  code=$(country_code_from_value "$value")
  if [ -z "$code" ]; then
    printf '%s' "$value"
    return 0
  fi
  name=$(country_zh_name "$code")
  if [ -n "$name" ]; then
    printf '[%s]%s' "$code" "$name"
  else
    printf '[%s]' "$code"
  fi
}

country_continent_code() {
  local code="${1^^}"
  case "$code" in
    AF|AM|AZ|BH|BD|BT|BN|KH|CN|CX|CC|CY|GE|HK|IN|ID|IR|IQ|IL|JP|JO|KZ|KW|KG|LA|LB|MO|MY|MV|MN|MM|NP|KP|OM|PK|PS|PH|QA|RU|SA|SG|KR|LK|SY|TW|TJ|TH|TL|TR|TM|AE|UZ|VN|YE)
      printf 'AS'
      ;;
    AX|AL|AD|AT|BY|BE|BA|BG|HR|CZ|DK|EE|FO|FI|FR|DE|GI|GR|GG|HU|IS|IE|IM|IT|JE|XK|LV|LI|LT|LU|MT|MD|MC|ME|NL|MK|NO|PL|PT|RO|SM|RS|SK|SI|ES|SJ|SE|CH|UA|GB|VA)
      printf 'EU'
      ;;
    DZ|AO|BJ|BW|BF|BI|CM|CV|CF|TD|KM|CG|CD|CI|DJ|EG|GQ|ER|SZ|ET|GA|GM|GH|GN|GW|KE|LS|LR|LY|MG|MW|ML|MR|MU|YT|MA|MZ|NA|NE|NG|RE|RW|SH|ST|SN|SC|SL|SO|ZA|SS|SD|TZ|TG|TN|UG|EH|ZM|ZW)
      printf 'AF'
      ;;
    AQ|BV|GS|HM)
      printf 'AN'
      ;;
    AI|AG|AW|BS|BB|BZ|BM|BQ|CA|KY|CR|CU|CW|DM|DO|SV|GL|GD|GP|GT|HT|HN|JM|MQ|MX|MS|NI|PA|PR|BL|KN|LC|MF|PM|VC|SX|TT|TC|US|UM|VI)
      printf 'NA'
      ;;
    AR|BO|BR|CL|CO|EC|FK|GF|GY|PY|PE|SR|UY|VE)
      printf 'SA'
      ;;
    AS|AU|CK|FJ|PF|GU|KI|MH|FM|NR|NC|NZ|NU|NF|MP|PW|PG|PN|WS|SB|TK|TO|TV|VU|WF)
      printf 'OC'
      ;;
  esac
}

continent_zh_name() {
  case "${1^^}" in
    AF) printf '非洲' ;;
    AN) printf '南极洲' ;;
    AS) printf '亚洲' ;;
    EU) printf '欧洲' ;;
    NA) printf '北美洲' ;;
    OC) printf '大洋洲' ;;
    SA) printf '南美洲' ;;
  esac
}

continent_from_country_value() {
  local value="$1" code continent name
  code=$(country_code_from_value "$value")
  [ -n "$code" ] || return 0
  continent=$(country_continent_code "$code")
  [ -n "$continent" ] || return 0
  name=$(continent_zh_name "$continent")
  [ -n "$name" ] && printf '[%s]%s' "$continent" "$name" || printf '[%s]' "$continent"
}

basic_ip_type() {
  local registered="$1" location="$2" registered_code location_code
  registered_code=$(country_code_from_value "$registered")
  location_code=$(country_code_from_value "$location")
  if [ -z "$registered_code" ] || [ -z "$location_code" ]; then
    printf '%s' "$INVALID_STATUS"
  elif [ "$registered_code" = "$location_code" ]; then
    printf '%s' '原生IP'
  else
    printf '%s' '广播IP'
  fi
}

normalize_direct_ip_type() {
  case "$(trim_text "$1")" in
    原生|原生IP) printf '%s' '原生IP' ;;
    广播|广播IP) printf '%s' '广播IP' ;;
    [Nn][Aa][Tt][Ii][Vv][Ee]) printf '%s' '原生IP' ;;
    [Bb][Rr][Oo][Aa][Dd][Cc][Aa][Ss][Tt]) printf '%s' '广播IP' ;;
    *) return 0 ;;
  esac
}

extract_direct_ip_type() {
  local text="$1" match candidate
  match=$(printf '%s' "$text" \
    | grep -Eio '(IP[[:space:]_-]*Type|IP类型)[^A-Za-z]{0,30}(native|broadcast|原生|广播)' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -n -E 's/.*(native|broadcast|原生|广播).*/\1/p' \
    | sed -n '1p' || true)
  candidate=$(normalize_direct_ip_type "$match")
  [ -n "$candidate" ] && printf '%s' "$candidate"
}

ip2location_ip_type() {
  local direct="$1" location="$2" registered="$3" direct_type
  direct_type=$(normalize_direct_ip_type "$direct")
  if [ -n "$direct_type" ]; then
    printf '%s' "$direct_type"
    return 0
  fi
  basic_ip_type "$registered" "$location"
}

basic_preferred_ip_type() {
  ip2location_ip_type \
    "$IP2LOCATION_IP_TYPE" \
    "$(basic_preferred_get location)" \
    "$(basic_get maxmind registered)"
}

map_url_from_coordinates() {
  local coordinates="$1" latitude longitude
  if [[ "$coordinates" != *,* ]]; then
    return 0
  fi
  latitude=$(trim_text "${coordinates%%,*}")
  longitude=$(trim_text "${coordinates#*,}")
  [ -n "$latitude" ] && [ -n "$longitude" ] || return 0
  printf 'https://maps.google.com/?q=%s,%s' "$latitude" "$longitude"
}

display_width() {
  local string="$1" length=0 byte byte_value byte_count i=0
  byte_count=$(LC_ALL=C printf '%s' "$string" | wc -c)
  while [ "$i" -lt "$byte_count" ]; do
    byte=$(LC_ALL=C printf '%s' "$string" | od -An -N1 -tx1 -j "$i" | tr -d ' ')
    [ -n "$byte" ] || break
    byte_value=$((16#$byte))
    if [ "$byte_value" -lt 128 ]; then
      length=$((length + 1))
      i=$((i + 1))
    elif [ "$byte_value" -lt 224 ]; then
      length=$((length + 2))
      i=$((i + 2))
    elif [ "$byte_value" -lt 240 ]; then
      length=$((length + 2))
      i=$((i + 3))
    else
      length=$((length + 2))
      i=$((i + 4))
    fi
  done
  printf '%s' "$length"
}

report_pad() {
  local value="$1" width="$2" current
  current=$(display_width "$value")
  printf '%s' "$value"
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_truncate() {
  local value="$1" max_width="$2" ellipsis='…' current i=0 char char_width used=0 result=""
  current=$(display_width "$value")
  if [ "$current" -le "$max_width" ]; then
    printf '%s' "$value"
    return 0
  fi
  if [ "$max_width" -le 2 ]; then
    printf '%s' "$ellipsis"
    return 0
  fi
  while [ "$i" -lt "${#value}" ]; do
    char="${value:i:1}"
    char_width=$(display_width "$char")
    if [ $((used + char_width + 2)) -gt "$max_width" ]; then
      break
    fi
    result+="$char"
    used=$((used + char_width))
    i=$((i + 1))
  done
  printf '%s%s' "$result" "$ellipsis"
}

report_clip() {
  local value="$1" max_width="$2" i=0 char char_width used=0 result=""
  while [ "$i" -lt "${#value}" ]; do
    char="${value:i:1}"
    char_width=$(display_width "$char")
    if [ $((used + char_width)) -gt "$max_width" ]; then
      break
    fi
    result+="$char"
    used=$((used + char_width))
    i=$((i + 1))
  done
  printf '%s' "$result"
}

report_cell() {
  local value="$1" width="$2" truncated
  truncated=$(report_truncate "$value" "$width")
  report_pad "$truncated" "$width"
}

report_label_cell() {
  local value="$1" width="$2" truncated current
  truncated=$(report_truncate "$value" "$width")
  current=$(display_width "$truncated")
  printf '%s%s%s' "$C_CYAN" "$truncated" "$C_NC"
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

ip_type_color() {
  local normalized="${1,,}"
  case "$normalized" in
    原生ip) printf '%s' "$C_GREEN" ;;
    广播ip) printf '%s' "$C_YELLOW" ;;
    *家宽*|*固网*|*移动*|*住宅*|*residential*|*isp*) printf '%s' "$C_GREEN" ;;
    *商业*|*组织*|*机房*|*托管*|*数据中心*|*business*|*hosting*|*datacenter*|*data_center*|*dch*)
      printf '%s' "$C_YELLOW"
      ;;
    *隐网*|*代理*|*vpn*|*tor*|*爬虫*|*智爬*|*proxy*|*anonym*) printf '%s' "$C_RED" ;;
    *分发*|*路由*|*cdn*|*router*|*政府*|*军事*|*教育*|*高校*|*学校*|*图书*|*library*|*government*|*military*|*education*|*cafe*)
      printf '%s' "$C_CYAN"
      ;;
    保留|无效|冷却|-|—|"") printf '%s' "$C_DIM" ;;
    *) : ;;
  esac
}

report_type_cell() {
  local value="$1" width="$2" truncated current color
  truncated=$(report_truncate "$value" "$width")
  current=$(display_width "$truncated")
  color=$(ip_type_color "$value")
  if [ -n "$color" ]; then
    printf '%s%s%s' "$(report_color_prefix "$color")" "$truncated" "$C_NC"
  else
    printf '%s' "$truncated"
  fi
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_color_has_background() {
  case "$1" in
    "$C_GREEN"|"$C_YELLOW"|"$C_RED") return 0 ;;
    *) return 1 ;;
  esac
}

report_background_color() {
  case "$1" in
    "$C_RED") printf '%s' "$C_BG_RED" ;;
    "$C_YELLOW") printf '%s' "$C_BG_YELLOW" ;;
    "$C_GREEN") printf '%s' "$C_BG_GREEN" ;;
    *) return 0 ;;
  esac
}

report_color_prefix() {
  local color="$1" background
  if report_color_has_background "$color"; then
    background=$(report_background_color "$color")
    printf '%s%s' "$background" "$color"
  else
    printf '%s' "$color"
  fi
}

REPORT_LABEL_WIDTH=0
REPORT_COLUMN_WIDTHS=(0 0 0 0)
RISK_VALUE_WIDTH=8
REPORT_MEASURE_ONLY=0

report_measure() {
  :
}

report_row() {
  local values=("$@") index
  printf '  '
  report_label_cell "${values[0]}" "$REPORT_LABEL_WIDTH"
  for index in 1 2 3 4; do
    printf '  '
    report_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$((index - 1))]}"
  done
  printf '\n'
}

report_type_row() {
  local values=("$@") index
  printf '  '
  report_label_cell "${values[0]}" "$REPORT_LABEL_WIDTH"
  for index in 1 2 3 4; do
    printf '  '
    report_type_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$((index - 1))]}"
  done
  printf '\n'
}

report_database_row() {
  local values=("$@") index
  printf '  '
  report_label_cell "${values[0]}" "$REPORT_LABEL_WIDTH"
  for index in 1 2 3 4; do
    printf '  '
    report_label_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$((index - 1))]}"
  done
  printf '\n'
}

report_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_row "$@"
  fi
}

report_type_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_type_row "$@"
  fi
}

report_database_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_database_row "$@"
  fi
}

neighbor_ratio_color() {
  local active="$1" total="$2"
  if ! [[ "$active" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || [ "$total" -le 0 ]; then
    printf '%s' "$C_DIM"
  elif [ $((active * 4)) -le "$total" ]; then
    printf '%s' "$C_GREEN"
  elif [ $((active * 4)) -le $((total * 3)) ]; then
    printf '%s' "$C_YELLOW"
  else
    printf '%s' "$C_RED"
  fi
}

report_neighbor_cell() {
  local width="$1" current index label segment active_display total_display color color_prefix rendered=""
  if [ "${#ACTIVE_NEIGHBOR_SEGMENTS[@]}" -eq 0 ]; then
    report_cell "$ACTIVE_NEIGHBOR_VALUE" "$width"
    return
  fi

  current=$(display_width "$ACTIVE_NEIGHBOR_VALUE")
  if [ "$current" -gt "$width" ]; then
    report_cell "$ACTIVE_NEIGHBOR_VALUE" "$width"
    return
  fi

  for index in "${!ACTIVE_NEIGHBOR_SEGMENTS[@]}"; do
    [ -n "$rendered" ] && rendered+='    '
    label="${ACTIVE_NEIGHBOR_LABELS[$index]:-}"
    segment="${ACTIVE_NEIGHBOR_SEGMENTS[$index]}"
    active_display="${segment%% / *}"
    total_display="${segment#* / }"
    color=$(neighbor_ratio_color \
      "${ACTIVE_NEIGHBOR_ACTIVE[$index]}" \
      "${ACTIVE_NEIGHBOR_TOTAL[$index]}")
    color_prefix=$(report_color_prefix "$color")
    rendered+="${C_CYAN}${label}${C_NC} ${color_prefix}${active_display} / ${total_display}${C_NC}"
  done
  printf '%s' "$rendered"
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_neighbor_row() {
  local label="$1" index total_width=0
  for index in 0 1 2 3; do
    total_width=$((total_width + REPORT_COLUMN_WIDTHS[$index]))
    [ "$index" -gt 0 ] && total_width=$((total_width + 2))
  done

  printf '  '
  report_label_cell "$label" "$REPORT_LABEL_WIDTH"
  printf '  '
  report_neighbor_cell "$total_width"
  printf '\n'
}

report_neighbor_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_neighbor_row "$@"
  fi
}

risk_color() {
  local value="$1"
  case "$value" in
    极低风险|低风险) printf '%s' "$C_GREEN" ;;
    较高风险|中风险) printf '%s' "$C_YELLOW" ;;
    高风险|极高风险) printf '%s' "$C_RED" ;;
    "$INVALID_STATUS"|冷却|-|—|"") printf '%s' "$C_DIM" ;;
    *) : ;;
  esac
}

risk_score_display() {
  local score="$1"
  if risk_score_valid "$score"; then
    printf '%s' "$score"
  else
    printf '%s' "$INVALID_STATUS"
  fi
}

report_risk_cell() {
  local value="$1" width="$2" color_key="${3:-$value}" truncated color value_width trailing_width
  value_width="$RISK_VALUE_WIDTH"
  [ "$value_width" -gt "$width" ] && value_width="$width"
  trailing_width=$((width - value_width))
  truncated=$(report_clip "$value" "$value_width")
  color=$(risk_color "$color_key")
  # 分数和等级均使用 4 个汉字的固定显示宽度，并从各列起始位置左对齐；
  # 超出时直接裁切，不添加省略号。
  # 列本身仍保留原宽度，确保风险值继续与数据库表头及其他区块对齐；
  # 红黄绿风险值同时使用对应底纹，底纹覆盖整个固定风险值单元格，
  # 其他状态仅保留字体颜色。
  if report_color_has_background "$color"; then
    printf '%s%s' "$(report_background_color "$color")" "$color"
    report_pad "$truncated" "$value_width"
    printf '%s' "$C_NC"
  elif [ -n "$color" ]; then
    printf '%s' "$color"
    report_pad "$truncated" "$value_width"
    printf '%s' "$C_NC"
  else
    report_pad "$truncated" "$value_width"
  fi
  if [ "$trailing_width" -gt 0 ]; then
    printf '%*s' "$trailing_width" ''
  fi
}

report_risk_row() {
  local kind="$1" label="$2" index color_key
  shift 2
  local values=("$@")
  local levels=("$MAXMIND_RISK_LEVEL" "$SCAMALYTICS_RISK_LEVEL" "$IP2LOCATION_RISK_LEVEL" "$IPAPI_RISK_LEVEL")
  printf '  '
  report_label_cell "$label" "$REPORT_LABEL_WIDTH"
  for index in 0 1 2 3; do
    printf '  '
    if [ "$kind" = "score" ]; then
      color_key="${levels[$index]}"
    else
      color_key="${values[$index]}"
    fi
    report_risk_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}" "$color_key"
  done
  printf '\n'
}

report_risk_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_risk_row "$@"
  fi
}

ai_status_color() {
  local value="$1"
  case "$value" in
    解锁) printf '%s' "$C_GREEN" ;;
    屏蔽|失败) printf '%s' "$C_RED" ;;
    -|—|"") printf '%s' "$C_DIM" ;;
    *) : ;;
  esac
}

report_ai_status_cell() {
  local value="$1" width="$2" truncated current color
  truncated=$(report_truncate "$value" "$width")
  current=$(display_width "$truncated")
  color=$(ai_status_color "$value")
  if [ -n "$color" ]; then
    printf '%s%s%s' "$(report_color_prefix "$color")" "$truncated" "$C_NC"
  else
    printf '%s' "$truncated"
  fi
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_ai_row() {
  local kind="$1" label="$2" index
  shift 2
  local values=("$@")
  printf '  '
  report_label_cell "$label" "$REPORT_LABEL_WIDTH"
  for index in 0 1 2 3; do
    printf '  '
    if [ "$kind" = "status" ]; then
      report_ai_status_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}"
    else
      report_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}"
    fi
  done
  printf '\n'
}

report_ai_service_row() {
  local values=("$@") index
  printf '  '
  report_label_cell "${values[0]}" "$REPORT_LABEL_WIDTH"
  for index in 1 2 3 4; do
    printf '  '
    report_label_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$((index - 1))]}"
  done
  printf '\n'
}

report_ai_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_ai_row "$@"
  fi
}

report_ai_service_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_ai_service_row "$@"
  fi
}

port_status_color() {
  local value="$1"
  case "$value" in
    可达) printf '%s' "$C_GREEN" ;;
    屏蔽|阻断) printf '%s' "$C_RED" ;;
    -|—|""|无效) printf '%s' "$C_DIM" ;;
    *) : ;;
  esac
}

report_port_status_cell() {
  local value="$1" width="$2" truncated current color
  truncated=$(report_truncate "$value" "$width")
  current=$(display_width "$truncated")
  color=$(port_status_color "$value")
  if [ -n "$color" ]; then
    printf '%s%s%s' "$(report_color_prefix "$color")" "$truncated" "$C_NC"
  else
    printf '%s' "$truncated"
  fi
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_port_value_cell() {
  local value="$1" width="$2" truncated current status color port
  truncated=$(report_truncate "$value" "$width")
  current=$(display_width "$truncated")
  if [[ "$value" =~ ^(.*)\[([^]]*)\]$ ]]; then
    port="${BASH_REMATCH[1]}"
    status="${BASH_REMATCH[2]}"
    color=$(port_status_color "$status")
    if [ -n "$color" ]; then
      printf '%s[%s%s%s]' "$port" "$(report_color_prefix "$color")" "$status" "$C_NC"
    else
      printf '%s' "$truncated"
    fi
  else
    printf '%s' "$truncated"
  fi
  if [ "$current" -lt "$width" ]; then
    printf '%*s' $((width - current)) ''
  fi
}

report_port_row() {
  local kind="$1" label="$2" index
  shift 2
  local values=("$@")
  printf '  '
  report_label_cell "$label" "$REPORT_LABEL_WIDTH"
  for index in 0 1 2; do
    printf '  '
    if [ "$kind" = "status" ]; then
      report_port_status_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}"
    elif [ "$kind" = "value" ]; then
      report_port_value_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}"
    else
      report_cell "${values[$index]}" "${REPORT_COLUMN_WIDTHS[$index]}"
    fi
  done
  printf '\n'
}

report_port_line() {
  if [ "$REPORT_MEASURE_ONLY" -eq 1 ]; then
    report_measure "$@"
  else
    report_port_row "$@"
  fi
}

resolve_tcp_targets() {
  local family="$1" host="$2"
  command -v getent >/dev/null 2>&1 || return 0
  getent "ahostsv${family}" "$host" 2>/dev/null \
    | awk '!seen[$1]++ { print $1 }'
}

tcp_connect_target() {
  local target="$1" port="$2"
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 4 "$target" "$port" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 使用 Bash 原生 TCP 重试，避免把“已建立但没有应用层数据”的连接误判为失败。
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c ':</dev/tcp/$1/$2' _ "$target" "$port" >/dev/null 2>&1
    return $?
  fi

  return 1
}

tcp_port_probe() {
  local family="$1" host="$2" port="$3" family_flag target
  family_flag="-${family}"
  if command -v nc >/dev/null 2>&1; then
    if nc "$family_flag" -z -w 4 "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 某些 nc 实现不支持 -4/-6；先按地址族解析，再对 IP 字面量建连。
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if tcp_connect_target "$target" "$port"; then
      return 0
    fi
  done < <(resolve_tcp_targets "$family" "$host")

  return 1
}

check_port_status() {
  local family="$1" port="$2" target
  shift
  shift
  for target in "$@"; do
    if tcp_port_probe "$family" "$target" "$port"; then
      printf '%s' '可达'
      return 0
    fi
  done
  printf '%s' '屏蔽'
}

run_port_checks() {
  local family="$1"
  PORT_25_STATUS=$(check_port_status "$family" 25 "${PORT_25_TARGETS[@]}")
  PORT_80_STATUS=$(check_port_status "$family" 80 "${PORT_80_TARGETS[@]}")
  PORT_443_STATUS=$(check_port_status "$family" 443 "${PORT_443_TARGETS[@]}")
}

fetch_ai_page() {
  local url="$1"
  curl -sS -L --compressed --connect-timeout 5 --max-time 12 \
    -A "$AI_USER_AGENT" \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'accept-language: en-US,en;q=0.8' \
    -o - \
    -w $'\n__TCPQUALITY_HTTP__%{http_code}\n__TCPQUALITY_URL__%{url_effective}\n' \
    "$url" 2>/dev/null || true
}

ai_probe_http() {
  local url="$1" status
  shift

  status=$(curl -sS -L --compressed \
    --connect-timeout 5 --max-time "$AI_PROBE_TIMEOUT_SECONDS" \
    -A "$AI_USER_AGENT" \
    -H 'accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8' \
    -H 'accept-language: en-US,en;q=0.8' \
    "$@" \
    -o /dev/null -w '%{http_code}' \
    "$url" 2>/dev/null || true)

  case "$status" in
    [0-9][0-9][0-9]) printf '%s' "$status" ;;
    *) printf '000' ;;
  esac
}

ai_probe_anthropic_api() {
  # 只发送无凭据的最小请求，用于确认官方 API 入口是否可达；不会使用用户 Key，
  # 也不会进入有效的模型调用流程。
  local payload='{"model":"tcpquality-connectivity-probe","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
  ai_probe_http 'https://api.anthropic.com/v1/messages' \
    -X POST \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    --data-raw "$payload"
}

ai_page_code() {
  printf '%s' "$1" | sed -n 's/^__TCPQUALITY_HTTP__//p' | tail -n 1
}

ai_page_url() {
  printf '%s' "$1" | sed -n 's/^__TCPQUALITY_URL__//p' | tail -n 1
}

ai_page_visible_text() {
  local response="$1"
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$response" | perl -0pe '
      s/^__TCPQUALITY_HTTP__.*?$//mg;
      s/^__TCPQUALITY_URL__.*?$//mg;
      s/<script\b[^>]*>.*?<\/script\s*>//gis;
      s/<style\b[^>]*>.*?<\/style\s*>//gis;
      s/<noscript\b[^>]*>.*?<\/noscript\s*>//gis;
      s/<[^>]+>/ /g;
      s/&(?:nbsp|#160);/ /gi;
      s/\s+/ /g;
    '
    return 0
  fi

  # 没有 perl 时至少移除标签和探测元数据，避免直接扫描整份 HTML。
  printf '%s' "$response" \
    | sed -E '/^__TCPQUALITY_(HTTP|URL)__/d; s/<[^>]+>/ /g; s/[[:space:]]+/ /g'
}

ai_page_is_blocked() {
  local response="$1" code visible_text
  code=$(ai_page_code "$response")
  # 403 可能是 Cloudflare/WAF 或客户端验证，只有明确的地区限制文案才判为屏蔽。
  [ "$code" = "451" ] && return 0

  visible_text=$(ai_page_visible_text "$response")
  printf '%s' "$visible_text" \
    | grep -Eiq 'unsupported[_ -]?country|country[_ -]?not[_ -]?supported|not available in (your )?(country|region)|not available in your area|unavailable in your (country|region)|region (is )?not supported|geo[-_ ]?blocked|geoblocked|blocked for your location'
}

ai_classify_page() {
  local response="$1" code
  code=$(ai_page_code "$response")
  if [ -z "$response" ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    printf '失败'
  elif ai_page_is_blocked "$response"; then
    printf '屏蔽'
  else
    case "$code" in
      2*|3*) printf '解锁' ;;
      *) printf '失败' ;;
    esac
  fi
}

ai_classify_service_probes() {
  local page_response="$1" status page_code page_result
  local saw_response=0 saw_block=0
  shift

  page_code=$(ai_page_code "$page_response")
  page_result=$(ai_classify_page "$page_response")
  case "$page_result" in
    解锁) saw_response=1 ;;
    屏蔽) saw_block=1 ;;
    *)
      # 登录页返回 401/404/5xx 仍说明服务入口可达；403/451 才作为拒绝信号。
      case "$page_code" in
        403|451) saw_block=1 ;;
        [1-9][0-9][0-9]) saw_response=1 ;;
      esac
      ;;
  esac

  for status in "$@"; do
    case "$status" in
      403|451) saw_block=1 ;;
      [1-9][0-9][0-9]) saw_response=1 ;;
    esac
  done

  # 只要任一官方入口返回了 HTTP 响应，就说明链路可达；明确拒绝且没有
  # 其它可达入口时才显示“屏蔽”，完全没有响应才显示“失败”。
  if [ "$saw_response" -eq 1 ]; then
    printf '解锁'
  elif [ "$saw_block" -eq 1 ]; then
    printf '屏蔽'
  else
    printf '失败'
  fi
}

ai_region_fallback() {
  local value
  value=$(basic_get ipinfo location)
  if [ -z "$value" ] || [ "$value" = "-" ] || [ "$value" = "$INVALID_STATUS" ]; then
    value=$(basic_get maxmind location)
  fi
  if [ -n "$value" ] && [ "$value" != "-" ] && [ "$value" != "$INVALID_STATUS" ]; then
    printf '%s' "$value"
  else
    printf '-'
  fi
}

ai_trace_region() {
  local host trace region
  for host in chatgpt.com chat.openai.com; do
    trace=$(curl -fsSL --connect-timeout 5 --max-time 8 \
      -A "$AI_USER_AGENT" "https://${host}/cdn-cgi/trace" 2>/dev/null || true)
    region=$(printf '%s' "$trace" | sed -n 's/^loc=//p' | sed -n '1p')
    if [[ "$region" =~ ^[A-Za-z]{2}$ ]]; then
      normalize_country_location "[${region^^}]"
      return 0
    fi
  done
  return 1
}

ai_ipv4_special() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      if ($1 == 10 || $1 == 127 || ($1 == 100 && $2 >= 64 && $2 <= 127) ||
          ($1 == 169 && $2 == 254) || ($1 == 172 && $2 >= 16 && $2 <= 31) ||
          ($1 == 192 && $2 == 168) || ($1 == 198 && ($2 == 18 || $2 == 19)) ||
          $1 >= 224) exit 0
      exit 1
    }
  ' <<< "$ip"
}

ai_dns_answer_suspicious() {
  local answer="$1" server="$2" answer_prefix server_prefix
  if [[ "$answer" == *:* ]]; then
    case "${answer,,}" in
      fe8:*|fe9:*|fea:*|feb:*|fc*|fd*|ff*) return 0 ;;
    esac
  elif ai_ipv4_special "$answer"; then
    return 0
  fi

  if [[ "$answer" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    answer_prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    if [[ "$server" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
      server_prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
      [ "$answer_prefix" = "$server_prefix" ] && return 0
    fi
  fi
  return 1
}

ai_method_for_domains() {
  local host lookup answer server random_host wildcard
  if ! command -v dig >/dev/null 2>&1; then
    printf '原生'
    return 0
  fi

  for host in "$@"; do
    lookup=$(dig +time=2 +tries=1 "$host" 2>/dev/null || true)
    answer=$(dig +short +time=2 +tries=1 "$host" A 2>/dev/null \
      | awk '/^[0-9]+(\.[0-9]+){3}$/ { print; exit }')
    if [ -z "$answer" ]; then
      answer=$(dig +short +time=2 +tries=1 "$host" AAAA 2>/dev/null \
        | awk '/:/ { print; exit }')
    fi
    server=$(printf '%s' "$lookup" \
      | sed -n 's/^;; SERVER: \([^# ]*\).*/\1/p' \
      | sed -n '1p')
    if ai_dns_answer_suspicious "$answer" "$server"; then
      printf 'DNS'
      return 0
    fi

    random_host="test${RANDOM}${RANDOM}.${host}"
    wildcard=$(dig +noall +answer +time=2 +tries=1 "$random_host" 2>/dev/null || true)
    if [ -n "$wildcard" ]; then
      printf 'DNS'
      return 0
    fi
  done
  printf '原生'
}

check_ai_chatgpt() {
  local response region favicon_status ios_status api_status models_status trace_status
  response=$(fetch_ai_page 'https://chatgpt.com/')
  AI_CHATGPT_STATUS=$(ai_classify_page "$response")
  if [ "$AI_CHATGPT_STATUS" != "解锁" ]; then
    favicon_status=$(ai_probe_http 'https://chatgpt.com/favicon.ico')
    ios_status=$(ai_probe_http 'https://ios.chat.openai.com/')
    api_status=$(ai_probe_http 'https://api.openai.com/compliance/cookie_requirements')
    models_status=$(ai_probe_http 'https://api.openai.com/v1/models')
    trace_status=$(ai_probe_http 'https://chat.openai.com/cdn-cgi/trace')
    AI_CHATGPT_STATUS=$(ai_classify_service_probes \
      "$response" "$favicon_status" "$ios_status" "$api_status" "$models_status" "$trace_status")
  fi
  if [ "$AI_CHATGPT_STATUS" != "解锁" ]; then
    AI_CHATGPT_REGION="-"
    AI_CHATGPT_METHOD="-"
    return 0
  fi
  region=$(ai_trace_region || true)
  AI_CHATGPT_REGION="${region:--}"
  if [ "$AI_CHATGPT_REGION" = "-" ]; then
    AI_CHATGPT_REGION=$(ai_region_fallback)
  fi
  AI_CHATGPT_METHOD=$(ai_method_for_domains chatgpt.com chat.openai.com)
}

check_ai_gemini() {
  local response
  response=$(fetch_ai_page 'https://gemini.google.com/')
  AI_GEMINI_STATUS=$(ai_classify_page "$response")
  if [ "$AI_GEMINI_STATUS" != "解锁" ]; then
    AI_GEMINI_REGION="-"
    AI_GEMINI_METHOD="-"
    return 0
  fi
  AI_GEMINI_REGION=$(ai_region_fallback)
  AI_GEMINI_METHOD=$(ai_method_for_domains gemini.google.com)
}

check_ai_grok() {
  local response
  response=$(fetch_ai_page 'https://grok.com/')
  AI_GROK_STATUS=$(ai_classify_page "$response")
  if [ "$AI_GROK_STATUS" != "解锁" ]; then
    AI_GROK_REGION="-"
    AI_GROK_METHOD="-"
    return 0
  fi
  AI_GROK_REGION=$(ai_region_fallback)
  AI_GROK_METHOD=$(ai_method_for_domains grok.com)
}

check_ai_claude() {
  local response login_status favicon_status api_root_status api_status
  response=$(fetch_ai_page 'https://claude.ai/')
  AI_CLAUDE_STATUS=$(ai_classify_page "$response")
  if [ "$AI_CLAUDE_STATUS" != "解锁" ]; then
    # Claude 首页同样可能要求浏览器验证；API 入口的 401/4xx/5xx 都能证明
    # 网络已到达 Anthropic，只有 403/451 且没有其它响应才认定为屏蔽。
    login_status=$(ai_probe_http 'https://claude.ai/login')
    favicon_status=$(ai_probe_http 'https://claude.ai/favicon.ico')
    api_root_status=$(ai_probe_http 'https://api.anthropic.com/')
    api_status=$(ai_probe_anthropic_api)
    AI_CLAUDE_STATUS=$(ai_classify_service_probes \
      "$response" "$login_status" "$favicon_status" "$api_root_status" "$api_status")
  fi
  if [ "$AI_CLAUDE_STATUS" != "解锁" ]; then
    AI_CLAUDE_REGION="-"
    AI_CLAUDE_METHOD="-"
    return 0
  fi
  AI_CLAUDE_REGION=$(ai_region_fallback)
  AI_CLAUDE_METHOD=$(ai_method_for_domains claude.ai)
}

run_ai_checks() {
  check_ai_chatgpt
  check_ai_gemini
  check_ai_grok
  check_ai_claude
}

lookup_maxmind() {
  lookup_ipquality_paid maxmind_basic "$1"
}

ipquality_set_failure() {
  local provider="$1" status="${2:-$INVALID_STATUS}" raw="${3:-}"
  case "$provider" in
    maxmind_basic)
      basic_mark_provider maxmind "$status"
      ;;
    maxmind)
      MAXMIND_USAGE_TYPE="$status"
      MAXMIND_COMPANY_TYPE="$status"
      MAXMIND_USAGE_RAW="$raw"
      MAXMIND_COMPANY_RAW="$raw"
      ;;
    scamalytics)
      SCAMALYTICS_RISK_SCORE=""
      SCAMALYTICS_RISK_LEVEL="$status"
      ;;
    ipapi)
      IPAPI_USAGE_TYPE="$status"
      IPAPI_COMPANY_TYPE="$status"
      IPAPI_USAGE_RAW="$raw"
      IPAPI_COMPANY_RAW="$raw"
      IPAPI_RISK_RAW="$raw"
      IPAPI_RISK_SCORE=""
      IPAPI_RISK_LEVEL="$status"
      ;;
  esac
}

ipquality_fetch_lookup() {
  local provider="$1" ip="$2"
  local base response error challenge_id nonce difficulty target_ip solution family=4
  local token_response token lookup_response
  IPQUALITY_LOOKUP_RESPONSE=""
  IPQUALITY_LOOKUP_TOKEN=""
  IPQUALITY_LOOKUP_ERROR=""
  [[ "$ip" == *:* ]] && family=6
  base=$(printf '%s' "$IPQUALITY_API_BASE" | sed 's:/*$::')
  if [ -z "$base" ]; then
    IPQUALITY_LOOKUP_ERROR="endpoint_unavailable"
    return 1
  fi

  response=$(fetch_json_post "$base/ipquality/challenge" \
    "$(jq -nc --arg ip "$ip" --arg provider "$provider" '{ip:$ip,provider:$provider}')" \
    "" "$family" || true)
  if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    IPQUALITY_LOOKUP_ERROR="invalid_challenge_response"
    return 1
  fi
  error=$(jq_first_string "$response" '.error')
  if [ -n "$error" ]; then
    IPQUALITY_LOOKUP_ERROR="$error"
    return 1
  fi

  challenge_id=$(jq_first_string "$response" '.challengeId')
  nonce=$(jq_first_string "$response" '.nonce')
  difficulty=$(jq_first_string "$response" '.difficulty')
  target_ip=$(jq_first_string "$response" '.targetIp')
  if [ -z "$challenge_id" ] || [ -z "$nonce" ] || [ -z "$target_ip" ]; then
    IPQUALITY_LOOKUP_ERROR="invalid_challenge_response"
    return 1
  fi
  difficulty="${difficulty:-16}"
  solution=$(solve_ipquality_pow "$nonce" "$target_ip" "$difficulty" || true)
  if [ -z "$solution" ]; then
    IPQUALITY_LOOKUP_ERROR="pow_failed"
    return 1
  fi

  token_response=$(fetch_json_post "$base/ipquality/token" \
    "$(jq -nc --arg challengeId "$challenge_id" --arg solution "$solution" '{challengeId:$challengeId,solution:$solution}')" \
    "" "$family" || true)
  token=$(jq_first_string "$token_response" '.token')
  if [ -z "$token" ]; then
    IPQUALITY_LOOKUP_ERROR="$(jq_first_string "$token_response" '.error')"
    [ -n "$IPQUALITY_LOOKUP_ERROR" ] || IPQUALITY_LOOKUP_ERROR="token_failed"
    return 1
  fi

  lookup_response=$(fetch_json_post "$base/ipquality/lookup" '{}' "$token" "$family" || true)
  if ! printf '%s' "$lookup_response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    IPQUALITY_LOOKUP_ERROR="invalid_lookup_response"
    return 1
  fi
  error=$(jq_first_string "$lookup_response" '.error')
  if [ -n "$error" ]; then
    IPQUALITY_LOOKUP_ERROR="$error"
    if [ "$error" = "client_result_required" ]; then
      IPQUALITY_LOOKUP_TOKEN="$token"
      return 2
    fi
    return 1
  fi
  IPQUALITY_LOOKUP_RESPONSE="$lookup_response"
  return 0
}

ipquality_submit_client_result() {
  local provider="$1" ip="$2" result="$3" family=4 base response error body
  [ -n "$IPQUALITY_LOOKUP_TOKEN" ] || return 1
  [ -n "$result" ] || return 1
  [[ "$ip" == *:* ]] && family=6
  base=$(printf '%s' "$IPQUALITY_API_BASE" | sed 's:/*$::')
  [ -n "$base" ] || return 1
  body=$(jq -nc --argjson clientResult "$result" '{clientResult:$clientResult}' 2>/dev/null) || return 1
  response=$(fetch_json_post "$base/ipquality/lookup" "$body" "$IPQUALITY_LOOKUP_TOKEN" "$family" || true)
  if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    IPQUALITY_LOOKUP_ERROR="invalid_upload_response"
    return 1
  fi
  error=$(jq_first_string "$response" '.error')
  if [ -n "$error" ]; then
    IPQUALITY_LOOKUP_ERROR="$error"
    return 1
  fi
  IPQUALITY_LOOKUP_RESPONSE="$response"
  IPQUALITY_LOOKUP_TOKEN=""
  return 0
}

lookup_ipquality_paid() {
  local provider="$1" ip="$2"
  if [ "$provider" = "maxmind" ] && [ "$IPQUALITY_PAID_LOOKUP" != "1" ]; then
    return 0
  fi
  case "$provider" in
    maxmind_basic|maxmind|scamalytics|ipapi) ;;
    *) return 0 ;;
  esac

  # 只要进入实际查询，就先清掉上一轮的 provider 状态；这样未配置、
  # key 失效、未命中或响应不完整时，不会把旧的成功结果继续用于本次应答。
  ipquality_set_failure "$provider"

  local base response error challenge_id nonce difficulty target_ip solution family=4
  local token token_response lookup_response usage_raw company_raw risk_score risk_level risk_raw
  local asn_number organization country_code country_name registered_code registered_name
  local continent_code continent_name continent_label latitude longitude time_zone subdivision city coordinates location
  [[ "$ip" == *:* ]] && family=6
  base=$(printf '%s' "$IPQUALITY_API_BASE" | sed 's:/*$::')
  [ -n "$base" ] || return 0

  response=$(fetch_json_post "$base/ipquality/challenge" \
    "$(jq -nc --arg ip "$ip" --arg provider "$provider" '{ip:$ip,provider:$provider}')" \
    "" "$family" || true)
  if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ipquality_set_failure "$provider"
    return 0
  fi
  error=$(jq_first_string "$response" '.error')
  if [ -n "$error" ]; then
    case "$error" in
      ip_cooldown|challenge_rate_limited)
        ipquality_set_failure "$provider" "冷却" "$error"
        ;;
      *)
        ipquality_set_failure "$provider" "$INVALID_STATUS" "$error"
        ;;
    esac
    return 0
  fi

  challenge_id=$(jq_first_string "$response" '.challengeId')
  nonce=$(jq_first_string "$response" '.nonce')
  difficulty=$(jq_first_string "$response" '.difficulty')
  target_ip=$(jq_first_string "$response" '.targetIp')
  if [ -z "$challenge_id" ] || [ -z "$nonce" ] || [ -z "$target_ip" ]; then
    ipquality_set_failure "$provider"
    return 0
  fi
  difficulty="${difficulty:-16}"
  solution=$(solve_ipquality_pow "$nonce" "$target_ip" "$difficulty" || true)
  if [ -z "$solution" ]; then
    ipquality_set_failure "$provider" "$INVALID_STATUS" "pow_failed"
    return 0
  fi

  token_response=$(fetch_json_post "$base/ipquality/token" \
    "$(jq -nc --arg challengeId "$challenge_id" --arg solution "$solution" '{challengeId:$challengeId,solution:$solution}')" \
    "" "$family" || true)
  token=$(jq_first_string "$token_response" '.token')
  if [ -z "$token" ]; then
    error=$(jq_first_string "$token_response" '.error')
    ipquality_set_failure "$provider" \
      "$([ "$error" = "ip_cooldown" ] && printf '冷却' || printf '%s' "$INVALID_STATUS")" \
      "${error:-token_failed}"
    return 0
  fi

  lookup_response=$(fetch_json_post "$base/ipquality/lookup" '{}' "$token" "$family" || true)
  if ! printf '%s' "$lookup_response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ipquality_set_failure "$provider"
    return 0
  fi
  error=$(jq_first_string "$lookup_response" '.error')
  if [ -n "$error" ]; then
    ipquality_set_failure "$provider" "$INVALID_STATUS" "$error"
    return 0
  fi

  case "$provider" in
    maxmind_basic)
      asn_number=$(jq_first_string "$lookup_response" '.basic.asn.number')
      organization=$(jq_first_string "$lookup_response" '.basic.asn.organization')
      country_code=$(jq_first_string "$lookup_response" '.basic.geo.countryCode')
      country_name=$(jq_first_string "$lookup_response" '.basic.geo.countryName')
      registered_code=$(jq_first_string "$lookup_response" '.basic.geo.registeredCountryCode')
      registered_name=$(jq_first_string "$lookup_response" '.basic.geo.registeredCountryName')
      continent_code=$(jq_first_string "$lookup_response" '.basic.geo.continentCode')
      continent_name=$(jq_first_string "$lookup_response" '.basic.geo.continentName')
      latitude=$(jq_first_string "$lookup_response" '.basic.geo.latitude')
      longitude=$(jq_first_string "$lookup_response" '.basic.geo.longitude')
      time_zone=$(jq_first_string "$lookup_response" '.basic.geo.timeZone')
      subdivision=$(jq_first_string "$lookup_response" '.basic.geo.subdivision')
      city=$(jq_first_string "$lookup_response" '.basic.geo.city')
      if [ -n "$latitude" ] && [ -n "$longitude" ]; then
        coordinates="$latitude,$longitude"
      else
        coordinates=""
      fi
      if [ -n "$country_code" ] || [ -n "$country_name" ]; then
        if [ -n "$country_code" ]; then
          location=$(normalize_country_location "[$country_code]$country_name")
        else
          location=$(normalize_country_location "$country_name")
        fi
      else
        location=""
      fi
      if [ -n "$subdivision" ] && [ -n "$city" ]; then
        city="$subdivision, $city"
      elif [ -n "$subdivision" ]; then
        city="$subdivision"
      fi
      if [ -z "$asn_number" ] && [ -z "$organization" ] && [ -z "$country_code" ] &&
         [ -z "$country_name" ] && [ -z "$city" ] && [ -z "$coordinates" ]; then
        ipquality_set_failure "$provider"
        return 0
      fi
      if [ -n "$registered_code" ] || [ -n "$registered_name" ]; then
        if [ -n "$registered_code" ]; then
          registered_name=$(normalize_country_location "[$registered_code]$registered_name")
        else
          registered_name=$(normalize_country_location "$registered_name")
        fi
      else
        registered_name=""
      fi
      if [ -n "$continent_code" ] || [ -n "$continent_name" ]; then
        if [ -n "$continent_code" ]; then
          continent_label=$(continent_zh_name "$continent_code")
          if [ -n "$continent_label" ]; then
            continent_name="[$continent_code]$continent_label"
          else
            continent_name="[$continent_code]$continent_name"
          fi
        fi
      else
        continent_name=""
      fi
      if [ -n "$asn_number" ]; then asn_number="AS$asn_number"; fi
      basic_set maxmind asn "$asn_number"
      basic_set maxmind organization "$organization"
      basic_set maxmind coordinates "$coordinates"
      basic_set maxmind map "$(map_url_from_coordinates "$coordinates")"
      basic_set maxmind city "$city"
      basic_set maxmind registered "$registered_name"
      basic_set maxmind continent "$continent_name"
      basic_set maxmind timezone "$time_zone"
      basic_set maxmind location "$location"
      ;;
    maxmind)
      usage_raw=$(jq_first_string "$lookup_response" '[.attributes.usageTypeRaw, .attributes.usageType][] | select(. != null and (type == "string" or type == "number")) | tostring')
      company_raw=$(jq_first_string "$lookup_response" '[.attributes.companyTypeRaw, .attributes.companyType][] | select(. != null and (type == "string" or type == "number")) | tostring')
      MAXMIND_USAGE_RAW="$usage_raw"
      MAXMIND_COMPANY_RAW="$company_raw"
      if [ -n "$usage_raw" ]; then
        MAXMIND_USAGE_TYPE=$(maxmind_label "$usage_raw")
      else
        MAXMIND_USAGE_TYPE="$INVALID_STATUS"
      fi
      if [ -n "$company_raw" ]; then
        MAXMIND_COMPANY_TYPE=$(maxmind_label "$company_raw")
      else
        MAXMIND_COMPANY_TYPE="$INVALID_STATUS"
      fi

      risk_score=$(jq_first_string "$lookup_response" '
        [
          .attributes.riskScore,
          .attributes.risk_score,
          .attributes.ipRiskSnapshot,
          .attributes.ip_risk_snapshot
        ][]
        | select(. != null and (type == "string" or type == "number"))
        | tostring
      ')
      if risk_score_valid "$risk_score"; then
        MAXMIND_RISK_SCORE="$risk_score"
        MAXMIND_RISK_LEVEL=$(risk_level_from_score maxmind "$risk_score")
      else
        MAXMIND_RISK_SCORE=""
        MAXMIND_RISK_LEVEL="$INVALID_STATUS"
      fi
      ;;
    scamalytics)
      risk_score=$(jq_first_string "$lookup_response" '
        [
          .attributes.riskScore,
          .attributes.risk_score,
          .riskScore,
          .risk_score,
          .score,
          .fraud_score
        ][]
        | select(. != null and (type == "string" or type == "number"))
        | tostring
      ')
      if risk_score_valid "$risk_score"; then
        SCAMALYTICS_RISK_SCORE="$risk_score"
        SCAMALYTICS_RISK_LEVEL=$(risk_level_from_score scamalytics "$risk_score")
      else
        SCAMALYTICS_RISK_SCORE=""
        SCAMALYTICS_RISK_LEVEL="$INVALID_STATUS"
      fi
      ;;
    ipapi)
      usage_raw=$(jq_first_string "$lookup_response" '[.attributes.usageTypeRaw, .attributes.usageType][] | select(. != null and (type == "string" or type == "number")) | tostring')
      company_raw=$(jq_first_string "$lookup_response" '[.attributes.companyTypeRaw, .attributes.companyType][] | select(. != null and (type == "string" or type == "number")) | tostring')
      risk_score=$(jq_first_string "$lookup_response" '[.attributes.riskScore, .attributes.risk_score][] | select(. != null and (type == "string" or type == "number")) | tostring')
      risk_level=$(jq_first_string "$lookup_response" '[.attributes.riskLevel, .attributes.risk_level][] | select(. != null and (type == "string" or type == "number")) | tostring')
      risk_raw=$(jq_first_string "$lookup_response" '[.attributes.riskRaw, .attributes.risk_raw][] | select(. != null and (type == "string" or type == "number")) | tostring')
      IPAPI_USAGE_RAW="$usage_raw"
      IPAPI_COMPANY_RAW="$company_raw"
      IPAPI_RISK_RAW="$risk_raw"
      if [ -n "$usage_raw" ]; then
        IPAPI_USAGE_TYPE=$(ipapi_label "$usage_raw")
      else
        IPAPI_USAGE_TYPE="$INVALID_STATUS"
      fi
      if [ -n "$company_raw" ]; then
        IPAPI_COMPANY_TYPE=$(ipapi_label "$company_raw")
      else
        IPAPI_COMPANY_TYPE="$INVALID_STATUS"
      fi
      if risk_score_valid "$risk_score"; then
        IPAPI_RISK_SCORE="$risk_score"
      else
        IPAPI_RISK_SCORE=""
      fi
      case "$risk_level" in
        极低风险|低风险|较高风险|高风险|极高风险) IPAPI_RISK_LEVEL="$risk_level" ;;
        *) IPAPI_RISK_LEVEL="$INVALID_STATUS" ;;
      esac
      ;;
  esac
}

lookup_maxmind_paid() {
  lookup_ipquality_paid maxmind "$1"
}

lookup_ip2location_direct() {
  local ip="$1" response demo_text usage_section company_section fraud_score
  local country registered region city coordinates isp asn timezone
  response=$(fetch_ip2location_demo "$ip" || true)
  if [ -z "$response" ]; then
    IP2LOCATION_USAGE_TYPE="$INVALID_STATUS"
    IP2LOCATION_COMPANY_TYPE="$INVALID_STATUS"
    basic_mark_provider ip2location "$INVALID_STATUS"
    return 0
  fi

  demo_text=$(ip2location_demo_text "$response" "$ip" || true)
  if [ -z "$demo_text" ]; then
    IP2LOCATION_USAGE_TYPE="$INVALID_STATUS"
    IP2LOCATION_COMPANY_TYPE="$INVALID_STATUS"
    basic_mark_provider ip2location "$INVALID_STATUS"
    return 0
  fi
  IP2LOCATION_IP_TYPE=$(extract_direct_ip_type "$response" || true)
  [ -n "$IP2LOCATION_IP_TYPE" ] || IP2LOCATION_IP_TYPE=$(extract_direct_ip_type "$demo_text" || true)
  usage_section=$(ip2location_demo_section "$demo_text" "Usage Type" "Address Type" || true)
  company_section=$(ip2location_demo_section "$demo_text" "AS Usage Type" "Olson Time Zone" || true)
  if [ -z "$company_section" ]; then
    company_section=$(ip2location_demo_section "$demo_text" "AS Usage Type" "Proxy Data" || true)
  fi

  country=$(ip2location_country_value "$(ip2location_demo_value "$demo_text" "Country" "Region")")
  registered=$(ip2location_country_value "$(ip2location_demo_value "$demo_text" "Registered Country" "Registered Region")")
  region=$(ip2location_demo_value "$demo_text" "Region" "City")
  city=$(ip2location_demo_value "$demo_text" "City" "Coordinates of City")
  coordinates=$(coordinates_from_text "$(ip2location_demo_value "$demo_text" "Coordinates of City" "ISP")")
  isp=$(ip2location_demo_value "$demo_text" "ISP" "Local Time")
  asn=""
  if [[ "$demo_text" =~ ASN[[:space:]]+(AS[0-9]+) ]]; then
    asn="${BASH_REMATCH[1]}"
  fi
  timezone=$(ip2location_demo_value "$demo_text" "Olson Time Zone" "Proxy Data")
  if [ -n "$region" ] && [ -n "$city" ]; then
    city="$region, $city"
  elif [ -n "$region" ]; then
    city="$region"
  fi
  basic_set ip2location asn "$asn"
  basic_set ip2location organization "$isp"
  basic_set ip2location coordinates "$coordinates"
  basic_set ip2location map "$(map_url_from_coordinates "$coordinates")"
  basic_set ip2location city "$city"
  basic_set ip2location registered "$(normalize_country_location "$registered")"
  basic_set ip2location continent "$(continent_from_country_value "$country")"
  basic_set ip2location timezone "$timezone"
  basic_set ip2location location "$(normalize_country_location "$country")"

  IP2LOCATION_USAGE_RAW=$(ip2location_codes "$usage_section")
  IP2LOCATION_COMPANY_RAW=$(ip2location_codes "$company_section")

  if [ -n "$IP2LOCATION_USAGE_RAW" ]; then
    IP2LOCATION_USAGE_TYPE=$(ip2location_label "$IP2LOCATION_USAGE_RAW")
  else
    IP2LOCATION_USAGE_TYPE="$INVALID_STATUS"
  fi
  if [ -n "$IP2LOCATION_COMPANY_RAW" ]; then
    IP2LOCATION_COMPANY_TYPE=$(ip2location_label "$IP2LOCATION_COMPANY_RAW")
  else
    IP2LOCATION_COMPANY_TYPE="$INVALID_STATUS"
  fi

  fraud_score=$(extract_ip2location_score "$response")
  if [ -z "$fraud_score" ]; then
    fraud_score=$(extract_ip2location_score "$demo_text")
  fi
  if risk_score_valid "$fraud_score"; then
    IP2LOCATION_RISK_SCORE="$fraud_score"
    IP2LOCATION_RISK_LEVEL=$(risk_level_from_score ip2location "$fraud_score")
  else
    IP2LOCATION_RISK_SCORE=""
    IP2LOCATION_RISK_LEVEL="$INVALID_STATUS"
  fi
}

lookup_ipinfo_direct() {
  local ip="$1" response coordinates country registered region city city_info location continent
  response=$(fetch_json "https://ipinfo.io/widget/demo/${ip}" || true)
  if [ -z "$response" ] || ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    IPINFO_USAGE_TYPE="$INVALID_STATUS"
    IPINFO_COMPANY_TYPE="$INVALID_STATUS"
    basic_mark_provider ipinfo "$INVALID_STATUS"
    return 0
  fi

  coordinates=$(jq_first_string "$response" '.data.loc')
  country=$(jq_first_string "$response" '.data.country')
  region=$(jq_first_string "$response" '.data.region')
  city=$(jq_first_string "$response" '.data.city')
  city_info="$city"
  if [ -n "$region" ] && [ -n "$city" ]; then
    city_info="$region, $city"
  elif [ -n "$region" ]; then
    city_info="$region"
  fi
  location=""
  if [ -n "$country" ]; then location=$(normalize_country_location "$country"); fi
  registered=$(jq_first_string "$response" '
    [
      .data.registered_country,
      .data.registeredCountry,
      .data.registration_country,
      .data.registrationCountry,
      .registered_country,
      .registeredCountry
    ][]
    | select(. != null and (type == "string" or type == "number"))
    | tostring
  ')
  # IPinfo widget 没有独立的 registered_country；兼容其现有公开字段，只有在
  # 真正的注册字段缺失时才使用 abuse 联系国家，并统一成国家显示格式。
  [ -n "$registered" ] || registered=$(jq_first_string "$response" '.data.abuse.country')
  continent=$(jq_first_string "$response" '
    [
      .data.continent.name,
      .data.continent,
      .continent.name,
      .continent
    ][]
    | select(. != null and (type == "string" or type == "number"))
    | tostring
  ')
  [ -n "$continent" ] || continent=$(continent_from_country_value "$country")
  basic_set ipinfo asn "$(jq_first_string "$response" '[.data.asn.asn, .data.org][] | select(. != null and (type == "string" or type == "number")) | tostring')"
  basic_set ipinfo organization "$(jq_first_string "$response" '[.data.company.name, .data.asn.name, .data.org][] | select(. != null and (type == "string" or type == "number")) | tostring')"
  basic_set ipinfo coordinates "$coordinates"
  basic_set ipinfo map "$(map_url_from_coordinates "$coordinates")"
  basic_set ipinfo city "$city_info"
  basic_set ipinfo registered "$(normalize_country_location "$registered")"
  basic_set ipinfo continent "$continent"
  basic_set ipinfo timezone "$(jq_first_string "$response" '.data.timezone')"
  basic_set ipinfo location "$location"

  IPINFO_USAGE_RAW=$(jq_first_string "$response" '
    [
      .data.asn.type,
      .data.asn_type,
      .data.network.type,
      .asn.type
    ][]
    | select(. != null and (type == "string" or type == "number"))
    | tostring
  ')
  IPINFO_COMPANY_RAW=$(jq_first_string "$response" '
    [
      .data.company.type,
      .data.company_type,
      .company.type,
      .organization.type
    ][]
    | select(. != null and (type == "string" or type == "number"))
    | tostring
  ')

  if [ -n "$IPINFO_USAGE_RAW" ]; then
    IPINFO_USAGE_TYPE=$(ipinfo_label "$IPINFO_USAGE_RAW")
  else
    IPINFO_USAGE_TYPE="$INVALID_STATUS"
  fi
  if [ -n "$IPINFO_COMPANY_RAW" ]; then
    IPINFO_COMPANY_TYPE=$(ipinfo_label "$IPINFO_COMPANY_RAW")
  else
    IPINFO_COMPANY_TYPE="$INVALID_STATUS"
  fi
}

lookup_scamalytics() {
  lookup_ipquality_paid scamalytics "$1"
}

lookup_ipapi() {
  lookup_ipquality_paid ipapi "$1"
}

bgp_tools_prefix() {
  local ip="$1" page prefix path
  page=$(curl -sS -L --connect-timeout 5 --max-time 12 \
    -A "$AI_USER_AGENT" "https://bgp.tools/prefix/${ip}" 2>/dev/null || true)
  [ -n "$page" ] || return 1

  # bgp.tools 对重叠前缀会先返回选择页，沿用 NetQuality 取第一个前缀链接。
  if [[ "$page" == *"Overlapping Prefixes Detected"* ]]; then
    path=$(printf '%s' "$page" \
      | grep -o 'href="/prefix/[^" ]*' \
      | sed -n '1p' \
      | cut -d '/' -f 3-)
    if [ -n "$path" ]; then
      page=$(curl -sS -L --connect-timeout 5 --max-time 12 \
        -A "$AI_USER_AGENT" "https://bgp.tools/prefix/${path}" 2>/dev/null || true)
    fi
  fi

  page=${page//$'\r'/ }
  page=${page//$'\n'/ }
  prefix=$(printf '%s' "$page" \
    | sed -n 's/.*<p id="network-name"[^>]*>\([^<]*\).*/\1/p' \
    | sed -n '1p')
  prefix=$(trim_text "$prefix")
  if [[ "$prefix" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    printf '%s' "$prefix"
  else
    return 1
  fi
}

bgp_tools_count_png_python() {
  python3 -c '
import struct
import sys
import zlib

def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c

try:
    data = sys.stdin.buffer.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not png")
    offset = 8
    width = height = depth = color_type = interlace = None
    palette = None
    idat = []
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        chunk = data[offset + 8:offset + 8 + length]
        offset += length + 12
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            palette = chunk
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break

    if not width or not height or depth != 8 or interlace != 0:
        raise ValueError("unsupported png format")
    bytes_per_pixel = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if bytes_per_pixel is None:
        raise ValueError("unsupported color type")
    raw = zlib.decompress(b"".join(idat))
    stride = width * bytes_per_pixel
    previous = bytearray(stride)
    position = 0
    active = 0

    def rgb(row, x):
        if color_type == 0:
            value = row[x]
            return value, value, value
        if color_type == 2:
            start = x * 3
            return tuple(row[start:start + 3])
        if color_type == 3:
            index = row[x] * 3
            if palette is None or index + 3 > len(palette):
                raise ValueError("invalid palette")
            return tuple(palette[index:index + 3])
        if color_type == 4:
            value = row[x * 2]
            return value, value, value
        start = x * 4
        return tuple(row[start:start + 3])

    for _ in range(height):
        filter_type = raw[position]
        position += 1
        row = bytearray(raw[position:position + stride])
        position += stride
        if len(row) != stride or filter_type > 4:
            raise ValueError("invalid scanline")
        for index in range(stride):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 255
            elif filter_type == 2:
                row[index] = (row[index] + above) & 255
            elif filter_type == 3:
                row[index] = (row[index] + ((left + above) // 2)) & 255
            elif filter_type == 4:
                row[index] = (row[index] + paeth(left, above, upper_left)) & 255
        for x in range(width):
            if rgb(row, x) in ((0, 3, 255), (64, 65, 190)):
                active += 1
        previous = row
    print(active)
except Exception:
    raise SystemExit(1)
' 2>/dev/null
}

bgp_tools_active_count() {
  local prefix="$1" url image_text count
  url="https://bgp.tools/pfximg/${prefix}"

  if command -v convert >/dev/null 2>&1; then
    image_text=$(curl -fsSL --connect-timeout 5 --max-time 12 \
      -A "$AI_USER_AGENT" "$url" \
      | convert png:- txt:- 2>/dev/null) || return 1
    count=$(printf '%s' "$image_text" | grep -Eic '#0003ff|#4041be' || true)
  elif command -v magick >/dev/null 2>&1; then
    image_text=$(curl -fsSL --connect-timeout 5 --max-time 12 \
      -A "$AI_USER_AGENT" "$url" \
      | magick png:- txt:- 2>/dev/null) || return 1
    count=$(printf '%s' "$image_text" | grep -Eic '#0003ff|#4041be' || true)
  elif command -v python3 >/dev/null 2>&1; then
    count=$(curl -fsSL --connect-timeout 5 --max-time 12 \
      -A "$AI_USER_AGENT" "$url" \
      | bgp_tools_count_png_python) || return 1
  else
    return 1
  fi

  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

compact_neighbor_count() {
  local count="$1"
  if [ "$count" -lt 1000 ]; then
    printf '%s' "$count"
  elif [ "$count" -lt 10000 ]; then
    printf '%sk' "${count:0:1}"
  elif [ "$count" -lt 100000 ]; then
    printf '%sk' "${count:0:2}"
  elif [ "$count" -lt 1000000 ]; then
    printf '.%sm' "${count:0:1}"
  else
    printf '1m+'
  fi
}

lookup_active_neighbors_direct() {
  local ip="$1" prefix prefix_length prefix_total prefix_total_display index
  local subnet_prefix subnet_active prefix_active
  ACTIVE_NEIGHBOR_VALUE="$INVALID_STATUS"
  ACTIVE_NEIGHBOR_LABELS=()
  ACTIVE_NEIGHBOR_SEGMENTS=()
  ACTIVE_NEIGHBOR_ACTIVE=()
  ACTIVE_NEIGHBOR_TOTAL=()

  # NetQuality 的邻居图和 /24 计算针对 IPv4；IPv6 没有对应的 IPv4 /24 邻居图。
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 0
  prefix=$(bgp_tools_prefix "$ip" || true)
  if [ -z "$prefix" ]; then
    # bgp.tools 的前缀页偶尔会被 CDN/WAF 拦截，但邻居图本身仍可能可用。
    # 此时至少查询 IP 所在的 /24，避免把“前缀页失败”直接显示成无效。
    subnet_prefix="${ip%.*}.0/24"
    subnet_active=$(bgp_tools_active_count "$subnet_prefix" || true)
    if [[ "$subnet_active" =~ ^[0-9]+$ ]]; then
      ACTIVE_NEIGHBOR_VALUE="Subnet/24 ${subnet_active} / 256"
      ACTIVE_NEIGHBOR_LABELS+=("Subnet/24")
      ACTIVE_NEIGHBOR_SEGMENTS+=("${subnet_active} / 256")
      ACTIVE_NEIGHBOR_ACTIVE+=("$subnet_active")
      ACTIVE_NEIGHBOR_TOTAL+=(256)
    fi
    return 0
  fi
  prefix_length="${prefix##*/}"
  [[ "$prefix_length" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 0

  prefix_total=$((2 ** (32 - prefix_length)))
  prefix_total_display=$(compact_neighbor_count "$prefix_total")
  prefix_active=$(bgp_tools_active_count "$prefix" || true)

  if [ "$prefix_length" -ne 24 ]; then
    subnet_prefix="${ip%.*}.0/24"
    subnet_active=$(bgp_tools_active_count "$subnet_prefix" || true)
    if [[ "$subnet_active" =~ ^[0-9]+$ ]]; then
      ACTIVE_NEIGHBOR_LABELS+=("Subnet/24")
      ACTIVE_NEIGHBOR_SEGMENTS+=("${subnet_active} / 256")
      ACTIVE_NEIGHBOR_ACTIVE+=("$subnet_active")
      ACTIVE_NEIGHBOR_TOTAL+=(256)
    fi
  fi

  if [[ "$prefix_active" =~ ^[0-9]+$ ]]; then
    ACTIVE_NEIGHBOR_LABELS+=("Prefix/${prefix_length}")
    ACTIVE_NEIGHBOR_SEGMENTS+=("${prefix_active} / ${prefix_total_display}")
    ACTIVE_NEIGHBOR_ACTIVE+=("$prefix_active")
    ACTIVE_NEIGHBOR_TOTAL+=("$prefix_total")
  fi
  if [ "${#ACTIVE_NEIGHBOR_SEGMENTS[@]}" -gt 0 ]; then
    ACTIVE_NEIGHBOR_VALUE=""
    for index in "${!ACTIVE_NEIGHBOR_SEGMENTS[@]}"; do
      [ -n "$ACTIVE_NEIGHBOR_VALUE" ] && ACTIVE_NEIGHBOR_VALUE+='    '
      ACTIVE_NEIGHBOR_VALUE+="${ACTIVE_NEIGHBOR_LABELS[$index]} ${ACTIVE_NEIGHBOR_SEGMENTS[$index]}"
    done
  fi
}

report_basic_rows() {
  local ip="$1" basic_value basic_type
  # 基础信息只展示 IP2Location；每个字段缺失时由本地 MaxMind 离线库兜底，
  # 无论实际命中哪个数据源，都固定放在第一列。
  report_database_line '数据库' 'IP2Location' '' '' ''
  basic_value=$(basic_preferred_get asn)
  report_line 'ASN' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get organization)
  report_line '组织' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get coordinates)
  report_line '坐标' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get city)
  report_line '城市' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get continent)
  report_line '洲际' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get timezone)
  report_line '时区' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get registered)
  report_line '注册地' "$basic_value" '' '' ''
  basic_value=$(basic_preferred_get location)
  report_line '使用地' "$basic_value" '' '' ''
  basic_type=$(basic_preferred_ip_type)
  report_type_line 'IP类型' "$basic_type" '' '' ''
  if [[ "$ip" != *:* ]]; then
    report_neighbor_line '活跃邻居'
  fi
}

report_type_rows() {
  report_database_line '数据库' 'MaxMind' 'IPinfo' 'IP2Location' 'ipapi.is'
  report_type_line '使用类型' \
    "$(display_type "$MAXMIND_USAGE_TYPE" "$MAXMIND_USAGE_RAW")" \
    "$(display_type "$IPINFO_USAGE_TYPE" "$IPINFO_USAGE_RAW")" \
    "$(display_type "$IP2LOCATION_USAGE_TYPE" "$IP2LOCATION_USAGE_RAW")" \
    "$(display_type "$IPAPI_USAGE_TYPE" "$IPAPI_USAGE_RAW")"
  report_type_line '公司类型' \
    "$(display_type "$MAXMIND_COMPANY_TYPE" "$MAXMIND_COMPANY_RAW")" \
    "$(display_type "$IPINFO_COMPANY_TYPE" "$IPINFO_COMPANY_RAW")" \
    "$(display_type "$IP2LOCATION_COMPANY_TYPE" "$IP2LOCATION_COMPANY_RAW")" \
    "$(display_type "$IPAPI_COMPANY_TYPE" "$IPAPI_COMPANY_RAW")"
}

report_risk_rows() {
  report_database_line '数据库' 'MaxMind' 'Scamalytics' 'IP2Location' 'ipapi.is'
  report_risk_line score '分数' \
    "$(risk_score_display "$MAXMIND_RISK_SCORE")" \
    "$(risk_score_display "$SCAMALYTICS_RISK_SCORE")" \
    "$(risk_score_display "$IP2LOCATION_RISK_SCORE")" \
    "$(risk_score_display "$IPAPI_RISK_SCORE")"
  report_risk_line level '等级' \
    "$MAXMIND_RISK_LEVEL" \
    "$SCAMALYTICS_RISK_LEVEL" \
    "$IP2LOCATION_RISK_LEVEL" \
    "$IPAPI_RISK_LEVEL"
}

report_ai_rows() {
  report_ai_service_line '服务' 'ChatGPT' 'Gemini' 'Grok' 'Claude'
  report_ai_line status '状态' \
    "$AI_CHATGPT_STATUS" \
    "$AI_GEMINI_STATUS" \
    "$AI_GROK_STATUS" \
    "$AI_CLAUDE_STATUS"
  report_ai_line plain '地区' \
    "$AI_CHATGPT_REGION" \
    "$AI_GEMINI_REGION" \
    "$AI_GROK_REGION" \
    "$AI_CLAUDE_REGION"
  report_ai_line plain '方式' \
    "$AI_CHATGPT_METHOD" \
    "$AI_GEMINI_METHOD" \
    "$AI_GROK_METHOD" \
    "$AI_CLAUDE_METHOD"
}

report_port_rows() {
  report_port_line value '端口' \
    "25[${PORT_25_STATUS}]" \
    "80[${PORT_80_STATUS}]" \
    "443[${PORT_443_STATUS}]"
}

print_port_report() {
  local family="$1" family_name
  family_name="IPv${family}"
  REPORT_LABEL_WIDTH=8
  REPORT_COLUMN_WIDTHS=(22 22 22)
  REPORT_MEASURE_ONLY=0

  printf '\n%s端口出站检测（%s）%s\n' "$C_BOLD" "$family_name" "$C_NC"
  report_port_rows
}

print_type_report() {
  local ip="$1" masked_ip
  masked_ip=$(mask_ip "$ip")

  # 固定列宽，避免第三方页面异常文本或超长 URL 把整张表撑开。
  REPORT_LABEL_WIDTH=8
  REPORT_COLUMN_WIDTHS=(22 22 22 22)
  REPORT_MEASURE_ONLY=0

  printf '\n%sIP：%s%s%s\n' "$C_BOLD" "$C_CYAN" "$masked_ip" "$C_NC"
  printf '\n%s基础信息%s\n' "$C_BOLD" "$C_NC"
  report_basic_rows "$ip"
  printf '\n%sIP 属性%s\n' "$C_BOLD" "$C_NC"
  report_type_rows
  printf '\n%s风险评分%s\n' "$C_BOLD" "$C_NC"
  report_risk_rows
  printf '\n%sAI解锁%s\n' "$C_BOLD" "$C_NC"
  report_ai_rows
}

active_neighbor_json() {
  local result='[]' index
  for index in "${!ACTIVE_NEIGHBOR_SEGMENTS[@]}"; do
    result=$(jq -cn \
      --argjson result "$result" \
      --arg neighbor_label "${ACTIVE_NEIGHBOR_LABELS[$index]}" \
      --arg neighbor_segment "${ACTIVE_NEIGHBOR_SEGMENTS[$index]}" \
      --arg neighbor_active "${ACTIVE_NEIGHBOR_ACTIVE[$index]}" \
      --arg neighbor_total "${ACTIVE_NEIGHBOR_TOTAL[$index]}" \
      '$result + [{"label": $neighbor_label, "segment": $neighbor_segment, "active": $neighbor_active, "total": $neighbor_total}]')
  done
  printf '%s' "$result"
}

ipquality_client_provider_failure() {
  local provider="$1"
  case "$provider" in
    ip2location)
      IP2LOCATION_USAGE_RAW=""
      IP2LOCATION_COMPANY_RAW=""
      IP2LOCATION_USAGE_TYPE="$INVALID_STATUS"
      IP2LOCATION_COMPANY_TYPE="$INVALID_STATUS"
      IP2LOCATION_IP_TYPE=""
      IP2LOCATION_RISK_SCORE=""
      IP2LOCATION_RISK_LEVEL="$INVALID_STATUS"
      basic_mark_provider ip2location "$INVALID_STATUS"
      ;;
    ipinfo)
      IPINFO_USAGE_RAW=""
      IPINFO_COMPANY_RAW=""
      IPINFO_USAGE_TYPE="$INVALID_STATUS"
      IPINFO_COMPANY_TYPE="$INVALID_STATUS"
      basic_mark_provider ipinfo "$INVALID_STATUS"
      ;;
    active_neighbor)
      ACTIVE_NEIGHBOR_VALUE="$INVALID_STATUS"
      ACTIVE_NEIGHBOR_LABELS=()
      ACTIVE_NEIGHBOR_SEGMENTS=()
      ACTIVE_NEIGHBOR_ACTIVE=()
      ACTIVE_NEIGHBOR_TOTAL=()
      ;;
  esac
}

ipquality_client_basic_value() {
  local provider="$1" field="$2" value=""
  case "$provider" in
    ip2location) value="${BASIC_IP2LOCATION[$field]:-}" ;;
    ipinfo) value="${BASIC_IPINFO[$field]:-}" ;;
  esac
  printf '%s' "$value"
}

ipquality_client_result_json() {
  local provider="$1" ip="$2" active_json
  local asn organization coordinates map city registered continent timezone location
  local usage_type usage_raw company_type company_raw risk_score risk_level ip_type

  case "$provider" in
    ip2location|ipinfo)
      asn=$(ipquality_client_basic_value "$provider" asn)
      organization=$(ipquality_client_basic_value "$provider" organization)
      coordinates=$(ipquality_client_basic_value "$provider" coordinates)
      map=$(ipquality_client_basic_value "$provider" map)
      city=$(ipquality_client_basic_value "$provider" city)
      registered=$(ipquality_client_basic_value "$provider" registered)
      continent=$(ipquality_client_basic_value "$provider" continent)
      timezone=$(ipquality_client_basic_value "$provider" timezone)
      location=$(ipquality_client_basic_value "$provider" location)
      if [ "$provider" = "ip2location" ]; then
        usage_type="$IP2LOCATION_USAGE_TYPE"
        usage_raw="$IP2LOCATION_USAGE_RAW"
        company_type="$IP2LOCATION_COMPANY_TYPE"
        company_raw="$IP2LOCATION_COMPANY_RAW"
        risk_score="$IP2LOCATION_RISK_SCORE"
        risk_level="$IP2LOCATION_RISK_LEVEL"
        ip_type="$IP2LOCATION_IP_TYPE"
      else
        usage_type="$IPINFO_USAGE_TYPE"
        usage_raw="$IPINFO_USAGE_RAW"
        company_type="$IPINFO_COMPANY_TYPE"
        company_raw="$IPINFO_COMPANY_RAW"
        risk_score=""
        risk_level="$INVALID_STATUS"
        ip_type=""
      fi
      jq -cn \
        --arg provider "$provider" \
        --arg ip "$ip" \
        --arg asn "$asn" \
        --arg organization "$organization" \
        --arg coordinates "$coordinates" \
        --arg map "$map" \
        --arg city "$city" \
        --arg registered "$registered" \
        --arg continent "$continent" \
        --arg timezone "$timezone" \
        --arg location "$location" \
        --arg usageType "$usage_type" \
        --arg usageTypeRaw "$usage_raw" \
        --arg companyType "$company_type" \
        --arg companyTypeRaw "$company_raw" \
        --arg riskScore "$risk_score" \
        --arg riskLevel "$risk_level" \
        --arg ipType "$ip_type" \
        '{
          provider: $provider,
          ip: $ip,
          basic: {
            asn: $asn,
            organization: $organization,
            coordinates: $coordinates,
            map: $map,
            city: $city,
            registered: $registered,
            continent: $continent,
            timezone: $timezone,
            location: $location
          },
          attributes: {
            usageType: $usageType,
            usageTypeRaw: $usageTypeRaw,
            companyType: $companyType,
            companyTypeRaw: $companyTypeRaw,
            riskScore: $riskScore,
            riskLevel: $riskLevel,
            ipType: $ipType
          }
        }'
      ;;
    active_neighbor)
      active_json=$(active_neighbor_json)
      jq -cn \
        --arg provider "$provider" \
        --arg ip "$ip" \
        --arg activeNeighbor "$ACTIVE_NEIGHBOR_VALUE" \
        --argjson activeNeighbors "$active_json" \
        '{
          provider: $provider,
          ip: $ip,
          activeNeighbor: $activeNeighbor,
          activeNeighbors: $activeNeighbors
        }'
      ;;
    *)
      return 1
      ;;
  esac
}

ipquality_apply_client_result() {
  local provider="$1" response="$2" field value usage_type usage_raw company_type company_raw
  local risk_score risk_level
  if ! printf '%s' "$response" | jq -e --arg provider "$provider" '.provider == $provider' >/dev/null 2>&1; then
    return 1
  fi

  case "$provider" in
    ip2location|ipinfo)
      for field in "${BASIC_FIELDS[@]}"; do
        value=$(jq_first_string "$response" ".basic.${field}")
        basic_set "$provider" "$field" "$value"
      done
      usage_raw=$(jq_first_string "$response" '.attributes.usageTypeRaw')
      usage_type=$(jq_first_string "$response" '.attributes.usageType')
      company_raw=$(jq_first_string "$response" '.attributes.companyTypeRaw')
      company_type=$(jq_first_string "$response" '.attributes.companyType')
      if [ "$provider" = "ip2location" ]; then
        IP2LOCATION_USAGE_RAW="$usage_raw"
        IP2LOCATION_COMPANY_RAW="$company_raw"
        if [ -n "$usage_type" ] && [ "$usage_type" != "$INVALID_STATUS" ] && [ "$usage_type" != "-" ]; then
          IP2LOCATION_USAGE_TYPE="$usage_type"
        elif [ -n "$usage_raw" ]; then
          IP2LOCATION_USAGE_TYPE=$(ip2location_label "$usage_raw")
        else
          IP2LOCATION_USAGE_TYPE="$INVALID_STATUS"
        fi
        if [ -n "$company_type" ] && [ "$company_type" != "$INVALID_STATUS" ] && [ "$company_type" != "-" ]; then
          IP2LOCATION_COMPANY_TYPE="$company_type"
        elif [ -n "$company_raw" ]; then
          IP2LOCATION_COMPANY_TYPE=$(ip2location_label "$company_raw")
        else
          IP2LOCATION_COMPANY_TYPE="$INVALID_STATUS"
        fi
        IP2LOCATION_IP_TYPE=$(jq_first_string "$response" '.attributes.ipType')
        risk_score=$(jq_first_string "$response" '.attributes.riskScore')
        risk_level=$(jq_first_string "$response" '.attributes.riskLevel')
        if risk_score_valid "$risk_score"; then
          IP2LOCATION_RISK_SCORE="$risk_score"
          IP2LOCATION_RISK_LEVEL=$(risk_level_from_score ip2location "$risk_score")
        elif [ -n "$risk_level" ] && [ "$risk_level" != "$INVALID_STATUS" ] && [ "$risk_level" != "-" ]; then
          IP2LOCATION_RISK_SCORE=""
          IP2LOCATION_RISK_LEVEL="$risk_level"
        else
          IP2LOCATION_RISK_SCORE=""
          IP2LOCATION_RISK_LEVEL="$INVALID_STATUS"
        fi
      else
        IPINFO_USAGE_RAW="$usage_raw"
        IPINFO_COMPANY_RAW="$company_raw"
        if [ -n "$usage_type" ] && [ "$usage_type" != "$INVALID_STATUS" ] && [ "$usage_type" != "-" ]; then
          IPINFO_USAGE_TYPE="$usage_type"
        elif [ -n "$usage_raw" ]; then
          IPINFO_USAGE_TYPE=$(ipinfo_label "$usage_raw")
        else
          IPINFO_USAGE_TYPE="$INVALID_STATUS"
        fi
        if [ -n "$company_type" ] && [ "$company_type" != "$INVALID_STATUS" ] && [ "$company_type" != "-" ]; then
          IPINFO_COMPANY_TYPE="$company_type"
        elif [ -n "$company_raw" ]; then
          IPINFO_COMPANY_TYPE=$(ipinfo_label "$company_raw")
        else
          IPINFO_COMPANY_TYPE="$INVALID_STATUS"
        fi
      fi
      return 0
      ;;
    active_neighbor)
      ACTIVE_NEIGHBOR_VALUE=$(jq_first_string "$response" '.activeNeighbor')
      ACTIVE_NEIGHBOR_LABELS=()
      ACTIVE_NEIGHBOR_SEGMENTS=()
      ACTIVE_NEIGHBOR_ACTIVE=()
      ACTIVE_NEIGHBOR_TOTAL=()
      while IFS= read -r value; do
        [ -n "$value" ] || continue
        local label segment active total
        label=$(jq_first_string "$value" '.label')
        segment=$(jq_first_string "$value" '.segment')
        active=$(jq_first_string "$value" '.active')
        total=$(jq_first_string "$value" '.total')
        [ -n "$label" ] && [ -n "$segment" ] || continue
        [[ "$active" =~ ^[0-9]+$ ]] || continue
        [[ "$total" =~ ^[0-9]+$ ]] || continue
        ACTIVE_NEIGHBOR_LABELS+=("$label")
        ACTIVE_NEIGHBOR_SEGMENTS+=("$segment")
        ACTIVE_NEIGHBOR_ACTIVE+=("$active")
        ACTIVE_NEIGHBOR_TOTAL+=("$total")
      done < <(printf '%s' "$response" | jq -c '.activeNeighbors[]?' 2>/dev/null)
      case "$ACTIVE_NEIGHBOR_VALUE" in
        ""|"-"|"$INVALID_STATUS"|失败|未知|冷却) return 1 ;;
      esac
      [ "${#ACTIVE_NEIGHBOR_SEGMENTS[@]}" -gt 0 ] || return 1
      return 0
      ;;
  esac
  return 1
}

lookup_ip2location() {
  local ip="$1" result
  ipquality_client_provider_failure ip2location
  if ipquality_fetch_lookup ip2location "$ip"; then
    if ipquality_apply_client_result ip2location "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi

  lookup_ip2location_direct "$ip"
  if [ -n "$IPQUALITY_LOOKUP_TOKEN" ]; then
    result=$(ipquality_client_result_json ip2location "$ip" 2>/dev/null || true)
    if [ -n "$result" ] &&
       ipquality_submit_client_result ip2location "$ip" "$result" &&
       ipquality_apply_client_result ip2location "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi
}

lookup_ipinfo() {
  local ip="$1" result
  ipquality_client_provider_failure ipinfo
  if ipquality_fetch_lookup ipinfo "$ip"; then
    if ipquality_apply_client_result ipinfo "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi

  lookup_ipinfo_direct "$ip"
  if [ -n "$IPQUALITY_LOOKUP_TOKEN" ]; then
    result=$(ipquality_client_result_json ipinfo "$ip" 2>/dev/null || true)
    if [ -n "$result" ] &&
       ipquality_submit_client_result ipinfo "$ip" "$result" &&
       ipquality_apply_client_result ipinfo "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi
}

lookup_active_neighbors() {
  local ip="$1" result
  ipquality_client_provider_failure active_neighbor
  if ipquality_fetch_lookup active_neighbor "$ip"; then
    if ipquality_apply_client_result active_neighbor "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi

  lookup_active_neighbors_direct "$ip"
  if [ -n "$IPQUALITY_LOOKUP_TOKEN" ]; then
    result=$(ipquality_client_result_json active_neighbor "$ip" 2>/dev/null || true)
    if [ -n "$result" ] &&
       ipquality_submit_client_result active_neighbor "$ip" "$result" &&
       ipquality_apply_client_result active_neighbor "$IPQUALITY_LOOKUP_RESPONSE"; then
      return 0
    fi
  fi
}

write_report_json() {
  local ip="$1" file="${REPORT_JSON_FILE:-}" family active_json
  local basic_asn basic_organization basic_coordinates basic_city basic_continent
  local basic_timezone basic_registered basic_location basic_ip_type
  [ -n "$file" ] || return 0
  family=4
  [[ "$ip" == *:* ]] && family=6
  active_json=$(active_neighbor_json)
  basic_asn=$(basic_preferred_get asn)
  basic_organization=$(basic_preferred_get organization)
  basic_coordinates=$(basic_preferred_get coordinates)
  basic_city=$(basic_preferred_get city)
  basic_continent=$(basic_preferred_get continent)
  basic_timezone=$(basic_preferred_get timezone)
  basic_registered=$(basic_preferred_get registered)
  basic_location=$(basic_preferred_get location)
  basic_ip_type=$(basic_preferred_ip_type)

  jq -cn \
    --arg ip "$ip" \
    --arg maskedIp "$(mask_ip "$ip")" \
    --arg family "IPv${family}" \
    --arg basicAsn "$basic_asn" \
    --arg basicOrganization "$basic_organization" \
    --arg basicCoordinates "$basic_coordinates" \
    --arg basicCity "$basic_city" \
    --arg basicContinent "$basic_continent" \
    --arg basicTimezone "$basic_timezone" \
    --arg basicRegistered "$basic_registered" \
    --arg basicLocation "$basic_location" \
    --arg basicIpType "$basic_ip_type" \
    --arg maxmindUsage "$(display_type "$MAXMIND_USAGE_TYPE" "$MAXMIND_USAGE_RAW")" \
    --arg ip2Usage "$(display_type "$IP2LOCATION_USAGE_TYPE" "$IP2LOCATION_USAGE_RAW")" \
    --arg ipinfoUsage "$(display_type "$IPINFO_USAGE_TYPE" "$IPINFO_USAGE_RAW")" \
    --arg ipapiUsage "$(display_type "$IPAPI_USAGE_TYPE" "$IPAPI_USAGE_RAW")" \
    --arg maxmindCompany "$(display_type "$MAXMIND_COMPANY_TYPE" "$MAXMIND_COMPANY_RAW")" \
    --arg ip2Company "$(display_type "$IP2LOCATION_COMPANY_TYPE" "$IP2LOCATION_COMPANY_RAW")" \
    --arg ipinfoCompany "$(display_type "$IPINFO_COMPANY_TYPE" "$IPINFO_COMPANY_RAW")" \
    --arg ipapiCompany "$(display_type "$IPAPI_COMPANY_TYPE" "$IPAPI_COMPANY_RAW")" \
    --arg maxmindScore "$(risk_score_display "$MAXMIND_RISK_SCORE")" \
    --arg ip2Score "$(risk_score_display "$IP2LOCATION_RISK_SCORE")" \
    --arg scamalyticsScore "$(risk_score_display "$SCAMALYTICS_RISK_SCORE")" \
    --arg ipapiScore "$(risk_score_display "$IPAPI_RISK_SCORE")" \
    --arg maxmindLevel "$MAXMIND_RISK_LEVEL" \
    --arg ip2Level "$IP2LOCATION_RISK_LEVEL" \
    --arg scamalyticsLevel "$SCAMALYTICS_RISK_LEVEL" \
    --arg ipapiLevel "$IPAPI_RISK_LEVEL" \
    --arg chatgptStatus "$AI_CHATGPT_STATUS" \
    --arg geminiStatus "$AI_GEMINI_STATUS" \
    --arg grokStatus "$AI_GROK_STATUS" \
    --arg claudeStatus "$AI_CLAUDE_STATUS" \
    --arg chatgptRegion "$AI_CHATGPT_REGION" \
    --arg geminiRegion "$AI_GEMINI_REGION" \
    --arg grokRegion "$AI_GROK_REGION" \
    --arg claudeRegion "$AI_CLAUDE_REGION" \
    --arg chatgptMethod "$AI_CHATGPT_METHOD" \
    --arg geminiMethod "$AI_GEMINI_METHOD" \
    --arg grokMethod "$AI_GROK_METHOD" \
    --arg claudeMethod "$AI_CLAUDE_METHOD" \
    --arg port25 "$PORT_25_STATUS" \
    --arg port80 "$PORT_80_STATUS" \
    --arg port443 "$PORT_443_STATUS" \
    --arg activeNeighbor "$ACTIVE_NEIGHBOR_VALUE" \
    --argjson activeNeighbors "$active_json" \
    '{
      version: 1,
      ip: $ip,
      maskedIp: $maskedIp,
      family: $family,
      basic: {
        columns: ["IP2Location"],
        columnPositions: [0],
        rows: [
          {"label": "ASN", "values": [$basicAsn]},
          {"label": "组织", "values": [$basicOrganization]},
          {"label": "坐标", "values": [$basicCoordinates]},
          {"label": "城市", "values": [$basicCity]},
          {"label": "洲际", "values": [$basicContinent]},
          {"label": "时区", "values": [$basicTimezone]},
          {"label": "注册地", "values": [$basicRegistered]},
          {"label": "使用地", "values": [$basicLocation]},
          {"label": "IP类型", "values": [$basicIpType]},
          {"label": "活跃邻居", "values": [$activeNeighbor]}
        ]
      },
      type: {
        columns: ["MaxMind", "IPinfo", "IP2Location", "ipapi.is"],
        rows: [
          {"label": "使用类型", "values": [$maxmindUsage, $ipinfoUsage, $ip2Usage, $ipapiUsage]},
          {"label": "公司类型", "values": [$maxmindCompany, $ipinfoCompany, $ip2Company, $ipapiCompany]}
        ]
      },
      risk: {
        columns: ["MaxMind", "Scamalytics", "IP2Location", "ipapi.is"],
        rows: [
          {"label": "分数", "values": [$maxmindScore, $scamalyticsScore, $ip2Score, $ipapiScore]},
          {"label": "等级", "values": [$maxmindLevel, $scamalyticsLevel, $ip2Level, $ipapiLevel]}
        ]
      },
      ai: {
        columns: ["ChatGPT", "Gemini", "Grok", "Claude"],
        rows: [
          {"label": "状态", "values": [$chatgptStatus, $geminiStatus, $grokStatus, $claudeStatus]},
          {"label": "地区", "values": [$chatgptRegion, $geminiRegion, $grokRegion, $claudeRegion]},
          {"label": "方式", "values": [$chatgptMethod, $geminiMethod, $grokMethod, $claudeMethod]}
        ]
      },
      ports: {
        columns: ["25", "80", "443"],
        values: [$port25, $port80, $port443]
      },
      activeNeighbors: $activeNeighbors
    }' >> "$file"
}

display_type() {
  local label="$1" raw="$2"
  case "$label" in
    "$INVALID_STATUS"|"冷却")
      printf '%s' "$label"
      return
      ;;
  esac
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    if [ -n "$label" ]; then
      printf '%s' "$label"
    else
      printf '-'
    fi
  elif [ "$label" = "$raw" ]; then
    printf '%s' "$label"
  else
    printf '%s(%s)' "$label" "$raw"
  fi
}

run_one() {
  local ip="$1"
  reset_results

  # MaxMind 基础信息和带 key 的 IP Quality 由服务端通过 PoW 查询；
  # IP2Location、IPinfo、活跃邻居先查服务端缓存，未命中才由客户端直查并回传。
  # 客户端不读取 MMDB，也不保留任何数据库结果缓存。
  lookup_maxmind "$ip"
  if [ "$IPQUALITY_PAID_LOOKUP" = "1" ]; then
    lookup_maxmind_paid "$ip"
  fi
  lookup_ip2location "$ip"
  lookup_ipinfo "$ip"
  lookup_scamalytics "$ip"
  if [[ "$ip" != *:* ]]; then
    lookup_active_neighbors "$ip"
  fi

  lookup_ipapi "$ip"

  run_ai_checks
  print_type_report "$ip"
  write_report_json "$ip"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ip)
        [ "$#" -ge 2 ] || { echo "--ip 缺少参数" >&2; return 2; }
        REQUESTED_IP="$2"
        shift 2
        ;;
      --ipv4)
        [ -z "$REQUESTED_FAMILY" ] || { echo "--ipv4 与 --ipv6 不能同时使用" >&2; return 2; }
        REQUESTED_FAMILY=4
        shift
        ;;
      --ipv6)
        [ -z "$REQUESTED_FAMILY" ] || { echo "--ipv4 与 --ipv6 不能同时使用" >&2; return 2; }
        REQUESTED_FAMILY=6
        shift
        ;;
      --json-file)
        [ "$#" -ge 2 ] || { echo "--json-file 缺少参数" >&2; return 2; }
        REPORT_JSON_FILE="$2"
        : > "$REPORT_JSON_FILE" || {
          echo "无法写入 JSON 报告：$REPORT_JSON_FILE" >&2
          return 2
        }
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数：$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done
}

main() {
  parse_args "$@" || exit $?
  check_dependencies || exit 1

  printf '%s%sTcpQuality IP 类型检测%s\n' "$C_BOLD" "$C_CYAN" "$C_NC"

  if [ -n "$REQUESTED_IP" ]; then
    local requested_family
    if ! is_public_ip "$REQUESTED_IP"; then
      printf '%s指定的 IP 不是公网 IPv4/IPv6：%s%s\n' "$C_RED" "$REQUESTED_IP" "$C_NC" >&2
      exit 1
    fi
    if [[ "$REQUESTED_IP" == *:* ]]; then requested_family=6; else requested_family=4; fi
    run_port_checks "$requested_family"
    run_one "$REQUESTED_IP"
    print_port_report "$requested_family"
    return 0
  fi

  local ipv4="" ipv6="" ran=0
  if [ "$REQUESTED_FAMILY" != 6 ]; then ipv4=$(get_public_ipv4 || true); fi
  if [ "$REQUESTED_FAMILY" != 4 ]; then ipv6=$(get_public_ipv6 || true); fi
  if [ -n "$ipv4" ]; then ran=1; fi
  if [ -n "$ipv6" ]; then ran=1; fi
  if [ "$ran" -eq 0 ]; then
    printf '%s没有检测到公网 IP。%s\n' "$C_RED" "$C_NC" >&2
    exit 1
  fi
  if [ -n "$ipv4" ]; then
    run_port_checks 4
    run_one "$ipv4"
    print_port_report 4
  fi
  if [ -n "$ipv6" ]; then
    run_port_checks 6
    run_one "$ipv6"
    print_port_report 6
  fi
}

main "$@"
