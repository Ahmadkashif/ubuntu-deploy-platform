#!/usr/bin/env bash
# Host-firewall behaviour test with a REAL Docker daemon (the "Docker bypasses the host firewall" trap).
# A privileged Ubuntu 24.04 container ("host") runs its own dockerd and two apps: one published on 80 (a web port)
# and one accidentally published on 8081 (must NOT be public). A separate client container reaches the host's IP.
#   phase A: no host firewall  -> both 80 and 8081 reachable  (the trap: `docker run -p 8081` is world-open)
#   phase B: load rendered inet host_fw -> 80 reachable, 8081 dropped by the forward chain
# Everything runs on a throwaway Docker network on THIS machine; the Mac's own firewall is never touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET=fwtest_$$; LAB=ship-fwlab:24.04
NFT="$ROOT/build/ubuntu-vps-small/host/nftables.conf"
[ -f "$NFT" ] || { echo "render ubuntu-vps-small first"; exit 2; }
docker image inspect "$LAB" >/dev/null 2>&1 || docker build -q -t "$LAB" "$ROOT/tests/fwlab" >/dev/null
cleanup(){ docker rm -f fwhost_$$ 2>/dev/null >/dev/null; docker network rm "$NET" 2>/dev/null >/dev/null; }
trap cleanup EXIT
docker network create "$NET" >/dev/null

echo "== start the 'host' (privileged, its own dockerd, uplink iface eth0)"
docker run -d --rm --privileged --name fwhost_$$ --network "$NET" "$LAB" sh -c 'dockerd --storage-driver vfs --iptables=true >/var/log/dockerd.log 2>&1 & sleep 8; tail -f /dev/null' >/dev/null
HOST_IP="$(docker inspect fwhost_$$ --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")"
for i in $(seq 1 20); do docker exec fwhost_$$ docker info >/dev/null 2>&1 && break; sleep 1; done
docker exec fwhost_$$ docker info >/dev/null 2>&1 || { echo "nested dockerd did not start"; docker exec fwhost_$$ tail -20 /var/log/dockerd.log; exit 1; }
echo "   nested dockerd up on host $HOST_IP; loading a tiny web image into it"
docker save busybox:1.37.0 | docker exec -i fwhost_$$ docker load >/dev/null
docker exec fwhost_$$ sh -c '
  mkdir -p /w80 /w8081; echo web-port-80 > /w80/index.html; echo accidental-8081 > /w8081/index.html
  docker run -d -p 80:80   -v /w80:/w:ro   busybox:1.37.0 httpd -f -p 80 -h /w   >/dev/null
  docker run -d -p 8081:80 -v /w8081:/w:ro busybox:1.37.0 httpd -f -p 80 -h /w   >/dev/null
  sleep 2'

probe(){ docker run --rm --network "$NET" "$LAB" sh -c "echo -n \"$1 :80=\"; curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://$HOST_IP:80/ || echo 000; echo -n ' :8081='; curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://$HOST_IP:8081/ || echo 000; echo"; }

echo "== phase A — no host firewall (the trap)"
probe "A"

echo "== phase B — load the rendered nftables ruleset (table inet host_fw)"
docker cp "$NFT" fwhost_$$:/etc/nftables.conf
docker exec fwhost_$$ sh -c 'nft -f /etc/nftables.conf && echo "   host_fw loaded" && nft list chain inet host_fw forward | grep -E "proto-dst|policy|dnat" | sed "s/^/     /"'
probe "B"

echo
echo "Expected: A :80=200 :8081=200 (both open — bypass) ; B :80=200 :8081=000 (accidental port now dropped)"
