#!/usr/bin/env bash
# Behavioural defence check: a single source that probes for sensitive files / uses scanner user-agents should be
# detected by CrowdSec and banned, after which the Caddy bouncer serves it 403 on any path. Local stack only.
#   tests/crowdsec-ban.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EDGE_IP="$(edge_ip)"
# a fresh attacker address per run: an earlier run's 4h ban (or CrowdSec's post-overflow blackhole) must not mask the result
active="$(docker exec "$CROWDSEC_CONTAINER" cscli decisions list -o raw 2>/dev/null)"
for _ in $(seq 1 50); do ATTACKER=203.0.113.$((100 + RANDOM % 90)); grep -q "Ip:$ATTACKER," <<<"$active" || break; done
HOST="$TEST_HOST"

echo "== baseline: attacker $ATTACKER can reach the site"
before="$(docker run --rm --network "$PUBLIC_NETWORK" --ip "$ATTACKER" "$LAB" \
  curl -sk -o /dev/null -w "%{http_code}" --resolve "$HOST:$HTTPS_PORT:$EDGE_IP" "https://$HOST:$HTTPS_PORT/")"
echo "  before: $before"

echo "== $ATTACKER probes sensitive paths + uses a scanner user-agent (generates CrowdSec signals)"
docker run --rm -i --network "$PUBLIC_NETWORK" --ip "$ATTACKER" -e EDGE_IP="$EDGE_IP" -e PORT="$HTTPS_PORT" -e HOST="$HOST" \
  "$LAB" bash -s <<'SH'
req(){ curl -sk -o /dev/null -w "%{http_code} " --max-time 4 --resolve "$HOST:$PORT:$EDGE_IP" "$@"; }
# sensitive-file probing (http-probing / http-sensitive-files scenarios)
for p in /.env /.git/config /.git/HEAD /wp-login.php /wp-admin/ /phpmyadmin/ /admin /config.php.bak /backup.sql \
         /.aws/credentials /server-status /.svn/entries /vendor/phpunit /solr/ /actuator/health /_ignition/execute-solution; do
  req "https://$HOST:$PORT$p"
done
echo
# scanner user-agents (http-bad-user-agent scenario)
for ua in "Nikto/2.1.6" "sqlmap/1.8" "() { :;}; test" "masscan/1.3" "Nmap Scripting Engine"; do
  req -A "$ua" "https://$HOST:$PORT/"
done
echo
SH

echo "== wait for CrowdSec to parse the logs and decide (bouncer ticker ${SHIP_TICKER:-a few}s)"
banned=""
for i in $(seq 1 24); do
  d="$(docker exec "$CROWDSEC_CONTAINER" cscli decisions list -o json 2>/dev/null)"
  # here-string, not `printf | grep -q`: grep -q exits early, printf gets SIGPIPE and pipefail turns that into "false"
  if grep -q "$ATTACKER" <<<"$d"; then banned=yes; break; fi
  sleep 2
done
echo "-- cscli decisions list:"; docker exec "$CROWDSEC_CONTAINER" cscli decisions list 2>/dev/null | sed 's/^/   /'
echo "-- cscli alerts for $ATTACKER:"; docker exec "$CROWDSEC_CONTAINER" cscli alerts list -o json 2>/dev/null | tr ',' '\n' | grep -iE "scenario|value.*$ATTACKER|events_count" | sed 's/^/   /' | head -8

echo "== after detection: is $ATTACKER now blocked by the bouncer? (expect 403)"
sleep 3
after="$(docker run --rm --network "$PUBLIC_NETWORK" --ip "$ATTACKER" "$LAB" \
  curl -sk -o /dev/null -w "%{http_code}" --resolve "$HOST:$HTTPS_PORT:$EDGE_IP" "https://$HOST:$HTTPS_PORT/")"
echo "  after: $after"
echo "== a DIFFERENT source (203.0.113.201) is unaffected (expect 200):"
docker run --rm --network "$PUBLIC_NETWORK" --ip 203.0.113.201 "$LAB" \
  curl -sk -o /dev/null -w "  clean client: %{http_code}\n" --resolve "$HOST:$HTTPS_PORT:$EDGE_IP" "https://$HOST:$HTTPS_PORT/"
[ "$before" = 200 ] && [ "$banned" = yes ] && [ "$after" = 403 ] && { echo "PASS: scanner detected, banned, and blocked by the bouncer"; exit 0; }
echo "RESULT: banned=$banned after=$after (see notes)"; exit 1
