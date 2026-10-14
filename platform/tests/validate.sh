#!/usr/bin/env bash
# Render every profile and validate every generated artefact with the real tool — without running anything on this
# machine's network. Ubuntu-only files are checked inside an unprivileged Ubuntu 24.04 container (tests/fwlab).
#   tests/validate.sh            -> PASS/FAIL table, exit 1 on any FAIL
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a; . ./VERSIONS.env; set +a
LAB=ship-fwlab:24.04
# the edge image of whichever profile was brought up last (its name carries that profile's edge.project)
EDGE_IMG="$(python3 bin/render.py --get "$(cat .profile 2>/dev/null || echo ubuntu-vps-small)" edge.project)-caddy:${CADDY_VERSION}-crs${CRS_VERSION}"
docker image inspect "$LAB" >/dev/null 2>&1 || docker build -q -t "$LAB" tests/fwlab >/dev/null
docker image inspect "$EDGE_IMG" >/dev/null 2>&1 || { echo "edge image $EDGE_IMG missing — run ./up.sh once"; exit 2; }
fails=0; rows=""
row() { rows="$rows$(printf '%-20s %-34s %s' "$1" "$2" "$3")"$'\n'; case "$3" in PASS*) ;; *) fails=$((fails+1));; esac; }
run() { local p="$1" what="$2"; shift 2; local out; if out="$("$@" 2>&1)"; then row "$p" "$what" PASS; else row "$p" "$what" "FAIL: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"; fi; }

python3 bin/render.py --all >/dev/null || { echo "render failed"; exit 1; }
run all "templates host-agnostic" python3 bin/render.py --check-agnostic

SAMPLE_SITES="$(mktemp -d)"; chmod 755 "$SAMPLE_SITES"   # mktemp -d is 0700: the edge image runs as uid 65532 (hidden by Docker Desktop file sharing)
cat > "$SAMPLE_SITES/apps.caddy" <<'EOF'
app1.example.invalid, app2.example.invalid {
	import protect 1
	@app_app1 host app1.example.invalid
	header @app_app1 {
		defer
		Content-Security-Policy "default-src 'self'"
	}
	import to_proxy
}
EOF
echo 'SecRule REQUEST_HEADERS:Host "@rx ^app2\.example\.invalid$" "id:10001,phase:1,pass,nolog,setvar:tx.dummy=1"' > "$SAMPLE_SITES/waf-apps.conf"
chmod 644 "$SAMPLE_SITES"/*

for p in $(ls profiles | sed 's/\.yaml$//'); do
  B="build/$p"
  run "$p" "compose config" env CROWDSEC_BOUNCER_KEY=validate docker compose -f "$B/edge/compose.yaml" config -q
  run "$p" "caddy validate (edge image + CRS)" docker run --rm -e CROWDSEC_API_KEY=validate \
    -v "$ROOT/$B/edge/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$SAMPLE_SITES:/etc/caddy/sites:ro" \
    -v "$ROOT/edge/bots.caddy:/etc/caddy/bots.caddy:ro" "$EDGE_IMG" validate --config /etc/caddy/Caddyfile --adapter caddyfile
  run "$p" "crowdsec acquis/whitelist YAML" python3 - "$B/edge/crowdsec" <<'PY'
import sys, os
for base, _, files in os.walk(sys.argv[1]):
    for f in files:
        t = open(os.path.join(base, f)).read()
        assert ":" in t and "\t" not in t, f
PY
  if [ -d "$B/host" ]; then
    run "$p" "nft -c host firewall" docker run --rm --cap-add NET_ADMIN -v "$ROOT/$B/host:/h:ro" "$LAB" nft -c -f /h/nftables.conf
    run "$p" "dockerd --validate daemon.json" docker run --rm -v "$ROOT/$B/host:/h:ro" "$LAB" dockerd --validate --config-file /h/daemon.json
    run "$p" "sshd -t with drop-in" docker run --rm -v "$ROOT/$B/host:/h:ro" "$LAB" bash -c \
      'ssh-keygen -A >/dev/null && mkdir -p /run/sshd && cp /h/sshd-hardening.conf /etc/ssh/sshd_config.d/10-ship.conf && sshd -t'
    # unprivileged: sysctl -N only reads /proc/sys (no module loading, nothing on the machine changes)
    run "$p" "sysctl keys exist" docker run --rm -v "$ROOT/$B/host:/h:ro" "$LAB" bash -c \
      'miss=0; for k in $(grep -E "^[a-z]" /h/sysctl-hardening.conf | cut -d= -f1); do
         sysctl -N "$k" >/dev/null 2>&1 && continue
         case "$k" in net.core.bpf_jit_harden) echo "lab-kernel gap (no BPF JIT sysctl on this kernel, e.g. LinuxKit; present on Ubuntu kernels): $k" >&2;; *) echo "missing $k"; miss=1;; esac
       done; exit $miss'
    run "$p" "wg-quick strip wg0.conf" docker run --rm -v "$ROOT/$B/host:/h:ro" "$LAB" bash -c \
      'cp /h/wg0.conf /tmp/wg0.conf && wg-quick strip /tmp/wg0.conf >/dev/null'
    run "$p" "bash -n install-host.sh" bash -n "$B/host/install-host.sh"
  fi
  if [ -d "$B/relay" ]; then
    run "$p" "haproxy -c relay config" docker run --rm -v "$ROOT/$B/relay:/r:ro" "$HAPROXY_IMAGE" haproxy -c -f /r/haproxy.cfg
    run "$p" "nft -c relay firewall" docker run --rm --cap-add NET_ADMIN -v "$ROOT/$B/relay:/r:ro" "$LAB" nft -c -f /r/nftables-relay.conf
    run "$p" "wg-quick strip relay tunnels" docker run --rm -v "$ROOT/$B/relay:/r:ro" "$LAB" bash -c \
      'for f in wgrelay-relay wgrelay-home; do cp /r/$f.conf /tmp/wgrelay.conf && wg-quick strip /tmp/wgrelay.conf >/dev/null || exit 1; done'
  fi
  run "$p" "actionlint forgejo-deploy.yml" docker run --rm -v "$ROOT/$B/ci:/c:ro" -v "$ROOT/tests/actionlint.yaml:/cfg.yaml:ro" \
    rhysd/actionlint:1.7.12 -config-file /cfg.yaml -shellcheck= /c/forgejo-deploy.yml
done
run all "shellcheck bin/ship up/down/detect" docker run --rm -v "$ROOT:/p:ro" -w /p koalaman/shellcheck:v0.11.0 -S error \
  bin/ship up.sh down.sh bin/detect-host.sh tests/validate.sh
rm -rf "$SAMPLE_SITES"
printf '%-20s %-34s %s\n' PROFILE CHECK RESULT
printf '%s' "$rows"
echo "failures: $fails"
[ "$fails" -eq 0 ]
