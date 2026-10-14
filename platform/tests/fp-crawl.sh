#!/usr/bin/env bash
# WAF false-positive crawl: fetch every page + every asset referenced by it, plus framework-specific requests
# (Next.js RSC navigation headers, prefetch, server action POSTs), through the full edge. Prints status counts;
# exit 1 if any request got 403 (a WAF/CrowdSec block on legitimate traffic).
#   tests/fp-crawl.sh <host> [paths...]      e.g. tests/fp-crawl.sh next.localhost / /about
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
H="$1"; shift; PATHS="${*:-/}"
TLS="-k"; [ -f "$ROOT/secrets/edge-ca.crt" ] && TLS="--cacert $ROOT/secrets/edge-ca.crt"
BASE="https://$H:$HTTPS_PORT"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
tmp="$(mktemp -d)"; results="$tmp/results"
req() { # req <label> <curl args...>
  local label="$1"; shift
  local code; code=$(curl -s -o "$tmp/body" -w '%{http_code}' $TLS --resolve "$H:$HTTPS_PORT:$SMOKE_IP" -A "$UA" "$@")
  echo "$code $label" >> "$results"; echo "$code $label"
}
for p in $PATHS; do
  req "GET $p" "$BASE$p"; cp "$tmp/body" "$tmp/page.html"
  for a in $(grep -oE '(src|href)="/[^"]*"' "$tmp/page.html" | sed -E 's/^(src|href)="//; s/"$//' | sort -u); do
    req "GET $a (asset of $p)" "$BASE$a"
  done
done
if grep -q '_next/' "$tmp/page.html" 2>/dev/null || [ "${NEXTJS:-}" = 1 ]; then
  TREE='%5B%22%22%2C%7B%22children%22%3A%5B%22__PAGE__%22%2C%7B%7D%2C%22%2F%22%2C%22refresh%22%5D%7D%2Cnull%2Cnull%2Ctrue%5D'
  for p in $PATHS; do
    req "RSC nav $p" -H 'RSC: 1' -H "Next-Router-State-Tree: $TREE" -H "Next-Url: $p" "$BASE$p?_rsc=1a2b3"
    req "RSC prefetch $p" -H 'RSC: 1' -H 'Next-Router-Prefetch: 1' -H "Next-Router-State-Tree: $TREE" "$BASE$p?_rsc=4c5d6"
  done
  curl -s $TLS --resolve "$H:$HTTPS_PORT:$SMOKE_IP" -A "$UA" "$BASE/" > "$tmp/home.html"
  AID="$(grep -oE 'ACTION_ID_[0-9a-f]+' "$tmp/home.html" | head -1 | sed 's/ACTION_ID_//')"
  if [ -n "$AID" ]; then
    req "server action (no-JS form post, multipart)" -F "\$ACTION_ID_$AID=" -F 'msg=hello world, this is a normal message!' "$BASE/"
    req "server action (JS fetch, Next-Action header)" -X POST -H "Next-Action: $AID" -H 'Accept: text/x-component' \
      -H 'Content-Type: text/plain;charset=UTF-8' -H "Next-Router-State-Tree: $TREE" --data '[{"msg":"hello world"}]' "$BASE/"
  fi
fi
echo "--- summary for $H"; cut -d' ' -f1 "$results" | sort | uniq -c
if grep -q '^403 ' "$results"; then echo "FAIL: legitimate requests were blocked:"; grep '^403 ' "$results"; exit 1; fi
echo "PASS: 0 blocked (no WAF false positives)"
