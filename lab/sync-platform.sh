#!/usr/bin/env bash
# Copy ../platform (code + templates + profiles, never build/state/secrets) into ~/platform on a lab VM.
#   lab/sync-platform.sh <vm>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
tar c -C "$HERE/../platform" --exclude=./build --exclude=./state --exclude=./secrets --exclude=./.profile . \
  | "$HERE/vmlab/vm" "$1" 'mkdir -p ~/platform && tar x -C ~/platform'
