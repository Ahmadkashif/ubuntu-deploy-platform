#!/usr/bin/env bash
# Start (or update) the edge stack for a profile, then restart the current release of every deployed app.
#   ./up.sh [profile]        profile defaults to the one used last (.profile) or bin/detect-host.sh's recommendation
# Idempotent: re-run after editing a profile or template. Generates secrets on first run (platform/secrets/, 0600).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
PROFILE="${1:-$(cat .profile 2>/dev/null || true)}"
if [ -z "$PROFILE" ]; then
  PROFILE="$(bin/detect-host.sh | awk -F= '/^RECOMMENDED=/{print $2}')"
fi
[ -n "$PROFILE" ] && [ "$PROFILE" != none ] || { echo "no profile (pass one: $(ls profiles | sed 's/.yaml//' | tr '\n' ' '))"; exit 2; }
bin/detect-host.sh --check "$PROFILE" >/dev/null || { echo "WARNING: this host does not meet the minimum of '$PROFILE' (bin/detect-host.sh)"; }
echo "$PROFILE" > .profile
echo "==> profile: $PROFILE"

python3 bin/render.py "$PROFILE"
B="build/$PROFILE/edge"
mkdir -p "$B/sites"
[ -f "$B/sites/apps.caddy" ] || echo "# no apps deployed yet (bin/ship writes this file)" > "$B/sites/apps.caddy"
[ -f "$B/sites/waf-apps.conf" ] || echo "# per-app WAF exclusions (bin/ship writes this file)" > "$B/sites/waf-apps.conf"

# ---- secrets (never committed; 0600) ----
umask 077
mkdir -p secrets
if [ ! -f secrets/edge.env ]; then
  echo "CROWDSEC_BOUNCER_KEY=$(openssl rand -hex 32)" > secrets/edge.env
  echo "==> generated secrets/edge.env (CrowdSec bouncer key)"
fi
set -a; . ./VERSIONS.env; . ./secrets/edge.env; set +a
if [ ! -f secrets/cosign.key ]; then
  openssl rand -hex 24 > secrets/cosign.password
  docker run --rm -u "$(id -u):$(id -g)" -e COSIGN_PASSWORD="$(cat secrets/cosign.password)" -v "$ROOT/secrets:/keys" -w /keys \
    "$COSIGN_IMAGE" generate-key-pair >/dev/null
  echo "==> generated cosign key pair (secrets/cosign.key, secrets/cosign.pub)"
fi
umask 022

# ---- pre-seed the Caddy access log so CrowdSec's file datasource attaches at startup ----
# CrowdSec starts before Caddy (Caddy waits for LAPI) and only globs its log files once, at boot. Caddy creates
# access.log lazily on the first matching request, so without this the caddy log scenarios never attach (found in
# Phase 7). Create it in the shared volume, owned by Caddy's uid, before anything starts.
EDGE_PROJECT="$(python3 bin/render.py --get "$PROFILE" edge.project)"
docker volume create "${EDGE_PROJECT}_caddy_logs" >/dev/null
docker run --rm -v "${EDGE_PROJECT}_caddy_logs:/l" busybox:1.37.0 sh -c 'touch /l/access.log && chown 65532:65532 /l/access.log && chmod 640 /l/access.log'

# ---- edge stack ----
docker compose -f "$B/compose.yaml" up -d --build --wait --wait-timeout 240
if [ "$(python3 bin/render.py --get "$PROFILE" exposure.tls)" = internal ]; then
  docker cp "$(grep ^CADDY_CONTAINER "$B/ship.env" | cut -d= -f2):/data/caddy/pki/authorities/local/root.crt" secrets/edge-ca.crt 2>/dev/null \
    && echo "==> local CA exported to secrets/edge-ca.crt (curl --cacert / add to your browser to trust *.$(python3 bin/render.py --get "$PROFILE" exposure.domain))"
fi

# ---- apps: restart each app's current release (containers are stopped by down.sh) ----
if [ -d "state/$PROFILE" ]; then
  for cur in state/"$PROFILE"/*/current; do
    [ -f "$cur" ] || continue
    ctr="$(awk -F= '/^CTR=/{print $2}' "$cur")"
    docker start "$ctr" >/dev/null 2>&1 && echo "==> started $ctr" || echo "WARN: could not start $ctr (redeploy with bin/ship deploy)"
  done
fi
docker compose -f "$B/compose.yaml" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
echo "==> up. Deploy an app:  bin/ship deploy <app-dir>     Stop everything:  ./down.sh"
