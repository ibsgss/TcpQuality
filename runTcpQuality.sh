#!/usr/bin/env bash
#
# TcpQuality 默认入口。
# 旧命令保持不变：
#   bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
#   bash <(curl -fsSL https://tcpquality.ibsgss.uk/run)
#
# 默认进入临时 Debian rootfs + chroot 后运行 runTcpQuality-core.sh。
# 使用 --no-rootfs 可直接在宿主环境运行 core，便于调试。
#

set -Eeuo pipefail

RAW_BASE="${TCPQUALITY_RAW_BASE:-https://raw.githubusercontent.com/ibsgss/TcpQuality/main}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '.')
LOCAL_ROOTFS="$SCRIPT_DIR/runTcpQuality-rootfs.sh"
LOCAL_CORE="$SCRIPT_DIR/runTcpQuality-core.sh"
ORIGINAL_ARGS=("$@")
NO_ROOTFS=0
KEEP_ROOTFS=0
ROOTFS_DEBUG=0
ALLOW_SPEEDTEST_STAGED=0
ROOTFS_DISTRO="${TCPQUALITY_ROOTFS_DISTRO:-debian}"
ROOTFS_EXTRA_ARGS=()
CORE_ARGS=()
TEMP_DIR=""

usage() {
  cat <<'EOF'
用法:
  bash runTcpQuality.sh [入口选项] [主脚本参数]

入口选项:
  --no-rootfs          不使用 rootfs，直接在宿主环境运行检测 core
  --rootfs-distro NAME rootfs 类型：debian 或 alpine，默认 debian
  --debug-rootfs       保留临时 rootfs，便于调试
  --allow-speedtest-staged
                       允许北京三段限速测速修改宿主 qdisc/ifb

主脚本参数:
  其余参数会原样透传给 runTcpQuality-core.sh。例如 -v4、--intl、--all。
EOF
}

cleanup() {
  [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-rootfs)
      NO_ROOTFS=1
      shift
      ;;
    --rootfs-distro)
      [ "$#" -ge 2 ] || { echo "[X] --rootfs-distro 缺少参数" >&2; exit 1; }
      ROOTFS_DISTRO="$2"
      shift 2
      ;;
    --debug-rootfs)
      ROOTFS_DEBUG=1
      KEEP_ROOTFS=1
      shift
      ;;
    --allow-speedtest-staged)
      ALLOW_SPEEDTEST_STAGED=1
      shift
      ;;
    --rootfs-help)
      if [ -f "$LOCAL_ROOTFS" ]; then
        exec bash "$LOCAL_ROOTFS" --help
      fi
      usage
      exit 0
      ;;
    -h|--help)
      CORE_ARGS+=("--help")
      NO_ROOTFS=1
      shift
      ;;
    --)
      shift
      CORE_ARGS+=("$@")
      break
      ;;
    *)
      CORE_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$ROOTFS_DISTRO" in
  debian|alpine) ;;
  *) echo "[X] --rootfs-distro 只能是 debian 或 alpine" >&2; exit 1 ;;
esac

run_core_direct() {
  local core="$LOCAL_CORE"
  if [ ! -f "$core" ]; then
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
    core="$TEMP_DIR/runTcpQuality-core.sh"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
      "$RAW_BASE/runTcpQuality-core.sh" -o "$core"
    chmod 0755 "$core"
  fi
  exec bash "$core" "${CORE_ARGS[@]}"
}

if [ "$NO_ROOTFS" -eq 1 ] || [ "${TCPQUALITY_INSIDE_ROOTFS:-0}" -eq 1 ]; then
  run_core_direct
fi

if [ "$(uname -s)" != Linux ]; then
  echo "[!] rootfs/chroot 仅支持 Linux，当前系统将直接运行 core" >&2
  run_core_direct
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
    temp_entry="$TEMP_DIR/runTcpQuality.sh"
    cat "$0" > "$temp_entry"
    chmod 0755 "$temp_entry"
    exec sudo -E bash -c '
      dir=$1
      script=$2
      shift 2
      trap "rm -rf -- \"$dir\"" EXIT
      exec bash "$script" "$@"
    ' bash "$TEMP_DIR" "$temp_entry" "${ORIGINAL_ARGS[@]}"
  fi
  echo "[X] 默认 rootfs 模式需要 root 权限；请使用 root 运行，或加 --no-rootfs 直接运行宿主模式" >&2
  exit 1
fi

ROOTFS_EXTRA_ARGS+=(--distro "$ROOTFS_DISTRO")
[ "$KEEP_ROOTFS" -eq 1 ] && ROOTFS_EXTRA_ARGS+=(--keep)
[ "$ALLOW_SPEEDTEST_STAGED" -eq 1 ] && ROOTFS_EXTRA_ARGS+=(--allow-speedtest)

if [ -f "$LOCAL_ROOTFS" ] && [ -f "$LOCAL_CORE" ]; then
  export TCPQUALITY_CORE_SCRIPT="$LOCAL_CORE"
  exec bash "$LOCAL_ROOTFS" "${ROOTFS_EXTRA_ARGS[@]}" -- "${CORE_ARGS[@]}"
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-entry.XXXXXX")
rootfs_runner="$TEMP_DIR/runTcpQuality-rootfs.sh"
core_script="$TEMP_DIR/runTcpQuality-core.sh"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$RAW_BASE/runTcpQuality-rootfs.sh" -o "$rootfs_runner"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$RAW_BASE/runTcpQuality-core.sh" -o "$core_script"
chmod 0755 "$rootfs_runner" "$core_script"
export TCPQUALITY_CORE_SCRIPT="$core_script"
exec bash "$rootfs_runner" "${ROOTFS_EXTRA_ARGS[@]}" -- "${CORE_ARGS[@]}"
