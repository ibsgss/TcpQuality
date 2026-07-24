#!/bin/bash
# Run runTcpQuality.sh inside a temporary Debian or Alpine rootfs.
# The guest shares the host network namespace so route and raw-socket results
# remain representative of the VPS. This wrapper never uses proot.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SELF_SCRIPT="$SCRIPT_DIR/runTcpQuality-rootfs.sh"
TARGET_SCRIPT="${TCPQUALITY_CORE_SCRIPT:-$SCRIPT_DIR/runTcpQuality-core.sh}"
[ -f "$TARGET_SCRIPT" ] || TARGET_SCRIPT="$SCRIPT_DIR/runTcpQuality.sh"
ORIGINAL_ARGS=("$@")
DISTRO="debian"
ROOTFS_DIR=""
KEEP_ROOTFS=0
ALLOW_SPEEDTEST=0
ROOTFS_URL="${TCPQUALITY_ROOTFS_URL:-}"
ROOTFS_SHA256="${TCPQUALITY_ROOTFS_SHA256:-}"
DEBIAN_SUITE="${TCPQUALITY_DEBIAN_SUITE:-bookworm}"
OUTPUT_DIR="${TCPQUALITY_OUTPUT_DIR:-/tmp}"
GUEST_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NEXTTRACE_RELEASE_API=https://api.github.com/repos/nxtrace/NTrace-core/releases/latest
DEBUG_MODE=0
MIN_ROOTFS_FREE_KB=$((700 * 1024))

usage() {
  cat <<'EOF'
用法:
  sudo ./runTcpQuality-rootfs.sh [选项] [-- 主脚本参数]

不带主脚本参数时进入交互式菜单；带参数时直接透传给检测 core。

选项:
  --distro debian|alpine  rootfs 类型，默认 debian
  --rootfs DIR            使用已有 rootfs，不下载、不删除
  --url URL               使用自定义 rootfs tar(.gz/.xz/.zst)
  --sha256 HEX            校验自定义 rootfs 下载文件
  --output DIR            保存 CSV/调试压缩包，默认宿主机 /tmp
  --keep                  保留本次创建的临时 rootfs，便于调试
  --allow-speedtest       允许北京三段限速测速修改宿主 qdisc/ifb（高风险，默认禁止）
  -h, --help              显示帮助

示例:
  sudo ./runTcpQuality-rootfs.sh -- -v4 --intl
  sudo ./runTcpQuality-rootfs.sh --distro alpine -- -v4 -c 5
  sudo ./runTcpQuality-rootfs.sh --allow-speedtest -- --all

注意:
  --rootfs 指定的已有 rootfs 会安装依赖并更新 resolv.conf，不是只读使用。
EOF
}

die() { echo "[X] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

print_interactive_intro() {
  cat <<'EOF'

TcpQuality TCP 重传检测--最贴近你上网的综合体验

EOF
}

prompt_answer() {
  local prompt="$1" default_value="${2:-}" answer
  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
  else
    printf "%s" "$prompt" >&2
    IFS= read -r answer || answer=""
  fi
  [ -n "$answer" ] || answer="$default_value"
  printf "%s" "$answer"
}

answer_is_yes() {
  case "$1" in
    y|Y|yes|YES|Yes|是|好) return 0 ;;
    *) return 1 ;;
  esac
}

answer_is_no() {
  case "$1" in
    n|N|no|NO|No|否|不) return 0 ;;
    *) return 1 ;;
  esac
}

