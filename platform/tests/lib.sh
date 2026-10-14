# shellcheck shell=bash
# Common test setup: sourced by tests/*.sh. Everything comes from the active profile (platform/.profile or
# SHIP_PROFILE) — no profile values are hard-coded in tests.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${SHIP_PROFILE:-$(cat "$ROOT/.profile" 2>/dev/null || true)}"
[ -n "$PROFILE" ] || { echo "no profile — run ./up.sh <profile> first" >&2; exit 2; }
# shellcheck disable=SC1090
. "$ROOT/build/$PROFILE/edge/ship.env"
set -a; . "$ROOT/VERSIONS.env"; set +a
LAB=ship-fwlab:24.04                                     # test-client image (curl, openssl, nc, nft, dockerd)
EDGE_IMG="${EDGE_PROJECT}-caddy:${CADDY_VERSION}-crs${CRS_VERSION}"
HTTP_PORT="$(python3 "$ROOT/bin/render.py" --get "$PROFILE" exposure.http_port)"
TEST_HOST="${SHIP_TEST_HOST:-astro.$DOMAIN}"             # the app the WAF/CrowdSec tests hit (examples/astro-static)
docker image inspect "$LAB" >/dev/null 2>&1 || docker build -q -t "$LAB" "$ROOT/tests/fwlab" >/dev/null
edge_ip() { docker inspect "$CADDY_CONTAINER" --format "{{(index .NetworkSettings.Networks \"$PUBLIC_NETWORK\").IPAddress}}" 2>/dev/null; }
