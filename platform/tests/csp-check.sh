#!/usr/bin/env bash
# Real-browser check through the full edge: headless Chromium (chromedp/headless-shell) on the edge's public Docker
# network, driven over DevTools by tests/browser-check.mjs in a node container. Reports CSP violations, console errors,
# whether client JS ran (#js-status) and whether a click handler works. Exit 1 on any CSP violation.
#   tests/csp-check.sh <host> [path]       e.g. tests/csp-check.sh next.localhost /
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
H="$1"; P="${2:-/}"
IP="$(docker inspect "$CADDY_CONTAINER" --format "{{(index .NetworkSettings.Networks \"$PUBLIC_NETWORK\").IPAddress}}")"
# Chrome only binds DevTools to loopback, so socat (shipped in the image) exposes it on :9222 inside the network.
cid=$(docker run -d --rm --network "$PUBLIC_NETWORK" --entrypoint sh chromedp/headless-shell:latest -c \
  "socat TCP4-LISTEN:9222,fork TCP4:127.0.0.1:9223 & exec /headless-shell/headless-shell --no-sandbox --disable-gpu \
   --ignore-certificate-errors '--host-resolver-rules=MAP $H $IP' --remote-debugging-port=9223 about:blank")
CIP="$(docker inspect "$cid" --format "{{(index .NetworkSettings.Networks \"$PUBLIC_NETWORK\").IPAddress}}")"
sleep 2
docker run --rm --network "$PUBLIC_NETWORK" -v "$ROOT/tests:/t:ro" node:24.21.0-alpine node /t/browser-check.mjs "$CIP" "https://$H:$HTTPS_PORT$P"
rc=$?
docker rm -f "$cid" >/dev/null 2>&1
[ $rc -eq 0 ] && echo "PASS: 0 CSP violations" || echo "FAIL: CSP violations (see above)"
exit $rc
