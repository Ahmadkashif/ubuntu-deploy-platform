# ship — a small, open-source deploy platform for frontends behind a strong edge

`ship` deploys any app that ships a **Dockerfile exposing one HTTP port with a health path** — build → scan → SBOM →
sign → push by digest → run hardened → **health-gated** cutover → smoke → keep the previous release for instant
rollback. In front sits one edge: **Caddy (auto-HTTPS) → CrowdSec bouncer + AppSec → per-IP rate limit → AI-scraper
block → Coraza WAF with OWASP CRS → kamal-proxy** (Basecamp's Kamal 2 proxy) routing to your app containers. The
admin plane (registry, CrowdSec, kamal-proxy control, Caddy admin) is never public.

Everything is OSI-licensed. Nothing is exposed until you run the go-public steps yourself.

- **What runs where and why:** `../findings.md`. **Deferred ideas:** `../backlog.md`.
- **Profiles** (host templates): `ubuntu-vps-small`, `ubuntu-home-public`, `ubuntu-home-nat` (production shapes),
  `ubuntu-lan-verify`, `ubuntu-nat-verify` (same kit, local CA, no domain), `linux-docker-verify`, `mac-docker-verify`
  (loopback-only try-outs that never touch the host).
- Verified on Linux 2026-10-14: real Ubuntu 26.04.1 VMs (host kit, firewall, WireGuard, relay) + Linux Docker 29.
  Evidence: `../proof-linux/`. What is NOT verified: going public (domain/ACME/real internet).

---

## 1. Quickstart (verify profile: loopback only, host untouched)

On **Linux** (any machine with Docker Engine >= 29, even one that already runs other things) use `linux-docker-verify`
(127.0.0.1:**19080** HTTP, **19443** HTTPS, **15055** registry, compose project `shipverify`). On a **Mac** with Docker
Desktop use `mac-docker-verify` (127.0.0.1:9080/9443/5055). Neither renders or applies any host change.

```bash
cd platform
./up.sh linux-docker-verify      # or mac-docker-verify; builds the edge image, generates secrets, starts the edge
bin/ship deploy examples/astro-static
```
Then, trusting the local CA that `up.sh` exported to `secrets/edge-ca.crt`:
```bash
curl --cacert secrets/edge-ca.crt --resolve astro.localhost:9443:127.0.0.1 https://astro.localhost:9443/
```
(on linux-docker-verify use port 19443.) `bin/ship status` lists routes and releases. `./down.sh` stops everything (keeps volumes); `./up.sh` resumes.
Add `astro.localhost` etc. to `/etc/hosts` as `127.0.0.1` to use a browser (import `secrets/edge-ca.crt` to trust TLS).

Apps become `<name>.<exposure.domain>`: `<name>.localhost` on the two loopback profiles, `<name>.ship.test` on
`ubuntu-lan-verify`/`ubuntu-nat-verify`, your domain on the production profiles. Run `./up.sh` and `bin/ship` as a normal
user in the `docker` group (on a fresh host `install-host.sh` adds the user who ran it with sudo).

---

## 2. Deploy your own app (the contract)

Put two files in your app directory:

**`Dockerfile`** — build your app, run it as **non-root** on one port, expose a **health path** that returns 200.
Prefer a static file server for SPA/SSG, or a standalone server for SSR. Copy an `examples/` one and adapt. What the
examples rely on, so you can write one without them:
- static sites/SPAs: `joseluisq/static-web-server:<2.44.x>` (the **scratch** variant: as of 2026-10-14 the `-alpine` tag
  fails the scan gate on critical OpenSSL CVEs), files in `/public`, `USER 65534:65534` (any non-root uid), and
  `CMD ["--port","8080","--root","/public","--health"]`. `--health` serves **`/health`**.
- your container must listen on `PORT` itself: ship does **not** inject it. EXPOSE is documentation only.
- SSR (Node): a standalone server, `USER node`, a real health route (see `examples/nextjs-ssr`).

**`ship.env`** — the deploy manifest:
```sh
APP=myapp                 # a-z0-9- , unique
PORT=8080                 # the port your container listens on (apps may share a port: each is its own container)
HEALTH_PATH=/health       # returns 200 when ready (kamal-proxy gates the cutover on this). Must be a REAL endpoint:
                          # with an SPA page fallback EVERY path returns 200, so a typo'd path passes the gate
                          # (measured). Health paths are reachable through the edge like any other path.
HOSTS="myapp"             # bare names get .<profile domain> (myapp.localhost on verify); or a full domain
# optional:
MEMORY=128m               # default from the profile
CPUS=1.0
TMPFS="/app/cache"        # writable paths for a read-only rootfs (e.g. Next.js: /app/.next/cache)
EGRESS=false              # true only if the app must reach the internet (else it has none)
WAF_PROFILE=default       # 'nextjs' also allows Next.js Server Actions (text/plain POST) for these hosts
CSP="default-src 'self'; ..."   # overrides the strict default CSP for these hosts (no double quotes)
SMOKE_PATH=/              # path the post-deploy smoke test fetches
```
Notes on the contract:
- **Version:** a git short-sha if the dir is a git repo, else a UTC timestamp; override with `--version`.
- Your build gets `SHIP_VERSION` as a **Docker build-arg** (declare `ARG SHIP_VERSION` and use it to stamp the build);
  see the example Dockerfiles.
- `npm ci` (used by the examples) needs a committed `package-lock.json` — generate one with
  `npm install --package-lock-only`. Docker builds have network access.
- **The default CSP is strict** (no inline scripts):
  `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:;
  connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'`.
- **Clean URLs:** `static-web-server` serves `/about/` from `about/index.html`. For SSG, prefer `trailingSlash: always`
  (or the framework equivalent) so links resolve; for SPAs use `--page-fallback` (see below).

Then:
```bash
bin/ship deploy /path/to/your/app     # or: bin/ship deploy .   (uses the git short-sha as the version)
bin/ship rollback myapp               # health-gated switch back to the previous release
bin/ship status [myapp]               # routes + current/previous versions
bin/ship remove myapp                 # unroute + remove its containers (images stay in the registry)
bin/ship edge ps|logs caddy|...       # docker compose for the edge stack
```
Notes:
- **Static SPA** (React/Vue): serve the build with `static-web-server --page-fallback /public/index.html` so deep
  links work; see `examples/vite-react-spa`.
- **SSR** (Next.js): `output: "standalone"`, run `node server.js`, set `TMPFS="/app/.next/cache"` and
  `WAF_PROFILE=nextjs`; see `examples/nextjs-ssr`.
- **Static site** (Astro/Hugo/plain): serve the output dir. The strict default CSP **blocks inline `<script>`**, so no
  inline scripts may be emitted. For Astro/Vite set `vite.build.assetsInlineLimit: 0`. **Frameworks whose bootstrap is
  an inline `<script>` (SvelteKit, and some others) cannot be fixed by a build flag** — either add a post-build step
  that moves the inline script into an external `.js` (loaded with `src`), or set a per-app `CSP=` that permits it.
  **Always verify:** `grep -rhoE '<script[^>]*>' dist | grep -v 'src='` must print nothing (inline scripts), and check the page in a browser
  — the deploy smoke test only checks for HTTP 200 and will **not** catch a CSP-blocked script (your page can be "up"
  but dead). `tests/csp-check.sh <host>` runs a real headless browser and reports CSP violations.
- The scan gate fails a deploy on a **critical** vulnerability by default (`security.scan_fail_on` per profile).
  It sees OS packages and what is installed in the image (e.g. Next.js's `node_modules`: on 2026-10-14 it refused
  next 16.3.5, GHSA-vcvr-r3jv-pc5j). For a static site on a scratch image it reports **0 packages**: your npm build
  dependencies are not in the image, so they are not scanned; audit the lockfile in CI.
- If the health gate fails, ship prints kamal-proxy's reason; more with `bin/ship edge logs --tail 50 kamal-proxy`.
  The failed container is removed; the previous release keeps serving.
- `tests/csp-check.sh <host> [path]` loads the page in headless Chromium and reports CSP violations + console errors; it
  also reads the text of `#js-status` and clicks the first `<button>` if your page has them (optional hooks to prove
  JS ran). `tests/fp-crawl.sh <host> [paths...]` fetches each page and every asset it references and fails on any 403.
- Every image is **signed and the signature is verified before the container runs** (cosign, local key in
  `secrets/`, no transparency-log upload).

---

## 3. Which profile?

| Profile | Use when | Exposure | Admin |
|---|---|---|---|
| `ubuntu-vps-small` | a VPS with a public IP | nftables opens 80/443 to anyone; ACME certs | SSH/registry/dashboards over WireGuard |
| `ubuntu-home-public` | a home box with a public IP + router port-forward | same, plus LAN admin | LAN + WireGuard |
| `ubuntu-home-nat` | a home box behind NAT/CGNAT (no inbound) | a small relay VPS forwards 80/443 over WireGuard with PROXY-v2; home firewall admits only the relay | LAN + WireGuard |
| `ubuntu-lan-verify` | an Ubuntu box on a LAN, no public domain | 80/443 on the LAN, local CA (`*.ship.test`); never port-forward it | admin LAN + WireGuard |
| `ubuntu-nat-verify` | trying the NAT relay path without a domain | like `ubuntu-home-nat`, local CA | admin LAN + WireGuard |
| `linux-docker-verify` | trying it out on any Linux Docker 29 host, incl. a shared one | 127.0.0.1:19080/19443 only, no host kit | loopback |
| `mac-docker-verify` | trying it out on a Mac (Docker Desktop) | 127.0.0.1 only | loopback |

Minimum specs per profile live in `profiles/<name>.yaml` (`minimum:`); `bin/detect-host.sh` checks them. Measured on
Ubuntu 26.04 (4 GB VM, edge + 3 apps idle): ~850 MiB used in total; edge containers ~215 MiB, dockerd+containerd
~260 MiB. Disk, not RAM, is the tighter limit on a 20 GB VPS: images + build cache + the grype DB used ~13 GB.

`bin/detect-host.sh` prints host facts and which profiles this machine meets. On Linux it cannot tell whether you
have a public IP or are behind NAT, so pick the `ubuntu-*` profile yourself. It **only ever recommends** a profile that
leaves the host untouched (`./up.sh` without an argument uses the recommendation), and it prints **shared-host signals**
(other containers, a listener on 80/443, an existing daemon.json, Tailscale, active UFW). If any show up, do not run
`install-host.sh` on that machine.

Edit a profile in `profiles/<name>.yaml` (domain, ACME email, LAN subnet, relay addresses, rate limits, whitelist).
`bin/render.py <name>` regenerates `build/<name>/`. `bin/render.py --check-agnostic` proves no verification-host
values leaked into the templates.

---

## 4. Install on Ubuntu (24.04 or 26.04; the install was run on 26.04.1)

The renderer produces a per-profile install script and config under `build/<profile>/host/` (and `.../relay/` for the
NAT profile). **Review them, then run from a console session** (the firewall defaults to deny):

```bash
bin/render.py ubuntu-vps-small           # -> build/ubuntu-vps-small/{host,edge,ci}/...
sudo build/ubuntu-vps-small/host/install-host.sh
# installs Docker (Docker's apt repo), nftables, WireGuard, unattended-upgrades;
# applies sysctl + sshd hardening + the daemon.json ("ip":"127.0.0.1", userland-proxy off);
# generates the host's WireGuard key and prints it; loads the host firewall (table inet host_fw).
```
Then bring the admin tunnel up (add your laptop as a `[Peer]` in `/etc/wireguard/wg0.conf` — replace both
`REPLACE_WITH_*` placeholders — and `systemctl enable --now wg-quick@wg0`), confirm SSH works **over WireGuard**, log in
again (docker group), and:
```bash
./up.sh ubuntu-vps-small
bin/ship deploy /path/to/app
```
The host firewall opens **only 80/443 and the WireGuard port**; SSH is bound to `wg0`. An accidental
`docker run -p 8081:...` is **not** reachable from outside — verified (see `../proof/firewall-lab.txt`): Docker
publishes ports by DNAT in a way that bypasses UFW, so `ship` uses an nftables `inet host_fw` table with a
default-drop forward chain that admits new inbound connections only when they are DNAT'd to 80/443. Do **not** run
`ufw`; do **not** `flush ruleset` (that would wipe Docker's own tables).

Ubuntu notes (observed on 26.04.1):
- sshd is **socket-activated**; the script reloads it only if it is running (a console-only first run used to abort here).
- OpenSSH 10.2 already enables `PerSourcePenalties` by default; nothing to set.
- `wg`/`wg-quick` are **AppArmor-confined**: keep private keys in `/etc/wireguard/` (as the kit does), not in a home dir.
- Ubuntu's `nftables.service` runs `nft flush ruleset` on stop, which also wipes Docker's tables. The kit installs a drop-in
  so stop/restart only removes `inet host_fw`.
- `live-restore` keeps containers running across a plain `systemctl restart docker` (verified). **Changing Docker's
  `firewall-backend` while containers run broke Docker's internal DNS** (every app 500) until dockerd was restarted again.
  Switch backends only with the stack stopped: `./down.sh`, edit daemon.json, `systemctl restart docker`, `./up.sh`.
- `sudo` is sudo-rs and most coreutils are uutils; the scripts only use portable flags.

CI (optional): copy `build/<profile>/ci/forgejo-deploy.yml` into your app repo at `.forgejo/workflows/deploy.yml`.
It runs `bin/ship deploy .` on a host-local Forgejo runner (label `deploy`) on push to `main` — no inbound port.
See the self-hosted-ci-cd research for the runner and the `ci` lane that runs tests before this.

---

## 5. Go public (run these yourself; nothing here does)

### 5a. Public-IP host (`ubuntu-vps-small` / `ubuntu-home-public`)
1. In `profiles/<name>.yaml` set `exposure.domain`, `exposure.acme_email`, keep `acme_staging: true` for the first
   run. For `ubuntu-home-public`, port-forward TCP 80/443 (and UDP 443 for HTTP/3) on your router to the host.
2. Point DNS `A`/`AAAA` for `*.<domain>` (or each app host) at the public IP.
3. `bin/render.py <name> && ./up.sh <name>` and `bin/ship deploy <app>`. Caddy gets a Let's Encrypt **staging** cert
   over HTTP-01/TLS-ALPN-01. Verify, then set `acme_staging: false`, `./up.sh <name>` again for a real cert.
4. Check from off-network: `curl https://<app>.<domain>/` works; the registry/CrowdSec/admin ports do not respond.

### 5b. Behind NAT/CGNAT via an OSS relay (`ubuntu-home-nat`)
No inbound to your home is needed; a cheap relay VPS (1 vCPU / 512 MB, public IPv4) forwards traffic over WireGuard
and TLS still terminates **at home** (the relay never holds your keys or sees plaintext).
1. In `profiles/ubuntu-home-nat.yaml` set `exposure.domain`, and the `relay.*` addresses. `bin/render.py ubuntu-home-nat`.
2. **Relay VPS:** install WireGuard + HAProxy. Copy `build/ubuntu-home-nat/relay/`:
   `wgrelay-relay.conf` → `/etc/wireguard/wgrelay.conf`, `haproxy.cfg` → `/etc/haproxy/haproxy.cfg`,
   `nftables-relay.conf` → `/etc/nftables.conf`. Generate keys, exchange public keys with the home host, start
   `wg-quick@wgrelay`, `haproxy`, `nftables`. Point DNS `A`/`AAAA` for `*.<domain>` at the relay's public IP.
3. **Home host:** copy `build/ubuntu-home-nat/relay/wgrelay-home.conf` → `/etc/wireguard/wgrelay.conf`, create its key
   (`wg genkey > /etc/wireguard/wgrelay.key`, chmod 600), set the relay's
   public key + endpoint, `wg-quick up wgrelay`. Then `sudo build/ubuntu-home-nat/host/install-host.sh` and
   `./up.sh ubuntu-home-nat`.
4. HAProxy forwards 80/443 in TCP mode with **PROXY protocol v2**, so Caddy, the WAF and CrowdSec see the real
   attacker IP — not the relay's (verified: `../proof/proxy-protocol.txt`). The home firewall admits 80/443 **only**
   from the relay's WireGuard address, and Caddy accepts PROXY headers **only** from it (a forged header from anyone
   else is rejected).

**Admin plane, all profiles:** SSH, the registry (`127.0.0.1:5000`), CrowdSec and dashboards stay on loopback / the
internal Docker networks / WireGuard. For more than a couple of admin devices, run Headscale (OSS Tailscale control
plane) or NetBird instead of hand-managed WireGuard peers.

---

## 6. Operations

- **Logs:** `bin/ship edge logs -f caddy` (JSON access + WAF blocks), `... logs -f crowdsec`, `... logs kamal-proxy`
  (health-gate decisions). The access log file is in the `<project>_caddy_logs` volume (the edge image has no shell).
- **Bans:** `bin/ship edge exec crowdsec cscli decisions list` / `... cscli alerts list`. Unban:
  `... cscli decisions delete --ip <ip>`. Never-ban list: `crowdsec.whitelist` in the profile.
- **Upgrades:** bump a pin in `VERSIONS.env`, `./up.sh <profile>` (rebuilds the edge image), re-run `tests/validate.sh`.
- **Verify the platform:** `tests/validate.sh` (renders + validates every profile with the real tools),
  `tests/waf-verify.sh`, `tests/tls-headers.sh`, `tests/isolation.sh`, `tests/crowdsec-ban.sh`,
  `tests/firewall-lab.sh`, `tests/proxy-protocol.sh`, `tests/zero-downtime.sh`, `tests/signature-gate.sh`,
  `tests/broken-release.sh`; `tests/run-all.sh <outdir>` runs them all against the running profile. Evidence: `../proof-linux/`.
- **HSTS:** the verify profiles send `max-age=300` on purpose (local CA); the production profiles send one year.
- **Backups:** the state that matters is `state/<profile>/` (release history), `secrets/` (cosign key, bouncer key —
  keep offline), and the `registry_data` / `crowdsec_*` volumes.

## 7. Security posture (summary)

Layered, OSI-only: host nftables (default-deny, Docker-safe) → TLS 1.2+/auto-HTTPS → security headers + per-app CSP →
CrowdSec IP decisions → CrowdSec AppSec virtual patches → per-IP rate limit (429) → AI-scraper UA block → Coraza +
OWASP CRS v4 (PL1). App containers run non-root, read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, memory/pids
limits, on internal networks with no egress by default. Images are scanned (grype), carry an SBOM (syft) and are
cosign-signed and verified before running. Full threat→control map and the VERIFIED/NOT-VERIFIED table: `../findings.md`.
