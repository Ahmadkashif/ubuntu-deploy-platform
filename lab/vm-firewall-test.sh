#!/usr/bin/env bash
# Real-host firewall test (Ubuntu 26.04 VM "edge" with the rendered host kit; probes from VM "client" over the lab LAN).
#   lab/vm-firewall-test.sh            -> uses whatever Docker firewall backend the edge currently runs
# Checks: (A) with host_fw removed, an accidental 0.0.0.0 publish is world-reachable (the trap);
#         (B) with host_fw loaded it is dropped while the edge 80/443 stays reachable; a default `-p` (no IP) binds
#             127.0.0.1 because of daemon.json "ip"; (C) DOCKER-ISOLATION: two ordinary user bridges cannot talk;
#         (D) IPv6 to the edge.
set -uo pipefail
V="$(dirname "$0")/vmlab/vm"; E=198.51.100.20; E6=2001:db8:5::20
probe() { "$V" client "for p in 80 443 8081 8082; do printf ':%s=' \$p; if [ \$p = 443 ]; then curl -sk -o /dev/null -w '%{http_code}' --max-time 4 --resolve astro.ship.test:443:$E https://astro.ship.test/ || true; else curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://$E:\$p/ || true; fi; printf ' '; done; echo"; }
echo "=== real-host firewall test $(date -u +%FT%TZ)"
"$V" edge 'echo "edge: $(. /etc/os-release; echo $PRETTY_NAME), docker $(docker version -f {{.Server.Version}}), firewall-backend=$(docker info -f {{.FirewallBackend.Driver}})"'
"$V" edge 'docker rm -f fw8081 fw8082 isoA isoB >/dev/null 2>&1; docker network rm isonetA isonetB >/dev/null 2>&1
  mkdir -p /tmp/w && echo accidental > /tmp/w/index.html
  docker run -d --name fw8081 -p 0.0.0.0:8081:80 -v /tmp/w:/w:ro busybox:1.37.0 httpd -f -p 80 -h /w >/dev/null
  docker run -d --name fw8082 -p 8082:80          -v /tmp/w:/w:ro busybox:1.37.0 httpd -f -p 80 -h /w >/dev/null
  sleep 1; docker ps --format "{{.Names}} {{.Ports}}" | grep fw80'
echo "--- (A) host_fw REMOVED (nft delete table inet host_fw) — the trap"
"$V" edge 'sudo nft delete table inet host_fw'
echo "A $(probe)"
echo "--- (B) host_fw LOADED (nft -f /etc/nftables.conf)"
"$V" edge 'sudo nft -f /etc/nftables.conf && sudo nft list chain inet host_fw forward | grep -E "policy|proto-dst .* accept"'
echo "B $(probe)"
echo "expect: A :80=308 :443=200 :8081=200 :8082=000 | B :80=308 :443=200 :8081=000 :8082=000"
echo "--- (C) DOCKER-ISOLATION between two ordinary (non-internal) user bridges"
"$V" edge 'docker network create isonetA >/dev/null; docker network create isonetB >/dev/null
  docker run -d --name isoB --network isonetB -v /tmp/w:/w:ro busybox:1.37.0 httpd -f -p 80 -h /w >/dev/null; sleep 1
  B=$(docker inspect isoB -f "{{(index .NetworkSettings.Networks \"isonetB\").IPAddress}}")
  docker run --rm --name isoA --network isonetA busybox:1.37.0 sh -c "wget -q -T 3 -O- http://$B/ >/dev/null 2>&1 && echo \"isonetA -> isonetB ($B): REACHABLE (isolation BROKEN)\" || echo \"isonetA -> isonetB ($B): blocked (isolation enforced)\""
  docker run --rm --network isonetB busybox:1.37.0 sh -c "wget -q -T 3 -O- http://$B/ >/dev/null && echo \"same-bridge control isonetB -> isoB: reachable\""
  docker rm -f fw8081 fw8082 isoB >/dev/null; docker network rm isonetA isonetB >/dev/null'
echo "--- (D) IPv6 from the client to the edge [$E6]:443"
"$V" client "ping -6 -c1 -W2 $E6 >/dev/null && echo 'v6 ping ok'; curl -sk -o /dev/null -w 'v6 https -> %{http_code}\n' --max-time 4 --resolve astro.ship.test:443:[$E6] https://astro.ship.test/ || echo 'v6 https -> 000 (not reachable)'"
echo "--- (E) client IP as seen by Caddy (userland-proxy off => no rewrite to the bridge gateway)"
"$V" client "curl -sk -o /dev/null --resolve astro.ship.test:443:$E -A fwtest-v4 https://astro.ship.test/?ipcheck=v4; curl -sk -o /dev/null --resolve astro.ship.test:443:[$E6] -A fwtest-v6 https://astro.ship.test/?ipcheck=v6"
sleep 1
"$V" edge "docker run --rm -v shipedge_caddy_logs:/l:ro busybox:1.37.0 cat /l/access.log | grep ipcheck | tail -2 | python3 -c 'import sys,json; [print(\"  uri=%s remote_ip=%s client_ip=%s\" % (d[\"request\"][\"uri\"], d[\"request\"][\"remote_ip\"], d[\"request\"].get(\"client_ip\"))) for d in map(json.loads, sys.stdin)]'"
