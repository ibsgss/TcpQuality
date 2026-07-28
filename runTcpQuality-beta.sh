#!/usr/bin/env bash
#
# TcpQuality beta 入口。
# 该脚本只切换后续依赖下载源，主入口逻辑仍复用 runTcpQuality.sh。
#

set -Eeuo pipefail

export TCPQUALITY_RAW_BASE="${TCPQUALITY_RAW_BASE:-https://raw.githubusercontent.com/ibsgss/TcpQuality/v1beta}"
ENTRY_BASE="${TCPQUALITY_ENTRY_BASE:-https://raw.githubusercontent.com/ibsgss/TcpQuality/main}"

case "$ENTRY_BASE" in
  http://*|https://*) ;;
  *)
    echo "[!] TCPQUALITY_ENTRY_BASE 非法，已回退到官方 GitHub 源" >&2
    ENTRY_BASE="https://raw.githubusercontent.com/ibsgss/TcpQuality/main"
    ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-beta-entry.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

entry="$tmp_dir/runTcpQuality.sh"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "${ENTRY_BASE%/}/runTcpQuality.sh" -o "$entry"
chmod 0755 "$entry"

bash "$entry" "$@"
