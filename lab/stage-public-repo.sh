#!/usr/bin/env bash
# Build the public repo tree in <dest> from this research dir, then scan it. Never copies secrets/state/build/.profile,
# VM disks or keys. Redacts WireGuard public keys and lab-run image digests are kept (they are content hashes).
#   lab/stage-public-repo.sh <dest>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"; D="$1"
rm -rf "$D"; mkdir -p "$D"
rsync -a --exclude build --exclude state --exclude secrets --exclude .profile --exclude node_modules \
  --exclude 'apps.caddy*' --exclude 'waf-apps.conf*' "$SRC/platform/" "$D/platform/"
rsync -a --exclude state "$SRC/lab/" "$D/lab/"
rsync -a "$SRC/proof-linux/" "$D/proof-linux/"
mkdir -p "$D/verification"
[ -d "$SRC/phase-3/clean-room/vuefresh" ] && rsync -a --exclude node_modules --exclude dist "$SRC/phase-3/clean-room/vuefresh/" "$D/verification/vuefresh/"
[ -f "$SRC/phase-3/clean-room/log.md" ] && cp "$SRC/phase-3/clean-room/log.md" "$D/verification/clean-room-log.md"
cp "$SRC/STATUS.md" "$SRC/backlog.md" "$D/" 2>/dev/null || true
# redact WireGuard public keys (44-char base64 ending in '=') in evidence/logs
grep -rlE '[A-Za-z0-9+/]{43}=' "$D/proof-linux" "$D/verification" 2>/dev/null | while read -r f; do
  sed -i -E 's#[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=#<wg-public-key-redacted>#g' "$f"; done
# local absolute paths in evidence -> repo-relative
grep -rlF "$SRC" "$D" 2>/dev/null | while read -r f; do sed -i "s#$SRC/#./#g; s#$SRC#.#g" "$f"; done
grep -rlF "$HOME" "$D" 2>/dev/null | while read -r f; do sed -i "s#$HOME#~#g" "$f"; done
echo "staged: $(find "$D" -type f | wc -l) files"