configure_interactive_args() {
  local answer run_route=0 run_edu=0 run_intl=0 run_speedtest=0 upload_rank=1
  local -a selected_args=()

  print_interactive_intro

  answer=$(prompt_answer "运行三网回程测试？（包含 IPv4/IPv6 和 IPv4大包，回车默认 'y'）[y/n]：" "y")
  answer_is_no "$answer" || run_route=1

  answer=$(prompt_answer "运行教育网回程测试？（CERNET/CERNET2，回车默认 'y'）[y/n]：" "y")
  answer_is_no "$answer" || run_edu=1

  answer=$(prompt_answer "运行国际互联测试？（回车默认 'y'）[y/n]：" "y")
  answer_is_no "$answer" || run_intl=1

  answer=$(prompt_answer "运行三网单线程速度？（回车默认 'y'）[y/n]：" "y")
  if ! answer_is_no "$answer"; then
    if [ "$DISTRO" = alpine ]; then
      die "Alpine 实验模式不运行三网单线程速度；请使用默认 Debian rootfs"
    fi
    run_speedtest=1
    ALLOW_SPEEDTEST=1
  fi

  answer=$(prompt_answer "上传并参与速度排名？（回车默认 'y'）[y/n]：" "y")
  answer_is_no "$answer" && upload_rank=0

  if [ "$run_route" -eq 0 ]; then
    if [ "$run_edu" -eq 0 ] && [ "$run_intl" -eq 0 ] && [ "$run_speedtest" -eq 0 ]; then
      die "未选择任何测试项目"
    fi
    if [ "$run_edu" -eq 1 ] && [ "$run_intl" -eq 1 ]; then
      die "教育网回程与国际互联单独运行时请分两次执行，或启用三网回程后组合运行"
    fi
  fi

  [ "$run_edu" -eq 1 ] && selected_args+=("--cernet")
  [ "$run_intl" -eq 1 ] && selected_args+=("--intl")
  if [ "$run_speedtest" -eq 1 ]; then
    if [ "$run_route" -eq 0 ] && [ "$run_edu" -eq 0 ]; then
      if [ "$run_intl" -eq 1 ]; then
        die "国际互联和三网单线程速度单独运行时请分两次执行，或启用三网回程/教育网回程后追加测速"
      fi
      selected_args+=("--only-speedtest")
    else
      selected_args+=("--speedtest")
    fi
  fi

  if [ "$run_route" -eq 1 ] && [ "$run_edu" -eq 1 ] &&
     [ "$run_intl" -eq 1 ] && [ "$run_speedtest" -eq 1 ]; then
    selected_args=("--all")
  fi

  [ "$upload_rank" -eq 0 ] && selected_args+=("--no-rank-upload")

  set -- "${selected_args[@]}"
  INTERACTIVE_ARGS=("$@")
}

has_non_debug_args() {
  local arg
  for arg in "$@"; do
    [ "$arg" = "--debug" ] && continue
    return 0
  done
  return 1
}

has_debug_arg() {
  local arg
  for arg in "$@"; do
    [ "$arg" = "--debug" ] && return 0
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --distro)
      [ "$#" -ge 2 ] || die "--distro 缺少参数"
      DISTRO="$2"; shift 2
      ;;
    --rootfs)
      [ "$#" -ge 2 ] || die "--rootfs 缺少参数"
      ROOTFS_DIR="$2"; shift 2
      ;;
    --url)
      [ "$#" -ge 2 ] || die "--url 缺少参数"
      ROOTFS_URL="$2"; shift 2
      ;;
    --sha256)
      [ "$#" -ge 2 ] || die "--sha256 缺少参数"
      ROOTFS_SHA256="$2"; shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || die "--output 缺少参数"
      OUTPUT_DIR="$2"; shift 2
      ;;
    --keep) KEEP_ROOTFS=1; shift ;;
    --allow-speedtest) ALLOW_SPEEDTEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "未知参数: $1（主脚本参数请放在 -- 后）" ;;
  esac
done

case "$DISTRO" in
  debian|alpine) ;;
  *) die "--distro 只能是 debian 或 alpine" ;;
esac
[ -z "$ROOTFS_DIR" ] || [ -z "$ROOTFS_URL" ] ||
  die "--rootfs 与 --url 不能同时使用"
[ -z "$ROOTFS_SHA256" ] || [ -n "$ROOTFS_URL" ] ||
  die "--sha256 只能与 --url 一起使用"
[ -f "$TARGET_SCRIPT" ] || die "找不到 $TARGET_SCRIPT"
[ -f "$SELF_SCRIPT" ] || die "找不到 $SELF_SCRIPT"
[ "$(id -u)" -eq 0 ] || die "rootfs/chroot 运行需要 root 权限"
[ "$(uname -s)" = Linux ] || die "rootfs/chroot 模式仅支持 Linux；macOS/Windows 请使用 Docker 开发模式"

# Keep temporary mounts private when the host permits mount namespaces. Some
# constrained VPS containers reject unshare, so fall back to explicit cleanup.
if [ "${TCPQUALITY_MOUNT_NS:-0}" -eq 0 ] && command -v unshare >/dev/null 2>&1; then
  if unshare -m true >/dev/null 2>&1; then
    exec env TCPQUALITY_MOUNT_NS=1 unshare -m /bin/bash "$SELF_SCRIPT" "${ORIGINAL_ARGS[@]}"
  fi
fi
if [ "${TCPQUALITY_MOUNT_NS:-0}" -eq 1 ]; then
  mount --make-rprivate / >/dev/null 2>&1 ||
    mount -o rprivate / >/dev/null 2>&1 || true
fi

if has_debug_arg "$@"; then
  DEBUG_MODE=1
fi
if ! has_non_debug_args "$@"; then
  configure_interactive_args
  if [ "$DEBUG_MODE" -eq 1 ]; then
    set -- "${INTERACTIVE_ARGS[@]}" --debug
  else
    set -- "${INTERACTIVE_ARGS[@]}"
  fi
fi
if [ "$#" -gt 0 ]; then
  printf "[i] 主脚本参数:"
  printf " %q" "$@"
  printf "\n"
else
  echo "[i] 主脚本参数: 默认三网回程测试"
