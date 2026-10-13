#!/usr/bin/env bash
# Keep the real main flow/schedulers/report writer; replace external network
# workers with deterministic 24 MiB workloads. No dependency installs/uploads.
set -eo pipefail
cd "$(dirname "$0")/../.."
core="${TCPQUALITY_TEST_CORE:-runTcpQuality-core.sh}"
source <(sed '/^parse_args "\$@"$/,$d' "$core")
allocate() {
  python3 -c 'import time; data=bytearray(24*1024*1024); time.sleep(0.15)'
}
clear() { :; }
check_curl() { :; }
check_nping() { :; }
check_traceroute() { :; }
check_nexttrace() { return 0; }
check_iperf3() { :; }
require_raw_socket_privilege() { :; }
detect_ip_stack() { IPV4_WORK=1; IPV6_WORK=1; }
require_remote_nodes() {
  REMOTE_CDN4_NODES=() REMOTE_CDN6_NODES=()
  REMOTE_CERNET_NODES=() REMOTE_CERNET2_NODES=()
  for ((n=1; n<=12; n++)); do
    REMOTE_CDN4_NODES+=("北京|电信|local$n|127.0.0.1|80")
    REMOTE_CDN6_NODES+=("北京|电信|local$n|::1|80")
    REMOTE_CERNET_NODES+=("北京|local$n|127.0.0.1|80")
    REMOTE_CERNET2_NODES+=("北京|local$n|::1|80")
  done
}
ipv6_nping_precheck() { :; }
large_packet_precheck() { return 0; }
route_trace_one() {
  allocate
  printf 'OK|%s|%s|%s|%s|fixture\n' "$3" "$4" "$2" "$5" > "$RESULT_DIR/${9}_$6"
}
test_one() {
  allocate
  printf 'OK|%s|%s|%s|%s|1|1|0.00|1.00\n' "$3" "$4" "$5" "$7" > "$RESULT_DIR/${1}_$6"
}
test_large_one() { test_one "$@"; }
refresh_international_telegram_targets() { :; }
international_latency_families() { printf '4\n6\n'; }
INTERNATIONAL_IPERF_TARGETS=('local|local|local|127.0.0.1|5201')
INTERNATIONAL_SITE_TARGETS=() INTERNATIONAL_CDN_TARGETS=()
INTERNATIONAL_TELEGRAM_DC_TARGETS=()
for ((n=1; n<=12; n++)); do
  INTERNATIONAL_SITE_TARGETS+=("site$n|local$n")
  INTERNATIONAL_CDN_TARGETS+=("cdn$n|local|local$n")
done
international_latency_test_one() {
  allocate
  printf 'OK|%s|%s|%s|%s|%s|%s|127.0.0.1|1.00|0\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$RESULT_DIR/international_latency_${2}_${3}_$1"
}
international_test_one() {
  allocate
  printf 'OK|%s|%s|%s|127.0.0.1|1|1|0.00|1.00|4\n' "$2" "$3" "$5" > "$RESULT_DIR/internet_$1"
}
speedtest_applecdn_tests_enabled() { return 1; }
speedtest_applecdn6_tests_enabled() { return 1; }
speedtest_group_specs() { printf '不限|cn-beijing|0\n'; }
collect_speedtest_results() {
  allocate
  local metric='1|0|1|127.0.0.1|北京|1|1|1|1'
  printf 'ROW\t不限;%s;%s;%s\n' "$metric" "$metric" "$metric" > "$SPEEDTEST_STATE_FILE"
  printf '3/3\n' > "$SPEEDTEST_PROGRESS_FILE"
}
parse_args --all --no-rank-upload "$@"
apply_auto_parallel
printf 'selected_parallel=%s\n' "$PARALLEL"
main
report=(/tmp/zstatic_nping_*.csv)
[ "${#report[@]}" -eq 1 ]
# 60 domestic/education probes, 24 site/CDN, 4 iPerf and 3 speed rows.
[ "$(wc -l < "${report[0]}")" -ge 92 ]
for section in 三网 大包 CERNET CERNET2 国际互联 三网单线程速度; do
  grep -q "$section" "${report[0]}"
done
cp "${report[0]}" /results/workload.csv
printf 'PASS: four-stage workload and report completed\n'
