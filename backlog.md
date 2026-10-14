# Backlog — deferred ideas (not built; keep the PoC small)

## Security hardening
- **CSP nonce/strict-dynamic middleware for SSR** so Next.js drops `script-src 'unsafe-inline'`. A small Go/Caddy
  handler (or Next middleware) that injects a per-request nonce and rewrites the CSP.
- **CRS PL2 (or targeted RCE rule)** to catch ultra-short command tokens (`;id`) that PL1 misses. Needs a fresh
  false-positive pass per app before enabling.
- **cs-firewall-bouncer (nftables)** to drop banned IPs at L3 (cheaper than an HTTP 403 under flood) in addition to the
  Caddy bouncer's L7 block.
- **Anubis (PoW)** in front of specific apps when AI-scraper volume becomes a cost problem.
- **CrowdSec 1.8 bot-detection/challenge** once the Caddy bouncer supports it (today: nginx/HAProxy/Traefik/Envoy only).
- **Suricata** NIDS on a bigger host; **Lynis**/USG scheduled audits with a score gate.
- **Track static-web-server advisories via Renovate** (grype/syft see 0 packages in its static binary — the scan gate
  is blind to SWS itself).
- **cosign keyless / Rekor** if the platform ever goes multi-tenant and a transparency log is wanted (needs internet).
- **mTLS or Caddy `forward_auth`** on the admin plane in addition to WireGuard, for shared-admin setups.

## Deploy engine / workflow
- **Preview environments** (`<branch>.<app>.<domain>`) — same `ship` flow with a per-branch service name/host, torn
  down on branch delete.
- **Railpack** ("no Dockerfile" builds) as an optional `ship build` path for apps without a Dockerfile.
- **Accessories** (Postgres/Redis/queues) as first-class `ship` resources (today: run via compose/Kamal accessories).
- **Multi-host** via full Kamal 2 (SSH) once a second host exists — the swap is documented; `ship`'s per-app manifest
  maps onto a Kamal `deploy.yml`.
- **Pull-based CD** (Komodo/Flux) so no runner ever holds prod credentials (relevant once there's more than one host).
- **`ship` in a real language** (Go) if it outgrows bash — keep the same CLI contract.

## Exposure
- **Headscale/NetBird** as the managed admin tunnel (beyond ~3 WireGuard peers), with ACLs restricting the deploy lane.
- **frp** as the relay swap where WireGuard is inconvenient; **Pangolin CE** if a dashboard is wanted (accept the extra
  public control plane).
- **DNS-01 ACME** (needs a DNS-provider Caddy module + API token) as an alternative to HTTP-01/TLS-ALPN behind the relay.
- **IPv6 end-to-end through the relay** (the relay config binds v6; verify client-IP preservation on v6).

## Observability / ops
- Wire Caddy JSON logs + CrowdSec metrics + an OTel `docker_stats` agent into ClickStack (the observability-factory
  stack) — hooks noted, not built.
- **Backups**: scheduled dumps of `registry_data`, `crowdsec_*` volumes and `state/`; a restore test.
- **`ship gc`** to prune old images/releases in the local registry (keep last N per app).
- **Alerting** on unexpected CrowdSec bans, cert-renewal failures, or a deploy that auto-rolled back.

## Verification (do on real hardware later)
- Run a real `ubuntu-vps-small` on a public IP: measure idle RAM, ACME issuance, the firewall against a real scan, and
  a real zero-downtime redeploy under load.
- Run the NAT-relay end to end (relay VPS + home host) and confirm client-IP + ACME through the live tunnel.
- go-ftw CRS regression suite against the edge for a rigorous WAF false-positive/true-positive baseline per app.

---

## Added 2026-10-14 (Ubuntu round): found on real Linux, deliberately not built

### Operations
- **`ship gc` is now urgent, not optional.** After ~10 deploys on the 26.04 VM the build cache was 4.5 GB, volumes 3.3 GB (mostly
  the grype DB), and images 2.9 GB, about 13 GB in total. On a 20 GB `ubuntu-vps-small` disk fills before RAM does. Prune old
  releases/images and the build cache, keeping the last N.
- **Self-heal after a Docker firewall-backend change.** Changing `firewall-backend` with live-restored containers broke Docker's
  embedded DNS (all apps 500) until another dockerd restart. The README now documents the safe order. A `ship doctor` check
  (resolve `kamal-proxy`/`crowdsec` from inside the edge) could detect it automatically.
- **Stale iptables tables** remain after switching Docker to the nftables backend: clean them up or document the expected output.
- **Health path exposure**: health paths are reachable through the edge. Optionally block `HEALTH_PATH` at Caddy for external
  clients (kamal-proxy probes the container directly, so the gate would not need it).
- **Loopback profiles' HTTP→HTTPS redirect drops a non-standard HTTPS port** (`http://x:19080/` → `https://x/`). Harmless on
  80/443 profiles; for verify profiles, add an explicit redirect site carrying `{{exposure.https_port}}`.

### Supply chain
- **Scan the lockfile of static apps** (syft/grype see 0 packages in scratch static-web-server images, so an SPA's npm deps are
  never scanned): run `grype` on the app dir / `package-lock.json` in the deploy step or CI.
- **Base-image drift**: on 2026-10-14 `joseluisq/static-web-server:2.44.1-alpine` failed the gate (2 critical OpenSSL CVEs) while
  the scratch tag passed. Add a Renovate rule or a weekly re-scan of running digests.

### Relay / exposure
- **Optional strict PROXY mode**: today a non-relay connection *without* a PROXY header is served (only headers from non-relay peers
  are refused); host_fw is the boundary, and was verified to drop it. Belt and braces: `fallback_policy require`, with ship's smoke
  test going through the relay (needs a `relay.public_ip` profile key, which would also fill the `Endpoint` placeholder).
- **Relay HAProxy health check** currently plain TCP. Consider `check-send-proxy` + an HTTP check against `/healthz` for real health.

### Verification still open
- **ACME through the relay / on a public IP** (HTTP-01 / TLS-ALPN-01): needs a real domain + public IP, out of scope this round.
- **go-ftw CRS regression baseline per app** and a **PL2 false-positive pass**: not run this round (time); still the right next WAF step.
- **Volumetric L3/L4** stays an upstream (provider) concern.
