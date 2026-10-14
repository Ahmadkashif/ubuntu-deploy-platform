#!/usr/bin/env bash
# Zero-downtime check: a client on the edge's public network requests <host> every 0.1 s (well under the rate limit)
# while <command> runs (a redeploy, a rollback, a broken deploy...). Prints status-code counts and the versions seen.
#   tests/zero-downtime.sh <host> <path> -- <command...>
#   e.g. tests/zero-downtime.sh next.localhost /api/health -- bin/ship deploy examples/nextjs-ssr
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
H="$1"; P="$2"; shift 2; [ "${1:-}" = -- ] && shift
EDGE_IP="$(edge_ip)"
OUT="$(mktemp -d)"
cid=$(docker run -d --network "$PUBLIC_NETWORK" -v "$OUT:/out" -e H="$H" -e P="$P" -e PORT="$HTTPS_PORT" -e EDGE_IP="$EDGE_IP" \
  "$LAB" bash -c 'while true; do
     r=$(curl -sk --max-time 5 -w " %{http_code}" --resolve "$H:$PORT:$EDGE_IP" "https://$H:$PORT$P" 2>/dev/null || echo " 000")
     code="${r##* }"; ver="$(printf "%s" "$r" | grep -oE "\"version\":\"[^\"]*\"|id=\"v\">[^<]*" | head -1 | sed -E "s/^\"version\":\"//; s/\"$//; s/^id=\"v\">//")"
     echo "$(date +%s.%N | cut -c1-14) $code ${ver:--}" >> /out/log; sleep 0.1; done')
sleep 3
echo "== running: $*"
"$@"; rc=$?
sleep 3
docker rm -f "$cid" >/dev/null
echo "== command exit code: $rc"
echo "== requests during the run: $(wc -l < "$OUT/log" | tr -d ' ')"
echo "== status codes:"; awk '{print $2}' "$OUT/log" | sort | uniq -c
echo "== versions served (in order of first appearance):"; awk '{print $3}' "$OUT/log" | awk '!s[$0]++'
bad=$(awk '$2 !~ /^2/' "$OUT/log" | wc -l | tr -d ' ')
echo "== non-2xx: $bad"
cp "$OUT/log" "${ZD_LOG:-/dev/null}" 2>/dev/null || true
rm -rf "$OUT"
[ "$bad" -eq 0 ]
