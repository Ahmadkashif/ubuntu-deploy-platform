#!/usr/bin/env bash
# Stop the edge stack and all ship-managed app containers. Keeps containers, volumes (certs, CrowdSec state,
# registry images, kamal-proxy routes) and state/, so ./up.sh brings everything back.
#   ./down.sh            stop
#   ./down.sh --purge    ALSO remove app containers, the stack, its networks and volumes (asks for confirmation)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
PROFILE="$(cat .profile 2>/dev/null || true)"
[ -n "$PROFILE" ] || { echo "no .profile — nothing was started with up.sh"; exit 0; }
B="build/$PROFILE/edge"
set -a; . ./VERSIONS.env; [ -f secrets/edge.env ] && . ./secrets/edge.env; set +a
apps="$(docker ps -aq --filter label=ship.managed=true)"
if [ "${1:-}" = --purge ]; then
  printf 'Remove ALL ship apps, the edge stack and its volumes for %s? [y/N] ' "$PROFILE"; read -r a
  [ "$a" = y ] || exit 1
  [ -n "$apps" ] && docker rm -f $apps >/dev/null
  docker compose -f "$B/compose.yaml" down -v
  rm -rf "state/$PROFILE"
  echo "==> purged"
  exit 0
fi
[ -n "$apps" ] && docker stop $apps >/dev/null && echo "==> stopped $(echo "$apps" | wc -l | tr -d ' ') app container(s)"
docker compose -f "$B/compose.yaml" stop
echo "==> down (volumes and containers kept; ./up.sh to resume)"
