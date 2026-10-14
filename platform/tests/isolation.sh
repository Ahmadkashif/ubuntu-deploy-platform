#!/usr/bin/env bash
# Network isolation check (verify profile): from a client on the "public" network, which of our own services can be
# reached? Expected: only the edge's HTTP/HTTPS ports; the admin plane (registry, CrowdSec LAPI/AppSec, kamal-proxy,
# Caddy admin API, app containers) is unreachable. Also lists what this machine exposes on its own interfaces.
#   tests/isolation.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ip_of() { docker inspect "$1" --format '{{range $n, $e := .NetworkSettings.Networks}}{{$n}}={{$e.IPAddress}} {{end}}'; }
EDGE_PUB="$(docker inspect "$CADDY_CONTAINER" --format "{{(index .NetworkSettings.Networks \"$PUBLIC_NETWORK\").IPAddress}}")"
targets="edge-public:$EDGE_PUB:22,2019,2080,5000,8080,$HTTP_PORT,$HTTPS_PORT"
for c in "$CADDY_CONTAINER" "$CROWDSEC_CONTAINER" "$PROXY_CONTAINER" "${EDGE_PROJECT}-registry" $(docker ps --filter label=ship.managed=true --format '{{.Names}}'); do
  for pair in $(ip_of "$c"); do
    net="${pair%%=*}"; ip="${pair#*=}"; [ "$net" = "$PUBLIC_NETWORK" ] && continue
    case "$c" in *crowdsec) ports=8080,7422,6060;; *kamal-proxy) ports=80;; *registry) ports=5000;; *caddy) ports=2019,2080,$HTTPS_PORT;; *) ports=80,3000,8080;; esac
    targets="$targets $c@$net:$ip:$ports"
  done
done
echo "== from a client on $PUBLIC_NETWORK (the simulated internet)"
docker run --rm --network "$PUBLIC_NETWORK" -e T="$targets" -e WEB="$HTTP_PORT $HTTPS_PORT" -e P="$EDGE_PROJECT" "$LAB" bash -c '
  bad=0
  for t in $T; do
    name="${t%%:*}"; rest="${t#*:}"; ip="${rest%%:*}"; ports="${rest#*:}"
    for p in ${ports//,/ }; do
      if nc -z -w 2 "$ip" "$p" 2>/dev/null; then st=OPEN; else st=closed; fi
      echo "  $name $ip:$p $st"
      case "$name:$st" in edge-public:OPEN) case " $WEB " in *" $p "*) ;; *) bad=1;; esac;; *:OPEN) bad=1;; esac
    done
  done
  for n in registry crowdsec kamal-proxy $P-registry $P-crowdsec $P-kamal-proxy; do
    getent hosts "$n" >/dev/null && { echo "  DNS $n resolves (BAD)"; bad=1; } || echo "  DNS $n: not resolvable"
  done
  exit $bad'
rc=$?
echo "== listeners on this machine belonging to Docker (host side)"
if command -v lsof >/dev/null; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR==1 || /com.docke|dockerd|docker-pr/ {print $1, $9}' | sort -u
else ss -ltnp 2>/dev/null | grep -E "docker|containerd" ; fi
[ $rc -eq 0 ] && echo "PASS: only the edge web ports are reachable from the public network" || echo "FAIL"
exit $rc
