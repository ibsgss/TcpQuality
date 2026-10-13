#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source <(sed '/^parse_args "\$@"$/,$d' runTcpQuality-core.sh)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture" "$RESULT_DIR"' EXIT
mkdir -p "$fixture/proc/self" "$fixture/cgroup/child"
proc_dir="$fixture/proc"
mount_dir="$fixture/cgroup"
assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$3" "$2" "$1" >&2
    exit 1
  fi
}
physical() {
  printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$proc_dir/meminfo"
}
v2() {
  printf '0::%s\n' "${1:-/child}" > "$proc_dir/self/cgroup"
  printf '1 0 0:1 %s %s ro - cgroup2 cgroup rw\n' "${2:-/}" "$mount_dir" > "$proc_dir/self/mountinfo"
}
physical 8388608 4194304
v2
printf 'max\n' > "$mount_dir/memory.max"
printf '134217728\n' > "$mount_dir/child/memory.max"
printf '16777216\n' > "$mount_dir/child/memory.current"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 112' 'v2 container limit and usage'
printf 'max\n' > "$mount_dir/child/memory.max"
printf '134217728\n' > "$mount_dir/memory.max"
printf '100663296\n' > "$mount_dir/memory.current"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 32' 'parent headroom with unlimited child'
printf '67108864\n' > "$mount_dir/child/memory.max"
printf '83886080\n' > "$mount_dir/child/memory.current"
assert_equal "$(detect_memory_mb "$proc_dir")" '64 0' 'over limit usage clamps to zero'
# A subtree bind mount maps the process path relative to the mount root.
v2 /tenant/child /tenant
printf '134217728\n' > "$mount_dir/child/memory.max"
printf '16777216\n' > "$mount_dir/child/memory.current"
printf 'max\n' > "$mount_dir/memory.max"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 112' 'subtree mount mapping'
# Private cgroup namespaces expose / even when mountinfo has a subtree root.
v2 / /tenant
printf '134217728\n' > "$mount_dir/memory.max"
printf '16777216\n' > "$mount_dir/memory.current"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 112' 'private namespace root'
printf '7:cpu,memory:/child\n' > "$proc_dir/self/cgroup"
printf '1 0 0:1 / %s ro - cgroup cgroup rw,cpu,memory\n' "$mount_dir" > "$proc_dir/self/mountinfo"
printf '9223372036854771712\n' > "$mount_dir/memory.limit_in_bytes"
printf '134217728\n' > "$mount_dir/child/memory.limit_in_bytes"
printf '16777216\n' > "$mount_dir/child/memory.usage_in_bytes"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 112' 'v1 unlimited sentinel and finite child'
printf '67108864\n' > "$mount_dir/memory.limit_in_bytes"
printf '33554432\n' > "$mount_dir/memory.usage_in_bytes"
assert_equal "$(detect_memory_mb "$proc_dir")" '64 32' 'v1 parent memory limit'
: > "$proc_dir/self/mountinfo"
physical 524288 98304
assert_equal "$(detect_memory_mb "$proc_dir")" '512 96' 'physical available memory'
physical 524288 0
assert_equal "$(detect_memory_mb "$proc_dir")" '512 0' 'zero available memory'
printf 'MemTotal: 131072 kB\n' > "$proc_dir/meminfo"
assert_equal "$(detect_memory_mb "$proc_dir")" '128 128' 'missing MemAvailable'
printf 'invalid\n' > "$proc_dir/meminfo"
assert_equal "$(detect_memory_mb "$proc_dir")" '512 512' 'unknown memory fallback'
# Exercise policy independently of the test machine's RAM.
eval "$(declare -f detect_memory_mb | sed '1s/detect_memory_mb/real_detect_memory_mb/')"
detect_memory_mb() { printf '%s %s\n' "$policy_total" "$policy_available"; }
for values in '128 112 1' '256 256 4' '512 512 9' '8192 8192 31' '128 0 1' '512 96 1'; do
  read -r policy_total policy_available expected <<< "$values"
  assert_equal "$(auto_parallel_by_memory)" "$expected" "policy $values"
done
policy_total=128 policy_available=112
PARALLEL=31 PARALLEL_EXPLICIT=1
apply_auto_parallel
assert_equal "$PARALLEL" 1 'manual high parallel is reduced'
policy_total=8192 policy_available=8192
PARALLEL=3 PARALLEL_EXPLICIT=1
apply_auto_parallel
assert_equal "$PARALLEL" 3 'manual smaller parallel is preserved'
# Do not even launch the LLVM/BTF compiler on a small machine.
policy_total=128 policy_available=112
bpftrace() { echo 'unexpected bpftrace invocation' >&2; exit 1; }
SPEEDTEST_RETRANS_TRACE_ENABLED=1
SPEEDTEST_RETRANS_TRACE_DISABLED=0
if speedtest_retrans_trace_start "$fixture/probe"; then
  echo 'FAIL: bpftrace should be skipped' >&2
  exit 1
fi
# A worker exiting without writing a result must not block later tasks.
PARALLEL=1
show_progress() { :; }
refresh_international_telegram_targets() { :; }
international_latency_families() { echo 4; }
check_iperf3() { :; }
INTERNATIONAL_IPERF_TARGETS=('local|local|local|127.0.0.1|5201')
INTERNATIONAL_SITE_TARGETS=('a|a' 'b|b' 'c|c')
INTERNATIONAL_CDN_TARGETS=()
INTERNATIONAL_TELEGRAM_DC_TARGETS=()
international_latency_test_one() {
  [ "$3" != upload ] || return 137
  printf 'OK\n' > "$RESULT_DIR/international_latency_${2}_${3}_${1}"
}
international_test_one() {
  [ "$1" != 2 ] || return 137
  sleep 0.1
  printf 'OK\n' > "$RESULT_DIR/internet_$1"
}
run_international_tests
[ -f "$RESULT_DIR/internet_1" ] && [ -f "$RESULT_DIR/internet_3" ]
assert_equal "$RESULTS_INCOMPLETE" 1 'missing worker results are reported'
assert_equal "$(jobs -pr | wc -l | tr -d ' ')" 0 'all workers finished after failure'
printf 'PASS: memory detection, concurrency policy, bpftrace guard, failed workers\n'