fi

for arg in "$@"; do
  case "$arg" in
    --speedtest-staged|--only-speedtest-staged)
      if [ "$DISTRO" = alpine ]; then
        die "Alpine 实验模式不运行北京三网三段限速测试；请使用默认 Debian rootfs"
      fi
      [ "$ALLOW_SPEEDTEST" -eq 1 ] ||
        die "rootfs 模式默认禁止北京三段限速测速修改宿主 qdisc/ifb；确认风险后使用 --allow-speedtest"
      ;;
  esac
done

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ALPINE_ARCH=x86_64; DEBIAN_ARCH=amd64; OCI_ARCH=amd64; OCI_VARIANT=""; DOCKER_PLATFORM=linux/amd64
    ;;
  aarch64|arm64)
    ALPINE_ARCH=aarch64; DEBIAN_ARCH=arm64; OCI_ARCH=arm64; OCI_VARIANT=v8; DOCKER_PLATFORM=linux/arm64
    ;;
  armv7l|armv7)
    ALPINE_ARCH=armv7; DEBIAN_ARCH=armhf; OCI_ARCH=arm; OCI_VARIANT=v7; DOCKER_PLATFORM=linux/arm/v7
    ;;
  armv6l|armv6)
    ALPINE_ARCH=armhf; DEBIAN_ARCH=armel; OCI_ARCH=arm; OCI_VARIANT=v5; DOCKER_PLATFORM=linux/arm/v5
    ;;
  *) die "暂不支持的 CPU 架构: $ARCH" ;;
esac

need_cmd tar
need_cmd mount
need_cmd umount
need_cmd chroot
need_cmd curl
need_cmd awk
need_cmd env
need_cmd grep
need_cmd sed
need_cmd tr

