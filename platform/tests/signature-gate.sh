#!/usr/bin/env bash
# Signature gate: the digest ship deployed verifies with secrets/cosign.pub; an image pushed around ship (unsigned) is
# refused by the same `cosign verify` call bin/ship runs before every `docker run`.
#   tests/signature-gate.sh [app]      (default: the first deployed app)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
APP="${1:-$(ls "$ROOT/state/$PROFILE" | head -1)}"
REF="$(awk -F= '/^REF=/{print $2}' "$ROOT/state/$PROFILE/$APP/current")"; DIG="${REF#*@}"
cos() { docker run --rm --network "$ADMIN_NETWORK" -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT/secrets:/keys:ro" "$COSIGN_IMAGE" \
  verify --key /keys/cosign.pub --insecure-ignore-tlog=true --allow-http-registry --allow-insecure-registry "$1" >/dev/null 2>/tmp/sg.$$; }
docker pull -q busybox:1.37.0 >/dev/null; docker tag busybox:1.37.0 "$REGISTRY_PUSH/unsigned-test:1"; docker push -q "$REGISTRY_PUSH/unsigned-test:1" >/dev/null
UDIG="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REGISTRY_PUSH/unsigned-test:1" | grep unsigned-test@ | head -1 | sed 's/.*@//')"
echo "=== signature gate ($PROFILE) $(date -u +%FT%TZ)"
rc=0
if cos "$REGISTRY_INTERNAL/$APP@$DIG"; then echo "$APP@$DIG -> VERIFIED"; else echo "$APP@$DIG -> REFUSED (BAD): $(tail -1 /tmp/sg.$$)"; rc=1; fi
if cos "$REGISTRY_INTERNAL/unsigned-test@$UDIG"; then echo "unsigned-test@$UDIG -> VERIFIED (BAD)"; rc=1; else echo "unsigned-test@$UDIG -> REFUSED: $(tail -1 /tmp/sg.$$)"; fi
rm -f /tmp/sg.$$; docker rmi "$REGISTRY_PUSH/unsigned-test:1" >/dev/null 2>&1
[ $rc -eq 0 ] && echo "PASS: signed digest verifies, unsigned digest refused"; exit $rc
