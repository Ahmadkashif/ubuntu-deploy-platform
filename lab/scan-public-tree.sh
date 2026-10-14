#!/usr/bin/env bash
# Pre-push scan of a staged public tree. Exit 1 on any finding. Patterns: private keys/PKI, env/secret files, tokens,
# this machine's identity (hostname, user, home path, tailnet names), private LAN addresses, company repo names.
#   lab/scan-public-tree.sh <dir> [extra-regex]
set -uo pipefail
D="$1"; X="${2:-}"; bad=0
hit() { echo "FINDING: $1"; bad=1; }
for f in $(find "$D" -type f \( -name '*.key' -o -name '*.pem' -o -name '*.crt' -o -name '*.p12' -o -name '.env' -o -name '*.env.local' -o -name 'edge.env' -o -name 'cosign.*' -o -name 'id_*' -o -name '*.password' \)); do hit "sensitive file name: $f"; done
P='BEGIN [A-Z ]*PRIVATE KEY|BEGIN CERTIFICATE|CROWDSEC_BOUNCER_KEY=[0-9a-f]{16}|COSIGN_PASSWORD=[^"$ ]|ghp_[A-Za-z0-9]{20}|github_pat_|gho_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|xox[bap]-|PrivateKey *= *[A-Za-z0-9+/]{40}'
grep -rnIE "$P" "$D" | grep -v 'scan-public-tree.sh' && bad=1
ID="$(hostname)|$(id -un)|/home/$(id -un)|\.ts\.net"   # plus private patterns passed as $2 (kept out of the repo)
[ -n "$X" ] && ID="$ID|$X"
grep -rnIiE "$ID" "$D" | grep -v 'scan-public-tree.sh' && bad=1
# private LAN addresses (lab uses documentation ranges; Docker bridges 172.16/12 are fine; flag 192.168 and 10.x outside the kit's tunnel nets)
grep -rnIE '\b192\.168\.[0-9]+\.[0-9]+' "$D" | grep -vE '192\.168\.1\.0/24|192\.168/16|192\.168\.0\.0/16' && bad=1
grep -rnIE '\b10\.[0-9]+\.[0-9]+\.[0-9]+' "$D" | grep -vE '10\.(66|77)\.0\.[0-9]+|10\.0\.0\.0/8|10/8' && bad=1
[ $bad -eq 0 ] && echo "SCAN CLEAN: $D" || echo "SCAN FOUND ISSUES (above)"
exit $bad
