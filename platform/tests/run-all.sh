#!/usr/bin/env bash
# Run every behaviour test against the running edge and store the output per test in <outdir>.
# Needs the three examples deployed (bin/ship deploy examples/{astro-static,vite-react-spa,nextjs-ssr}).
#   tests/run-all.sh <outdir>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"; cd "$ROOT"
D="$DOMAIN"; S=0; summary=""
t() { local name="$1"; shift; echo "### $name: $*"; { echo "# $name — profile $PROFILE — $(date -u +%FT%TZ)"; echo "# \$ $*"; "$@"; echo "# exit=$?"; } > "$OUT/$name.txt" 2>&1
      local rc; rc="$(tail -1 "$OUT/$name.txt" | sed 's/# exit=//')"; summary="$summary$(printf '%-28s %s' "$name" "$( [ "$rc" = 0 ] && echo PASS || echo "FAIL(rc=$rc)")")"$'\n'; [ "$rc" = 0 ] || S=1; }
t waf-signatures      tests/waf-verify.sh signatures
t rate-limit          tests/waf-verify.sh ratelimit
t tls-headers         tests/tls-headers.sh
t isolation           tests/isolation.sh
t crowdsec-ban        tests/crowdsec-ban.sh
for a in astro vite next; do t "csp-browser-$a" tests/csp-check.sh "$a.$D" /; done
t fp-crawl-astro      tests/fp-crawl.sh "astro.$D" / /docs/
t fp-crawl-vite       tests/fp-crawl.sh "vite.$D" /
t fp-crawl-next       tests/fp-crawl.sh "next.$D" / /about
t signature-gate      tests/signature-gate.sh next
t zero-downtime-redeploy tests/zero-downtime.sh "next.$D" /api/health -- bin/ship deploy examples/nextjs-ssr
t zero-downtime-rollback tests/zero-downtime.sh "next.$D" /api/health -- bin/ship rollback next
t zero-downtime-broken-release tests/broken-release.sh examples/astro-static "astro.$D" /
t proxy-protocol      tests/proxy-protocol.sh
t idle-footprint      sh -c "docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' \$(docker ps --format '{{.Names}}' | grep -E '^($EDGE_PROJECT-|astro-|vite-|next-)')"
printf '%s' "$summary" | tee "$OUT/SUMMARY.txt"
exit $S
