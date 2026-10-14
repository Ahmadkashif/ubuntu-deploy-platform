#!/usr/bin/env bash
# NAT relay end to end on real VMs (profile ubuntu-nat-verify):
#   client 198.51.100.50 / 2001:db8:5::50 --> relay 198.51.100.30 / ::30 (HAProxy 3.2 mode tcp, send-proxy-v2)
#   --> WireGuard wgrelay 10.77.0.1 -> 10.77.0.2 --> home host_fw (80/443 only from 10.77.0.1 on wgrelay)
#   --> Docker DNAT --> Caddy proxy_protocol (allow 10.77.0.1) --> CrowdSec/WAF --> kamal-proxy --> app
set -uo pipefail
V="$(dirname "$0")/vmlab/vm"; H=astro.ship.test; R4=198.51.100.30; R6=2001:db8:5::30; E4=198.51.100.20
"$V" edge 'cat ~/platform/secrets/edge-ca.crt' | "$V" client 'cat > ~/edge-ca.crt'
logip() { sleep 1; "$V" edge "docker run --rm -v shipedge_caddy_logs:/l:ro busybox:1.37.0 cat /l/access.log | grep '$1' | tail -1 | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(\"    caddy saw remote_ip=%s client_ip=%s status=%s\" % (d[\"request\"][\"remote_ip\"], d[\"request\"].get(\"client_ip\"), d[\"status\"]))'"; }
echo "=== relay end to end $(date -u +%FT%TZ)"
"$V" edge 'docker exec shipedge-crowdsec cscli decisions delete --ip 198.51.100.50 >/dev/null 2>&1; true'; sleep 10   # clean slate for re-runs (bouncer ticker)
"$V" edge 'sudo wg show wgrelay | grep -E "endpoint|handshake|transfer" | sed "s/^/  home wgrelay /"'
echo "--- 1) client -> relay over IPv4"
"$V" client "curl -s --cacert edge-ca.crt --resolve $H:443:$R4 -o /dev/null -w '  https via relay v4 -> %{http_code} (TLS verified against the home CA: TLS terminates at home)\n' 'https://$H/?relaycheck=v4'"
logip relaycheck=v4
echo "--- 2) client -> relay over IPv6"
"$V" client "curl -s --cacert edge-ca.crt --resolve '$H:443:[$R6]' -o /dev/null -w '  https via relay v6 -> %{http_code}\n' 'https://$H/?relaycheck=v6'"
logip relaycheck=v6
echo "--- 3) http :80 via relay (redirect)"
"$V" client "curl -s -o /dev/null -w '  http via relay -> %{http_code} %{redirect_url}\n' --resolve $H:80:$R4 http://$H/"
echo "--- 4) client -> home host DIRECTLY (must be dropped by host_fw: only the relay's tunnel IP may reach 80/443)"
"$V" client "curl -sk -o /dev/null -w '  direct https home v4 -> %{http_code}\n' --max-time 4 --resolve $H:443:$E4 https://$H/ || true; curl -sk -o /dev/null -w '  direct https home v6 -> %{http_code}\n' --max-time 4 --resolve '$H:443:[2001:db8:5::20]' https://$H/ || true"
echo "--- 5) forged PROXY header sent directly to the home host (blocked at L3 before Caddy even sees it)"
"$V" client "printf 'PROXY TCP4 1.2.3.4 9.9.9.9 1111 443\r\nGET / HTTP/1.1\r\nHost: $H\r\n\r\n' | timeout 5 nc -w4 $E4 443 | head -1 | sed 's/^/  /' ; echo '  (no answer = dropped)'"
echo "--- 6) relay admin surface from the internet: SSH to the relay public IP"
"$V" client "nc -z -w3 $R4 22 && echo '  relay :22 OPEN (BAD)' || echo '  relay :22 blocked (SSH only from home via wgrelay)'"
SCN=198.51.100.$((70 + RANDOM % 30))   # fresh scanner address per run (CrowdSec blackholes a bucket for a while after it overflows)
echo "--- 7) CrowdSec through the relay: a scanner at $SCN gets banned by its REAL address; another client (.51) is unaffected"
"$V" client "sudo ip addr add $SCN/24 dev eth0 2>/dev/null; sudo ip addr add 198.51.100.51/24 dev eth0 2>/dev/null; for p in /.env /.git/config /wp-login.php /phpmyadmin/ /.aws/credentials /server-status /backup.sql; do curl -s --interface $SCN --cacert edge-ca.crt --resolve $H:443:$R4 -o /dev/null -w '%{http_code} ' https://$H\$p; done; for ua in 'Nikto/2.1.6' 'sqlmap/1.8' 'masscan/1.3'; do curl -s --interface $SCN --cacert edge-ca.crt --resolve $H:443:$R4 -A \"\$ua\" -o /dev/null -w '%{http_code} ' https://$H/; done; echo"
for i in $(seq 1 20); do "$V" edge 'docker exec shipedge-crowdsec cscli decisions list -o raw 2>/dev/null' | grep -q "$SCN," && break; sleep 3; done
"$V" edge "docker exec shipedge-crowdsec cscli decisions list -o raw 2>/dev/null | grep -E '^id|$SCN,' | sed 's/^/  /'"
sleep 7
"$V" client "curl -s --interface $SCN --cacert edge-ca.crt --resolve $H:443:$R4 -o /dev/null -w '  banned $SCN via relay -> %{http_code}\n' https://$H/; curl -s --interface 198.51.100.51 --cacert edge-ca.crt --resolve $H:443:$R4 -o /dev/null -w '  clean 198.51.100.51 via relay -> %{http_code}\n' https://$H/"
echo "--- 8) Caddy proxy_protocol layer itself (inside the home host, from the simulated public Docker net 203.0.113.0/24)"
"$V" edge "docker run --rm -i --network shipedge_public -e H=$H -e E=\$(docker inspect shipedge-caddy -f '{{(index .NetworkSettings.Networks \"shipedge_public\").IPAddress}}') ship-fwlab:24.04 bash -s" <<'SH'
r=$(printf 'PROXY TCP4 1.2.3.4 9.9.9.9 1111 80\r\nGET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$H" | timeout 5 nc -w4 "$E" 80 | head -1)
echo "  forged PROXY header from non-relay 203.0.113.x on :80 -> ${r:-<connection closed, no response = rejected>}"
curl -sk -o /dev/null -w '  no header from non-relay -> %{http_code} (served with its own address: fallback_policy reject only refuses HEADERS from non-relay peers; host_fw keeps non-relay sources out, see 4)\n' --resolve "$H:443:$E" "https://$H/"
SH
echo "--- 9) the brand-new clean-room frontend through the relay"
"$V" client "curl -s --interface 198.51.100.51 --cacert edge-ca.crt --resolve vuefresh.ship.test:443:$R4 -o /dev/null -w '  vuefresh via relay v4 (source .51) -> %{http_code}\n' https://vuefresh.ship.test/about; curl -s --cacert edge-ca.crt --resolve 'vuefresh.ship.test:443:[$R6]' -o /dev/null -w '  vuefresh via relay v6 -> %{http_code}\n' https://vuefresh.ship.test/"