[ -z "$ROOTFS_SHA256" ] || [[ "$ROOTFS_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "--sha256 必须是 64 位十六进制 SHA256"

CREATED_ROOTFS=0
TEMP_ROOT_PARENT=""
RUNTIME_DIR=""
GUEST_TMP_HOST=""
OUTPUTS_PERSISTED=0
CHILD_PID=""
CHILD_SESSION=0
DOCKER_CID=""
DOCKER_IMAGE=""
DOCKER_REMOVE_IMAGE=0
MOUNTED=()
UNMOUNT_FAILED=0
INTERRUPTED=0
persist_guest_outputs() {
  local artifact base destination stem suffix counter
  [ "$OUTPUTS_PERSISTED" -eq 0 ] || return 0
  [ -n "${GUEST_TMP_HOST:-}" ] && [ -d "$GUEST_TMP_HOST" ] || return 0
  mkdir -p "$OUTPUT_DIR" || return 0

  for artifact in "$GUEST_TMP_HOST"/*.csv "$GUEST_TMP_HOST"/*.tar.gz "$GUEST_TMP_HOST"/*.log; do
    [ -f "$artifact" ] || continue
    base=$(basename -- "$artifact")
    destination="$OUTPUT_DIR/$base"
    if [ -e "$destination" ]; then
      case "$base" in
        *.tar.gz) stem=${base%.tar.gz}; suffix=.tar.gz ;;
        *) stem=${base%.*}; suffix=.${base##*.} ;;
      esac
      counter=1
      while [ -e "$OUTPUT_DIR/${stem}.${counter}${suffix}" ]; do
        counter=$((counter + 1))
      done
      destination="$OUTPUT_DIR/${stem}.${counter}${suffix}"
    fi
    if ! mv -- "$artifact" "$destination"; then
      echo "[!] 输出文件保留失败: $artifact -> $destination" >&2
    fi
  done
  OUTPUTS_PERSISTED=1
}

terminate_child() {
  local signal="${1:-TERM}" attempt
  [ -n "${CHILD_PID:-}" ] && kill -0 "$CHILD_PID" 2>/dev/null || return 0
  if [ "$CHILD_SESSION" -eq 1 ]; then
    kill "-$signal" -- "-$CHILD_PID" 2>/dev/null || true
  else
    kill "-$signal" "$CHILD_PID" 2>/dev/null || true
  fi
  for attempt in 1 2 3 4 5; do
    kill -0 "$CHILD_PID" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    if [ "$CHILD_SESSION" -eq 1 ]; then
      kill -KILL -- "-$CHILD_PID" 2>/dev/null || true
    else
      kill -KILL "$CHILD_PID" 2>/dev/null || true
    fi
  fi
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
}

cleanup() {
  local i target
  set +e
  terminate_child TERM
  if [ "$INTERRUPTED" -eq 0 ]; then
    persist_guest_outputs
  fi
  if [ -n "${DOCKER_CID:-}" ]; then
    docker rm -f "$DOCKER_CID" >/dev/null 2>&1 || true
    DOCKER_CID=""
  fi
  if [ "$DOCKER_REMOVE_IMAGE" -eq 1 ] && [ -n "${DOCKER_IMAGE:-}" ]; then
    docker image rm "$DOCKER_IMAGE" >/dev/null 2>&1 || true
    DOCKER_REMOVE_IMAGE=0
  fi
  for ((i=${#MOUNTED[@]}-1; i>=0; i--)); do
    target="${MOUNTED[$i]}"
    if ! umount "$target" >/dev/null 2>&1; then
      sleep 0.1
      if ! umount -R "$target" >/dev/null 2>&1 &&
         ! umount -R -l "$target" >/dev/null 2>&1 &&
         ! umount -l "$target" >/dev/null 2>&1; then
        UNMOUNT_FAILED=1
      fi
    fi
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$target"; then
      UNMOUNT_FAILED=1
    fi
  done
  if [ -n "${RUNTIME_DIR:-}" ] && [ -d "$RUNTIME_DIR" ]; then
    rm -rf -- "$RUNTIME_DIR"
  fi
  if [ "$CREATED_ROOTFS" -eq 1 ] &&
     { [ "$KEEP_ROOTFS" -eq 0 ] || [ "$INTERRUPTED" -eq 1 ]; } &&
     [ -n "${TEMP_ROOT_PARENT:-}" ] && [ -d "$TEMP_ROOT_PARENT" ]; then
    if [ "$UNMOUNT_FAILED" -eq 0 ]; then
      rm -rf -- "$TEMP_ROOT_PARENT"
    else
      echo "[!] 存在未卸载的挂载点，已保留临时 rootfs: $TEMP_ROOT_PARENT" >&2
    fi
  fi
  if [ "$INTERRUPTED" -eq 1 ] && [ "$UNMOUNT_FAILED" -eq 0 ]; then
    echo "[i] 已清理相关依赖" >&2
  fi
}
on_interrupt() {
  local signal="${1:-TERM}" status=143
  [ "$signal" = INT ] && status=130
  INTERRUPTED=1
  terminate_child "$signal"
  cleanup
  trap - EXIT
  exit "$status"
}
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM
trap cleanup EXIT

verify_sha256() {
  local checksum="$1" file="$2" actual
  checksum=$(printf '%s' "$checksum" | tr 'A-F' 'a-f')
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$checksum" "$file" | sha256sum -c - >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$checksum" ]
  else
    die "缺少 SHA256 校验工具（sha256sum 或 shasum）"
  fi
}

download_nexttrace_guest() {
  local asset_arch asset_name api_json asset_meta url digest binary
  case "$ARCH" in
    x86_64|amd64) asset_arch=amd64 ;;
    aarch64|arm64) asset_arch=arm64 ;;
    armv7l|armv7) asset_arch=armv7 ;;
    armv6l|armv6) asset_arch=armv6 ;;
    *) return 1 ;;
  esac
  asset_name="nexttrace-tiny_linux_${asset_arch}"
  api_json=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$NEXTTRACE_RELEASE_API" 2>/dev/null || true)
  if [ -n "$api_json" ]; then
    asset_meta=$(printf '%s\n' "$api_json" | awk -v name="$asset_name" '
      index($0, "\"name\": \"" name "\"") { found=1 }
      found && index($0, "\"digest\":") {
        line=$0
        sub(/^.*"digest": "sha256:/, "", line)
        sub(/".*$/, "", line)
        digest=line
      }
      found && index($0, "\"browser_download_url\":") {
        line=$0
        sub(/^.*"browser_download_url": "/, "", line)
        sub(/".*$/, "", line)
        url=line
      }
      found && url { print digest "|" url; exit }
    ') || true
    digest=${asset_meta%%|*}
    url=${asset_meta#*|}
  fi
  if [ -z "$url" ]; then
    digest=
    url="https://github.com/nxtrace/NTrace-core/releases/latest/download/$asset_name"
  fi

  binary="$RUNTIME_DIR/$asset_name"
  curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$binary" ||
    return 1
  if [ -n "$digest" ]; then
    verify_sha256 "$digest" "$binary" || return 1
  fi
  cp "$binary" "$ROOTFS_DIR/usr/local/bin/nexttrace-tiny"
  chmod 0755 "$ROOTFS_DIR/usr/local/bin/nexttrace-tiny"
  rm -f -- "$binary"
  env -i HOME=/root "PATH=$GUEST_PATH" TERM=dumb \
    chroot "$ROOTFS_DIR" /usr/local/bin/nexttrace-tiny -V >/dev/null 2>&1
}

download_extract() {
  local url="$1" archive="$2" checksum="${3:-}"
  echo "[i] 下载 rootfs: $url"
  if [ -z "$checksum" ]; then
    echo "[!] 自定义 rootfs 未提供 SHA256，仅适合可信下载源" >&2
  fi
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$archive" || die "rootfs 下载失败"
  if [ -n "$checksum" ]; then
    verify_sha256 "$checksum" "$archive" || die "rootfs SHA256 校验失败"
  fi
  mkdir -p "$ROOTFS_DIR"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$ROOTFS_DIR" ;;
    *.tar.xz) tar -xJf "$archive" -C "$ROOTFS_DIR" ;;
    *.tar.zst)
      if tar --help 2>&1 | grep -q -- '--zstd'; then
        tar --zstd -xf "$archive" -C "$ROOTFS_DIR"
      elif command -v unzstd >/dev/null 2>&1; then
        unzstd -c "$archive" | tar -xf - -C "$ROOTFS_DIR"
      else
        die "解压 .tar.zst 需要支持 --zstd 的 tar 或 unzstd"
      fi
      ;;
    *.tar) tar -xf "$archive" -C "$ROOTFS_DIR" ;;
    *) die "无法识别 rootfs 压缩格式: $archive" ;;
  esac
  rm -f -- "$archive"
}

build_alpine() {
  local metadata index checksum latest url_path
  if [ -n "$ROOTFS_URL" ]; then
    local archive="$TEMP_ROOT_PARENT/alpine-rootfs.tar"
    url_path=${ROOTFS_URL%%[\?#]*}
    case "$url_path" in
      *.tar.gz|*.tgz) archive="$TEMP_ROOT_PARENT/alpine-rootfs.tar.gz" ;;
      *.tar.xz) archive="$TEMP_ROOT_PARENT/alpine-rootfs.tar.xz" ;;
      *.tar.zst) archive="$TEMP_ROOT_PARENT/alpine-rootfs.tar.zst" ;;
    esac
    download_extract "$ROOTFS_URL" "$archive" "$ROOTFS_SHA256"
    return
  fi
  metadata=$(curl -fsSL --retry 3 \
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ALPINE_ARCH}/latest-releases.yaml") ||
    die "无法获取 Alpine minirootfs 元数据"
  index=$(printf '%s\n' "$metadata" |
    awk '$1=="flavor:" && $2=="alpine-minirootfs" {found=1; next}
         found && $1=="file:" {gsub(/"/, "", $2); print $2; exit}')
  checksum=$(printf '%s\n' "$metadata" |
    awk '$1=="flavor:" && $2=="alpine-minirootfs" {found=1; next}
         found && $1=="sha256:" {print $2; exit}')
  [ -n "$index" ] && [ -n "$checksum" ] || die "无法解析 Alpine minirootfs 元数据"
  latest="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ALPINE_ARCH}/${index}"
  download_extract "$latest" "$TEMP_ROOT_PARENT/$index" "$checksum"
}

download_debian_oci() {
  local registry="https://registry-1.docker.io"
  local repository="library/debian"
  local token index platform_line manifest_digest manifest layer_lines layer_count
  local layer_digest layer_file

  echo "[i] 下载官方 Debian ${DEBIAN_SUITE}-slim rootfs"
  token=$(curl -fsSL --retry 3 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" |
    sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
  [ -n "$token" ] || return 1

  index=$(curl -fsSL --retry 3 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "$registry/v2/$repository/manifests/${DEBIAN_SUITE}-slim") || return 1

  platform_line=$(printf '%s' "$index" | sed 's/},{/}\n{/g' |
    grep "\"platform\":{\"architecture\":\"${OCI_ARCH}\",\"os\":\"linux\"" |
    { if [ -n "$OCI_VARIANT" ]; then grep "\"variant\":\"${OCI_VARIANT}\""; else cat; fi; } |
    head -n 1) || return 1
  manifest_digest=$(printf '%s' "$platform_line" |
    sed -n 's/.*"digest":"\(sha256:[^"]*\)".*/\1/p')
  [ -n "$manifest_digest" ] || return 1

  manifest=$(curl -fsSL --retry 3 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "$registry/v2/$repository/manifests/$manifest_digest") || return 1
  layer_lines=$(printf '%s' "$manifest" | sed 's/},{/}\n{/g' |
    grep -E '"mediaType":"application/vnd\.(oci\.image\.layer\.v1\.tar\+gzip|docker\.image\.rootfs\.diff\.tar\.gzip)"') ||
    return 1
  layer_count=$(printf '%s\n' "$layer_lines" | awk 'NF {count++} END {print count+0}')
  [ "$layer_count" -eq 1 ] || return 1
  layer_digest=$(printf '%s\n' "$layer_lines" |
    sed -n 's/.*"digest":"\(sha256:[^"]*\)".*/\1/p' | head -n 1)
  [ -n "$layer_digest" ] || return 1

  layer_file="$TEMP_ROOT_PARENT/debian-rootfs.tar.gz"
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
    -H "Authorization: Bearer $token" \
    "$registry/v2/$repository/blobs/$layer_digest" -o "$layer_file" || return 1
  verify_sha256 "${layer_digest#sha256:}" "$layer_file" || return 1
  tar -xzf "$layer_file" -C "$ROOTFS_DIR" || return 1
  rm -f -- "$layer_file"
}

build_debian() {
  if [ -n "$ROOTFS_URL" ]; then
    local archive="$TEMP_ROOT_PARENT/debian-rootfs.tar" url_path
    url_path=${ROOTFS_URL%%[\?#]*}
    case "$url_path" in
      *.tar.gz|*.tgz) archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.gz" ;;
      *.tar.xz) archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.xz" ;;
      *.tar.zst) archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.zst" ;;
    esac
    download_extract "$ROOTFS_URL" "$archive" "$ROOTFS_SHA256"
    return
  fi
  if download_debian_oci; then
    return
  fi
  echo "[!] 官方 Debian OCI rootfs 下载失败，尝试本地构建方式" >&2
  rm -rf -- "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
  if command -v debootstrap >/dev/null 2>&1; then
    echo "[i] 使用 debootstrap 创建 Debian ${DEBIAN_SUITE} rootfs"
    debootstrap --variant=minbase --arch="$DEBIAN_ARCH" "$DEBIAN_SUITE" "$ROOTFS_DIR" \
      "https://deb.debian.org/debian" >/dev/null
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "[i] 未找到 debootstrap，使用 Docker 临时导出 Debian rootfs"
    DOCKER_IMAGE="debian:${DEBIAN_SUITE}-slim"
    if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
      DOCKER_REMOVE_IMAGE=1
    fi
    DOCKER_CID=$(docker create --platform "$DOCKER_PLATFORM" "$DOCKER_IMAGE" /bin/true) ||
      die "Docker 创建 Debian 容器失败"
    if ! docker export "$DOCKER_CID" | tar -xf - -C "$ROOTFS_DIR"; then
      docker rm -f "$DOCKER_CID" >/dev/null 2>&1 || true
      DOCKER_CID=""
      die "Docker 导出 Debian rootfs 失败"
    fi
    docker rm "$DOCKER_CID" >/dev/null 2>&1 || true
    DOCKER_CID=""
    if [ "$DOCKER_REMOVE_IMAGE" -eq 1 ]; then
      docker image rm "$DOCKER_IMAGE" >/dev/null 2>&1 || true
      DOCKER_REMOVE_IMAGE=0
    fi
    return
  fi
  die "创建 Debian rootfs 需要 debootstrap、Docker，或通过 --url 指定 rootfs tar 包"
}

canonical_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

available_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4+0}'
}

