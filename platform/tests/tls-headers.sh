#!/usr/bin/env bash
# TLS configuration + security-header audit of every deployed app, from a client on the edge's public network.
# TLS: protocol versions offered/refused (openssl s_client), certificate issuer/validity, HTTP->HTTPS redirect.
# Headers: required security headers present, fingerprinting headers absent — on normal pages and on a 404.
#   tests/tls-headers.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EDGE_IP="$(edge_ip)"
HOSTS="$(for f in "$ROOT"/state/"$PROFILE"/*/current; do awk -F= '/^HOSTS=/{print $2}' "$f"; done | tr '\n' ' ')"
docker run --rm --network "$PUBLIC_NETWORK" -e HOSTS="$HOSTS" -e EDGE_IP="$EDGE_IP" -e PORT="$HTTPS_PORT" -e HPORT="$HTTP_PORT" \
  "$LAB" bash -c '
fail=0
for h in $HOSTS; do
  echo "### $h"
  for v in tls1 tls1_1 tls1_2 tls1_3; do
    if echo | openssl s_client -connect "$EDGE_IP:$PORT" -servername "$h" -$v </dev/null >/tmp/o 2>&1 && grep -q "^New, TLS" /tmp/o; then
      echo "  $v: accepted ($(grep -m1 -oE "Cipher is [A-Z0-9_-]+" /tmp/o))"; case $v in tls1|tls1_1) fail=1;; esac
    else echo "  $v: refused"; case $v in tls1_2|tls1_3) fail=1;; esac; fi
  done
  echo | openssl s_client -connect "$EDGE_IP:$PORT" -servername "$h" 2>/dev/null | openssl x509 -noout -issuer -subject -dates -ext subjectAltName 2>/dev/null | sed "s/^/  cert: /"
  r=$(curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}" --resolve "$h:$HPORT:$EDGE_IP" "http://$h:$HPORT/")
  echo "  http://$h:$HPORT/ : $r"
  for path in / /definitely-not-here; do
    hdr=$(curl -sk -D - -o /dev/null --resolve "$h:$PORT:$EDGE_IP" "https://$h:$PORT$path")
    code=$(printf "%s" "$hdr" | head -1 | tr -d "\r")
    miss=""; for need in strict-transport-security content-security-policy x-content-type-options x-frame-options referrer-policy permissions-policy cross-origin-opener-policy; do
      printf "%s" "$hdr" | grep -qi "^$need:" || { miss="$miss $need"; fail=1; }; done
    leak=""; for bad in server x-powered-by via; do printf "%s" "$hdr" | grep -qi "^$bad:" && { leak="$leak $bad"; fail=1; }; done
    echo "  $path [$code] missing:${miss:- none} leaking:${leak:- none}"
  done
done
exit $fail'
rc=$?; [ $rc -eq 0 ] && echo "PASS: TLS >= 1.2 only, all security headers present, no fingerprint headers" || echo "FAIL (see above)"; exit $rc
