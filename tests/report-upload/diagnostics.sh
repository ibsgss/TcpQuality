#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")/../.."
source <(sed '/^parse_args "\$@"$/,$d' runTcpQuality-core.sh)
fixture=$(mktemp -d)
server_pid=""
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$fixture" "$RESULT_DIR"
}
trap cleanup EXIT
python3 tests/report-upload/http_server.py "$fixture" > "$fixture/server.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 50); do
  [ ! -f "$fixture/port" ] || break
  kill -0 "$server_pid" 2>/dev/null || { cat "$fixture/server.log"; exit 1; }
  sleep 0.05
done
[ -f "$fixture/port" ]
api="http://127.0.0.1:$(cat "$fixture/port")"
csv="$fixture/report.csv"
printf 'network,family,latency\nlocal,IPv4,1.0\n' > "$csv"
# Exercise real curl errors without waiting for production retries/timeouts.
curl() {
  printf 'call\n' >> "$fixture/curl_calls"
  command curl "$@" --noproxy '*' --max-time 0.3 --retry 0
}
# Do not upload supplementary bundles, even to the local fixture.
upload_route_trace_bundles() { :; }
upload_speedtest_debug_bundle() { :; }
upload_probe_debug_bundle() { :; }
assert_contains() {
  grep -Fq "$2" "$1" || { echo "FAIL: missing $2" >&2; cat "$1"; exit 1; }
}
DEBUG_MODE=0
REPORT_API="$api/success"
upload_report "$csv" 'fixture time' > "$fixture/success.log"
assert_contains "$fixture/success.log" 'http://127.0.0.1/report/fixture'
cmp "$csv" "$fixture/received.csv"
REPORT_API="$api/http400"
upload_report "$csv" > "$fixture/http400.log"
assert_contains "$fixture/http400.log" 'HTTP 400'
assert_contains "$fixture/http400.log" 'invalid CSV columns'
assert_contains "$fixture/http400.log" "$csv"
REPORT_API="$api/missing-url"
upload_report "$csv" > "$fixture/missing-url.log"
assert_contains "$fixture/missing-url.log" 'HTTP 200'
assert_contains "$fixture/missing-url.log" '接口响应未包含有效报告链接'
REPORT_API="$api/disconnect"
upload_report "$csv" > "$fixture/disconnect.log"
assert_contains "$fixture/disconnect.log" 'curl 52'
assert_contains "$fixture/disconnect.log" 'Empty reply from server'
DEBUG_MODE=1
REPORT_API="$api/timeout"
upload_report "$csv" > "$fixture/timeout.log"
assert_contains "$fixture/timeout.log" 'curl 28'
assert_contains "$fixture/timeout.log" 'Operation timed out'
assert_contains "$fixture/timeout.log" "$csv"
[ "$(cat "$RESULT_DIR/report_upload_curl_status.txt")" = 28 ]
[ "$(cat "$RESULT_DIR/report_upload_http_code.txt")" = 000 ]
[ -s "$RESULT_DIR/report_upload_curl.err" ]
# A missing CSV must be rejected before curl can send an empty request body.
calls_before=$(wc -l < "$fixture/curl_calls")
upload_report "$fixture/missing.csv" > "$fixture/missing-file.log"
assert_contains "$fixture/missing-file.log" '本地 CSV 文件无法读取'
[ "$(wc -l < "$fixture/curl_calls")" = "$calls_before" ]
[ -s "$csv" ]
# Check the effective display for node probes and sequential speed tests.
PARALLEL=6 SPEEDTEST_ONLY=0
print_header > "$fixture/header.log"
assert_contains "$fixture/header.log" '当前并行节点数：6'
SPEEDTEST_ONLY=1
print_header > "$fixture/speed-header.log"
assert_contains "$fixture/speed-header.log" '当前并行节点数：1'
printf 'PASS: concurrency display, report upload success, HTTP errors, timeout, disconnect, missing file\n'