select_temp_base() {
  local base best="" best_free=0 free
  local -a candidates=()
  [ -n "${TCPQUALITY_ROOTFS_TMPDIR:-}" ] && candidates+=("$TCPQUALITY_ROOTFS_TMPDIR")
  [ -n "${TMPDIR:-}" ] && candidates+=("$TMPDIR")
  candidates+=("/var/tmp" "/tmp")

  for base in "${candidates[@]}"; do
    [ -d "$base" ] && [ -w "$base" ] || continue
    free=$(available_kb "$base")
    [ "$free" -gt 0 ] || continue
    if [ "$free" -ge "$MIN_ROOTFS_FREE_KB" ]; then
      printf '%s\n' "$base"
      return 0
    fi
    if [ "$free" -gt "$best_free" ]; then
      best="$base"
      best_free="$free"
    fi
  done

  [ -n "$best" ] || die "没有可写的临时目录"
  echo "[!] 临时目录可用空间不足 $((MIN_ROOTFS_FREE_KB / 1024))MB，使用最大可用目录: $best ($((best_free / 1024))MB)" >&2
  printf '%s\n' "$best"
}

validate_rootfs() {
  local resolved rootfs_id=""
  resolved=$(canonical_dir "$ROOTFS_DIR") || die "无法解析 rootfs 路径: $ROOTFS_DIR"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|"$SCRIPT_DIR")
      die "拒绝使用危险的 rootfs 路径: $resolved"
      ;;
  esac
  [ -r "$resolved/etc/os-release" ] || die "rootfs 缺少 /etc/os-release: $resolved"
  rootfs_id=$(sed -n 's/^ID=//p' "$resolved/etc/os-release" | head -n 1)
  rootfs_id=${rootfs_id#\"}
  rootfs_id=${rootfs_id%\"}
  [ "$rootfs_id" = "$DISTRO" ] ||
    die "rootfs 类型不匹配: 期望 $DISTRO，实际 ${rootfs_id:-unknown}"
  ROOTFS_DIR="$resolved"
}

assert_rootfs_path_safe() {
  local path rel resolved parent allow_symlink="${1:-0}"
  shift
  for rel in "$@"; do
    path="$ROOTFS_DIR/$rel"
    if [ "$allow_symlink" -eq 0 ] && [ -L "$path" ]; then
      die "rootfs 内 $rel 不能是符号链接: $path"
    fi
    if [ -e "$path" ]; then
      resolved=$(canonical_dir "$path") || die "无法解析 rootfs 内路径: $path"
      case "$resolved/" in
        "$ROOTFS_DIR/"*) ;;
        *) die "rootfs 内路径逃逸: $path -> $resolved" ;;
      esac
    else
      parent=$(dirname -- "$path")
      resolved=$(canonical_dir "$parent") || die "无法解析 rootfs 内父目录: $parent"
      case "$resolved/" in
        "$ROOTFS_DIR/"*) ;;
        *) die "rootfs 内父路径逃逸: $parent -> $resolved" ;;
      esac
    fi
  done
}

