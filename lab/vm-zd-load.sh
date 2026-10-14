#!/usr/bin/env bash
# Zero-downtime under load on the real-host VM: client VM drives 10 source IPs x RPS req/s (new TLS connection each)
# at next.<domain>/api/health over the LAN, while the edge VM runs a redeploy and then a rollback of `next`.
#   lab/vm-zd-load.sh [rps-per-source]   (default 20 -> 200 req/s total; per-IP limit is 300/10s)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; V="$HERE/vmlab/vm"; RPS="${1:-20}"; SECS=150
"$V" edge 'cat ~/platform/secrets/edge-ca.crt' | "$V" client 'cat > ~/edge-ca.crt'
"$V" client 'cat > ~/loadgen.py' < "$HERE/loadgen.py"
"$V" client 'for i in $(seq 60 69); do sudo ip addr add 198.51.100.$i/24 dev eth0 2>/dev/null; done; true'
echo "=== zero-downtime under load $(date -u +%FT%TZ): 10 sources x $RPS req/s, new TLS connection per request, ${SECS}s"
"$V" client "nohup python3 ~/loadgen.py --host next.ship.test --ip 198.51.100.20 --path /api/health --ca ~/edge-ca.crt --sources 198.51.100.60-69 --rps $RPS --seconds $SECS --out /tmp/load.log >/tmp/loadgen.err 2>&1 </dev/null & echo loadgen started"
sleep 15
echo "--- [t+15s] redeploy next (new version) on the edge"
"$V" edge 'cd ~/platform && bin/ship deploy examples/nextjs-ssr 2>&1 | grep -E "\[[0-9]/9\]|DONE|ERROR|smoke"'
sleep 10
echo "--- rollback next"
"$V" edge 'cd ~/platform && bin/ship rollback next 2>&1 | tail -2'
echo "--- waiting for the load run to finish"
"$V" client "while pgrep -f "^python3 .*loadgen.py" >/dev/null; do sleep 2; done; cat /tmp/loadgen.err"
"$V" client 'python3 - <<"PY"
import collections
rows=[l.split() for l in open("/tmp/load.log")]
codes=collections.Counter(r[2] for r in rows); lat=sorted(int(r[3]) for r in rows)
t0=min(float(r[0]) for r in rows); t1=max(float(r[0]) for r in rows)
print("requests: %d over %.0fs = %.0f req/s" % (len(rows), t1-t0, len(rows)/(t1-t0)))
print("status codes:", dict(codes))
print("latency ms: p50=%d p95=%d p99=%d max=%d" % (lat[len(lat)//2], lat[int(len(lat)*.95)], lat[int(len(lat)*.99)], lat[-1]))
seen=[]; [seen.append(r[4]) for r in rows if r[4] not in seen]
print("versions in order of first appearance:", " -> ".join(seen))
bad=[r for r in rows if r[2]!="200"]
print("non-200: %d" % len(bad)); [print("  ", " ".join(r)) for r in bad[:20]]
per=collections.Counter(int(float(r[0])-t0)//10 for r in rows); print("req per 10s window:", [per[i] for i in sorted(per)])
PY'
