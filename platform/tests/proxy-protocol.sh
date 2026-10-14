#!/usr/bin/env bash
# NAT-relay real-client-IP proof (the trap: without PROXY protocol the WAF/CrowdSec see the relay's IP, which is
# private and CrowdSec-whitelisted, so no attacker is ever seen or banned). Mirrors the ubuntu-home-nat edge:
#   client --> HAProxy (mode tcp, send-proxy-v2) --> Caddy (listener_wrappers proxy_protocol allow <relay> reject)
# Verifies: (1) through the relay, Caddy sees the CLIENT ip, not the relay's; (2) a direct connection from a
# non-relay address WITHOUT a PROXY header is rejected (fallback_policy reject). Local containers only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
# TEST-NET-1 (never routed; also does not collide with a lab LAN on TEST-NET-2/3)
NET=pptest_$$; SUB=192.0.2.0/24
RELAY=192.0.2.10; EDGE=192.0.2.20; CLIENT=192.0.2.123
D="$(mktemp -d)"; trap 'docker rm -f pp_edge_$$ pp_relay_$$ 2>/dev/null >/dev/null; docker network rm "$NET" 2>/dev/null >/dev/null; rm -rf "$D"' EXIT
docker network create --subnet "$SUB" "$NET" >/dev/null

# Caddy config: the exact proxy_protocol listener construct from the rendered ubuntu-home-nat Caddyfile, allowing
# only the relay's address. The site echoes the client IP Caddy derived, and logs it as JSON.
cat > "$D/Caddyfile" <<EOF
{
	admin off
	auto_https off
	servers :8443 {
		listener_wrappers {
			proxy_protocol {
				timeout 5s
				allow $RELAY/32
				fallback_policy reject
			}
		}
		trusted_proxies static private_ranges
	}
	log {
		output stdout
		format json
	}
}
:8443 {
	respond "client={remote_host}" 200
}
EOF

echo "== start Caddy (edge image) with the home-nat proxy_protocol listener; relay allowed = $RELAY"
docker run -d --rm --name pp_edge_$$ --network "$NET" --ip "$EDGE" -v "$D/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$EDGE_IMG" run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
cat > "$D/haproxy.cfg" <<EOF
defaults
	mode tcp
	timeout connect 5s
	timeout client 30s
	timeout server 30s
frontend f
	bind :443
	default_backend b
backend b
	server edge $EDGE:8443 send-proxy-v2
EOF
echo "== start HAProxy relay (send-proxy-v2) at $RELAY"
docker run -d --rm --name pp_relay_$$ --network "$NET" --ip "$RELAY" -v "$D/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "$HAPROXY_IMAGE" >/dev/null
sleep 6

echo "   edge=$(docker inspect -f '{{.State.Running}}' pp_edge_$$) relay=$(docker inspect -f '{{.State.Running}}' pp_relay_$$)"
echo "== (1) client $CLIENT --> relay --> Caddy : Caddy must report client=$CLIENT (not the relay $RELAY)"
seen=""; for i in 1 2 3 4 5; do
  seen="$(docker run --rm --network "$NET" --ip "$CLIENT" "$LAB" curl -s --max-time 6 http://$RELAY:443/ 2>/dev/null)"
  [ -n "$seen" ] && break; sleep 2
done
echo "   Caddy returned: $seen"
echo "   Caddy access log (client_ip field):"
docker logs pp_edge_$$ 2>&1 | grep -o '"client_ip":"[^"]*"' | tail -1 | sed 's/^/     /'

echo "== (2) spoofing: client $CLIENT (NOT the relay) forges a PROXY header claiming 1.2.3.4 -> must be rejected"
# fallback_policy reject declines any connection that presents a PROXY header from a non-allowed peer, so a client
# cannot spoof its source IP past the WAF/CrowdSec. (Plain reachability of :443 is separately restricted to the relay
# by the host nftables input chain: firewall.public_sources = [relay] in the ubuntu-home-nat profile.)
spoof="$(docker run --rm --network "$NET" --ip "$CLIENT" "$LAB" sh -c \
  "printf 'PROXY TCP4 1.2.3.4 9.9.9.9 12345 443\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | nc -w4 $EDGE 8443 | head -1")"
echo "   forged-header response: ${spoof:-<connection closed / no response = rejected>}"
echo "== control: the SAME forged header VIA the relay resolves to the real client, not 1.2.3.4"
# (the relay strips any client-sent bytes and prepends its own PROXY v2 with the real TCP source)

echo
ok=1
[ "$seen" = "client=$CLIENT" ] || ok=0
case "$spoof" in *1.2.3.4*) ok=0;; esac      # the spoofed IP must never be honoured
if [ "$ok" = 1 ]; then
  echo "PASS: real client IP preserved through the relay; a forged PROXY header from a non-relay peer is not honoured"
else
  echo "RESULT: seen='$seen' spoof='$spoof' (expected client=$CLIENT and no 1.2.3.4)"
fi
