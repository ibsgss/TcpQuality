#!/usr/bin/env bash
set -eo pipefail
case "${1:-}" in
  --mount)
    [ -f /.dockerenv ] || { echo 'Run this test inside Docker' >&2; exit 1; }
    guest=$(mktemp -d /tmp/tcpquality-chroot.XXXXXX)
    mount --bind / "$guest"
    mount -t proc proc "$guest/proc"
    mount --rbind /sys "$guest/sys"
    mount --rbind /dev "$guest/dev"
    mount --bind /work "$guest/work"
    chroot "$guest" /bin/bash /work/tests/low-memory/chroot-memory.sh --verify
    ;;
  --verify)
    cd /work
    source <(sed '/^parse_args "\$@"$/,$d' runTcpQuality-core.sh)
    read -r total available < <(detect_memory_mb)
    [ "$total" -eq 128 ]
    [ "$(auto_parallel_by_memory)" -eq 1 ]
    printf 'PASS: chroot memory=%s MiB, available=%s MiB, parallel=1\n' "$total" "$available"
    ;;
  *) exit 2 ;;
esac
