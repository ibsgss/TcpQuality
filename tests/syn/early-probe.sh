#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
core=${1:-"$root/runTcpQuality-core.sh"}
source <(sed '/^parse_args "\$@"$/,$d' "$core")
sent='SENT (0.0000s) TCP [192.0.2.1:30000 > 192.0.2.2:443 S seq=4000 ack=0 off=5]'
wrong='RCVD (0.0100s) TCP [192.0.2.2:443 > 192.0.2.1:30000 RA seq=0 ack=3999 off=5]'
right='RCVD (0.5000s) TCP [192.0.2.2:443 > 192.0.2.1:30000 RA seq=0 ack=4001 off=5]'
[[ $(nping_matching_min_rtt "$sent
$wrong
$right" 4000 0) = 500.000 ]]
if nping_matching_min_rtt "$sent
$wrong" 4000 0 >/dev/null; then echo 'stale ACK counted' >&2; exit 1; fi
payload='RCVD (0.3000s) TCP [192.0.2.2:443 > 192.0.2.1:30000 RA seq=0 ack=4101 off=5]'
[[ $(nping_matching_min_rtt "$sent
$payload" 4000 100) = 300.000 ]]
sent6='SENT (0.0000s) TCP [2001:db8::1:30000 > 2001:db8::2:443 S seq=4000 ack=0 off=5]'
reply6='RCVD (0.1200s) TCP [2001:db8::2:443 > 2001:db8::1:30000 SA seq=10 ack=4001 off=5]'
[[ $(nping_matching_min_rtt "$sent6
$reply6" 4000 0) = 120.000 ]]
tmp=$(mktemp -d)
cat > "$tmp/nping" <<'PY'
#!/usr/bin/env python3
import os, signal, sys, time
def stop(sig, frame):
    open(os.environ['MARKER'], 'w').close()
    print('Raw packets sent: 1 | Rcvd: 4 | Lost: 0', flush=True)
    sys.exit(1)
signal.signal(signal.SIGINT, stop)
print('SENT (0.0000s) TCP [192.0.2.1:30000 > 192.0.2.2:443 S seq=4000 ack=0 off=5]', flush=True)
print('RCVD (0.0100s) TCP [192.0.2.2:443 > 192.0.2.1:30000 RA seq=0 ack=3999 off=5]', flush=True)
print('RCVD (0.0200s) TCP [192.0.2.2:443 > 192.0.2.1:30001 RA seq=0 ack=4001 off=5]', flush=True)
print('RCVD (0.0300s) TCP [192.0.2.2:443 > 192.0.2.1:30000 R seq=0 ack=4001 off=5]', flush=True)
time.sleep(.5)
if os.environ['MODE'] == 'valid':
    print('RCVD (0.5000s) TCP [192.0.2.2:443 > 192.0.2.1:30000 RA seq=0 ack=4001 off=5]', flush=True)
time.sleep(.5)
print('Raw packets sent: 1 | Rcvd: 3 | Lost: 0', flush=True)
PY
chmod +x "$tmp/nping"
export PATH="$tmp:$PATH" MARKER="$tmp/interrupted"
export MODE=valid
raw=$(nping_early_probe -c 1 192.0.2.2)
[[ -f "$MARKER" ]]
[[ $(nping_matching_min_rtt "$raw" 4000 0) = 500.000 ]]
rm -f "$MARKER"
export MODE=invalid
raw=$(nping_early_probe -c 1 192.0.2.2)
[[ ! -f "$MARKER" ]]
if nping_matching_min_rtt "$raw" 4000 0 >/dev/null; then echo 'invalid response counted' >&2; exit 1; fi
echo 'PASS: stale ACK, wrong tuple, ACK flag, late valid reply, IPv6 and payload'
rm -rf "$tmp"
