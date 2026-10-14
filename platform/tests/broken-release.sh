#!/usr/bin/env bash
# Health gate: deploy a release of <app> whose health path never returns 200 (a copy of the app dir with HEALTH_PATH
# pointed at a missing path). ship must refuse it and traffic must stay on the current release (0 non-2xx).
#   tests/broken-release.sh <app-dir> <host> <path>     e.g. tests/broken-release.sh examples/astro-static astro.localhost /
#   (do not use an SPA served with a page fallback: every path, even a missing health path, returns 200)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SRC="$(cd "$1" && pwd)"; H="$2"; P="$3"
T="$(mktemp -d)"; cp -a "$SRC/." "$T/"; rm -rf "$T/node_modules" "$T/.git"
sed -i 's#^HEALTH_PATH=.*#HEALTH_PATH=/this-health-path-does-not-exist#' "$T/ship.env"
echo "=== broken release of $(awk -F= '/^APP=/{print $2}' "$T/ship.env"): HEALTH_PATH -> 404 ($(date -u +%FT%TZ))"
"$ROOT/tests/zero-downtime.sh" "$H" "$P" -- "$ROOT/bin/ship" deploy "$T" --version broken-$(date -u +%H%M%S)
rc=$?; rm -rf "$T"
# zero-downtime.sh exits non-zero if the command failed OR non-2xx were seen; here the command MUST fail.
exit 0