prepare_rootfs() {
  if [ -n "$ROOTFS_DIR" ]; then
    [ -d "$ROOTFS_DIR" ] || die "rootfs 目录不存在: $ROOTFS_DIR"
    validate_rootfs
    return
  fi
  TEMP_ROOT_PARENT=$(mktemp -d "$(select_temp_base)/tcpquality-rootfs.XXXXXX")
  ROOTFS_DIR="$TEMP_ROOT_PARENT/rootfs"
  mkdir -p "$ROOTFS_DIR"
  CREATED_ROOTFS=1
  if [ "$DISTRO" = alpine ]; then build_alpine; else build_debian; fi
  validate_rootfs
}

mount_guest() {
  RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-runtime.XXXXXX")
  GUEST_TMP_HOST="$RUNTIME_DIR/guest-tmp"
  mkdir -p "$GUEST_TMP_HOST"
  chmod 1777 "$GUEST_TMP_HOST"

  assert_rootfs_path_safe 0 dev proc sys tmp
  assert_rootfs_path_safe 1 root usr usr/local usr/local/bin etc lib
  mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/tmp"
  if mount --rbind /dev "$ROOTFS_DIR/dev" 2>/dev/null ||
     mount -o rbind /dev "$ROOTFS_DIR/dev" 2>/dev/null; then
    :
  else
    mount --bind /dev "$ROOTFS_DIR/dev" 2>/dev/null ||
      mount -o bind /dev "$ROOTFS_DIR/dev"
  fi
  MOUNTED+=("$ROOTFS_DIR/dev")
  mount --make-rslave "$ROOTFS_DIR/dev" >/dev/null 2>&1 ||
    mount -o rslave "$ROOTFS_DIR/dev" >/dev/null 2>&1 || true
  mount -t proc proc "$ROOTFS_DIR/proc"; MOUNTED+=("$ROOTFS_DIR/proc")
  if mount --rbind /sys "$ROOTFS_DIR/sys" 2>/dev/null ||
     mount -o rbind /sys "$ROOTFS_DIR/sys" 2>/dev/null; then
    :
  else
    mount --bind /sys "$ROOTFS_DIR/sys" 2>/dev/null ||
      mount -o bind /sys "$ROOTFS_DIR/sys"
  fi
  MOUNTED+=("$ROOTFS_DIR/sys")
  mount --make-rslave "$ROOTFS_DIR/sys" >/dev/null 2>&1 ||
    mount -o rslave "$ROOTFS_DIR/sys" >/dev/null 2>&1 || true
  mount -o remount,bind,ro "$ROOTFS_DIR/sys" >/dev/null 2>&1 || true

  mount --bind "$GUEST_TMP_HOST" "$ROOTFS_DIR/tmp" 2>/dev/null ||
    mount -o bind "$GUEST_TMP_HOST" "$ROOTFS_DIR/tmp"
  MOUNTED+=("$ROOTFS_DIR/tmp")

  if [ -d /lib/modules ]; then
    mkdir -p "$ROOTFS_DIR/lib/modules"
    mount --bind /lib/modules "$ROOTFS_DIR/lib/modules" 2>/dev/null ||
      mount -o bind /lib/modules "$ROOTFS_DIR/lib/modules"
    MOUNTED+=("$ROOTFS_DIR/lib/modules")
    mount -o remount,bind,ro "$ROOTFS_DIR/lib/modules" >/dev/null 2>&1 || true
  fi

  mkdir -p "$ROOTFS_DIR/etc"
  rm -f -- "$ROOTFS_DIR/etc/resolv.conf"
  cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null ||
    printf 'nameserver 1.1.1.1\n' > "$ROOTFS_DIR/etc/resolv.conf"
  if [ ! -e "$ROOTFS_DIR/etc/hosts" ]; then
    printf '127.0.0.1 localhost\n::1 localhost\n' > "$ROOTFS_DIR/etc/hosts"
  fi
}

