#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
sed '/^parse_args "\$@"$/,$d' runTcpQuality-core.sh > "$fixture/core.sh"
mkdir "$fixture/guest" "$fixture/output"
set +e
TMPDIR="$fixture/guest" bash -c 'source "$1"; echo completed-node > "$RESULT_DIR/cdn4_1"; exit 42' _ "$fixture/core.sh" > "$fixture/failure.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 42 ]
partial=("$fixture/guest"/tcpquality-results.*)
[ "${#partial[@]}" -eq 1 ] && [ -f "${partial[0]}/cdn4_1" ]
# Load only the wrapper's persistence function, without starting a rootfs.
source <(sed -n '/^persist_guest_outputs() {/,/^}/p' runTcpQuality-rootfs.sh)
GUEST_TMP_HOST="$fixture/guest" OUTPUT_DIR="$fixture/output" OUTPUTS_PERSISTED=0
persist_guest_outputs
[ -f "$fixture/output/$(basename "${partial[0]}")/cdn4_1" ]
[ ! -d "${partial[0]}" ]
TMPDIR="$fixture/guest" bash -c 'source "$1"; echo incomplete > "$RESULT_DIR/cdn4_1"; RESULTS_INCOMPLETE=1' _ "$fixture/core.sh" > "$fixture/incomplete.log" 2>&1
incomplete=("$fixture/guest"/tcpquality-results.*)
[ -f "${incomplete[0]}/cdn4_1" ]
rm -rf "${incomplete[0]}"
TMPDIR="$fixture/guest" bash -c 'source "$1"; echo done > "$RESULT_DIR/cdn4_1"' _ "$fixture/core.sh" > "$fixture/success.log" 2>&1
[ -z "$(find "$fixture/guest" -mindepth 1 -maxdepth 1 -name 'tcpquality-results.*' -print)" ]
printf 'PASS: failed runs preserved, rootfs outputs persisted, successful runs cleaned\n'
