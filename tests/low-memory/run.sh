#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
result_dir=$(mktemp -d "${TMPDIR:-/tmp}/tcpquality-low-memory.XXXXXX")
container=""
trap '[ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1' EXIT
bash -n runTcpQuality.sh runTcpQuality-rootfs.sh runTcpQuality-core.sh
for distro in debian alpine; do
  image="tcpquality-low-memory:$distro"
  docker build -t "$image" -f "tests/low-memory/Dockerfile.$distro" .
  mkdir -p "$result_dir/$distro"
  container=$(docker create --memory 128m --memory-swap 128m --network none \
    -e TERM=xterm -v "$PWD:/work:ro" -v "$result_dir/$distro:/results" \
    "$image" -c '
      set +e
      timeout 30 bash tests/low-memory/memory-policy.sh > /results/policy.log 2>&1
      policy_rc=$?
      timeout 30 bash tests/low-memory/results-preservation.sh > /results/preservation.log 2>&1
      preservation_rc=$?
      timeout 180 bash tests/low-memory/workload.sh -p 31 > /results/workload.log 2>&1
      workload_rc=$?
      cat /sys/fs/cgroup/memory.events > /results/memory.events
      cat /sys/fs/cgroup/memory.peak > /results/memory.peak
      [ "$policy_rc" -eq 0 ] && [ "$preservation_rc" -eq 0 ] && [ "$workload_rc" -eq 0 ]
    ')
  docker start -a "$container" || true
  status=$(docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}' "$container")
  [ "$status" = '0 false' ] || { cat "$result_dir/$distro"/*.log; echo "$distro failed: $status" >&2; exit 1; }
  awk '$1 == "oom_kill" && $2 != 0 {exit 1}' "$result_dir/$distro/memory.events"
  printf '%s: PASS, peak=%s bytes\n' "$distro" "$(cat "$result_dir/$distro/memory.peak")"
  docker rm "$container" >/dev/null
  container=""
done
printf 'Logs and reports: %s\n' "$result_dir"