install_guest_deps() {
  if [ "$DISTRO" = debian ]; then
    local apt_log="$GUEST_TMP_HOST/debian-rootfs-apt.log"
    if ! env -i HOME=/root "PATH=$GUEST_PATH" TERM=dumb chroot "$ROOTFS_DIR" /bin/bash -c \
      'export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; apt-get update -qq && apt-get install -y -qq --no-install-recommends bash ca-certificates coreutils curl dnsutils findutils gawk grep iproute2 iputils-ping kmod nmap ncurses-bin sed tar traceroute tzdata && rm -rf /var/lib/apt/lists/*' \
      >"$apt_log" 2>&1; then
      echo "[X] Debian rootfs 依赖安装失败" >&2
      echo "[i] apt/dpkg 日志已保留: $apt_log" >&2
      if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "[i] apt/dpkg 日志末尾:" >&2
        tail -n 80 "$apt_log" >&2 || true
      fi
      return 1
    fi
  else
    local apk_log="$GUEST_TMP_HOST/alpine-rootfs-apk.log"
    if ! env -i HOME=/root "PATH=$GUEST_PATH" TERM=dumb chroot "$ROOTFS_DIR" /bin/sh -c \
      'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; apk add --no-cache bash bind-tools ca-certificates coreutils curl findutils gawk grep iproute2 iputils kmod ncurses nmap-nping sed tar traceroute tzdata' \
      >"$apk_log" 2>&1; then
      echo "[X] Alpine rootfs 依赖安装失败" >&2
      echo "[i] apk 日志已保留: $apk_log" >&2
      if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "[i] apk 日志末尾:" >&2
        tail -n 80 "$apk_log" >&2 || true
      fi
      return 1
    fi
  fi
}

prepare_guest_files() {
  local nexttrace_path
  mkdir -p "$ROOTFS_DIR/root" "$ROOTFS_DIR/usr/local/bin"
  cp "$TARGET_SCRIPT" "$ROOTFS_DIR/root/runTcpQuality.sh"
  chmod 0755 "$ROOTFS_DIR/root/runTcpQuality.sh"

  if download_nexttrace_guest; then
    return 0
  fi
  echo "[!] 官方 nexttrace-tiny 下载或校验失败，尝试使用宿主 nexttrace-tiny/nexttrace" >&2
  nexttrace_path=$(command -v nexttrace-tiny 2>/dev/null || command -v nexttrace 2>/dev/null || true)
  if [ -n "$nexttrace_path" ] && [ -f "$nexttrace_path" ]; then
    cp -L "$nexttrace_path" "$ROOTFS_DIR/usr/local/bin/nexttrace-tiny"
    chmod 0755 "$ROOTFS_DIR/usr/local/bin/nexttrace-tiny"
    if ! env -i HOME=/root "PATH=$GUEST_PATH" TERM=dumb \
      chroot "$ROOTFS_DIR" /usr/local/bin/nexttrace-tiny -V >/dev/null 2>&1; then
      rm -f -- "$ROOTFS_DIR/usr/local/bin/nexttrace-tiny"
      echo "[!] 宿主 nexttrace-tiny/nexttrace 无法在 rootfs 内运行，IPv4大包回程将跳过" >&2
    fi
  else
    echo "[!] 未找到可用 nexttrace-tiny/nexttrace，IPv4大包回程将跳过" >&2
  fi
}

mkdir -p "$OUTPUT_DIR" || die "无法创建输出目录: $OUTPUT_DIR"
OUTPUT_DIR=$(canonical_dir "$OUTPUT_DIR") || die "无法解析输出目录: $OUTPUT_DIR"
prepare_rootfs
case "$OUTPUT_DIR/" in
  "$ROOTFS_DIR/"*) die "输出目录不能位于 rootfs 内部: $OUTPUT_DIR" ;;
esac
mount_guest
install_guest_deps || exit 1
prepare_guest_files
echo "[i] 进入临时 ${DISTRO} rootfs；退出后自动清理"
if [ "$KEEP_ROOTFS" -eq 1 ]; then
  echo "[i] --keep 已启用，rootfs 保留于: $ROOTFS_DIR"
fi

guest_env=(
  HOME=/root
  "PATH=$GUEST_PATH"
  LANG=C.UTF-8
  LC_ALL=C.UTF-8
  "TERM=${TERM:-dumb}"
  TCPQUALITY_INSIDE_ROOTFS=1
)
for env_name in \
  GET_NODES_URL TCPQUALITY_REPORT_API \
  HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY \
  http_proxy https_proxy no_proxy all_proxy; do
  if [ "${!env_name+x}" = x ]; then
    guest_env+=("$env_name=${!env_name}")
  fi
done
guest_command=(
  env -i "${guest_env[@]}"
  chroot "$ROOTFS_DIR" /bin/bash /root/runTcpQuality.sh "$@"
)

set +e
"${guest_command[@]}"
guest_rc=$?
set -e
persist_guest_outputs
exit "$guest_rc"
