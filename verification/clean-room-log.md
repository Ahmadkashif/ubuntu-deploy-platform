# Clean-room deploy test: vuefresh (Vue 3 + Vite + Vue Router) via README only

Date: 2026-10-14. VM = edge (profile ubuntu-lan-verify). `V=lab/vmlab/vm`.
Documentation read: only `platform/README.md` (md5 cfd035d55a137b5769dc4dd50caa060b, identical to ~/platform/README.md on edge).

## 0. Baseline (edge)
`$V edge 'cd ~/platform && bin/ship status'`: astro (8080), vite (8080), next (3000) running.
Note: astro and vite both use PORT 8080, contradicting README "must be UNIQUE across your apps". Chose PORT=8081.

## 1. Scaffold (DONE)
Versions from `npm view` inside node:24.21.0-alpine: vue 3.5.44, vue-router 5.4.0, vite 8.3.4, @vitejs/plugin-vue 6.0.10 (all pinned exactly).
Files written by hand: package.json, vite.config.js (`build.assetsInlineLimit: 0`), index.html, src/main.js (createWebHistory, routes / and /about),
src/App.vue (onMounted sets `#js-status` text + `html[data-js=ran]`), src/views/Home.vue (`#counter` button), src/views/About.vue, src/style.css.
Lockfile, as README says:
```
tar c -C phase-3/clean-room/vuefresh . | $V edge 'mkdir -p ~/apps/vuefresh && tar x -C ~/apps/vuefresh && cd ~/apps/vuefresh && \
  docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v $PWD:/w -w /w node:24.21.0-alpine npm install --package-lock-only --no-audit --no-fund'
-> package-lock.json 53055 bytes (copied back to host)
```

## 2. Dockerfile + ship.env (DONE, one revision)
ship.env: APP=vuefresh PORT=8081 HEALTH_PATH=/health HOSTS="vuefresh" SMOKE_PATH=/
Dockerfile: node:24.21.0-alpine build stage (`npm ci`, `ARG SHIP_VERSION`, writes dist/version.txt), runtime static-web-server,
USER 1000:1000, `--port 8081 --root /public --health --page-fallback /public/index.html`.

## 3. Deploy (FAILED)
### Attempt 1 — runtime `joseluisq/static-web-server:2.44.1-alpine` (deploy1.out)
```
[ship 0s] deploy vuefresh version=20261014120534 profile=ubuntu-lan-verify hosts=[vuefresh.ship.test]
[ship 0s] [1/9] build
[ship 14s] [2/9] scan (grype, fail on >= critical)
[ship] ERROR: vulnerability gate failed (>= critical) — report: state/ubuntu-lan-verify/vuefresh/scans/20261014120534.txt
```
Report: libcrypto3/libssl3 3.5.7-r0 CVE-2026-63073 + CVE-2026-75803 Critical (fixed in 3.5.8-r0).
Fix: switched runtime to scratch-based `joseluisq/static-web-server:2.44.1` (entrypoint /static-web-server, CMD = flags only).

### Attempt 2 (deploy2.out) and 3 (deploy3.out) — steps 1-7 pass, step 8 fails
```
[ship 1s] deploy vuefresh version=20261014120744 profile=ubuntu-lan-verify hosts=[vuefresh.ship.test]
[ship 1s] [1/9] build
[ship 5s] [2/9] scan (grype, fail on >= critical)
[ship 7s]       findings: 0 (none >= critical)
[ship 7s] [3/9] SBOM (syft, SPDX JSON)
[ship 11s]      packages: 0
[ship 11s] [4/9] push
[ship 11s]      localhost:5000/vuefresh@sha256:6309014842dfc3054e0aff634f54f6de28ed91be51da6c4000c43b258860ef93
[ship 11s] [5/9] sign (cosign, local key, no transparency-log upload)
[ship 12s] [6/9] verify signature before running
[ship 12s] [7/9] run hardened container vuefresh-20261014120744
[ship 13s] [8/9] health-gated switch (kamal-proxy: /health must return 200)
Error: target failed to become healthy within configured timeout (1m0s)
[ship] ERROR: new release never became healthy — traffic stays on the previous release
```
(attempt 2: version 20261014120612, digest sha256:5f87fcc6fc13ff61dae1678dfb56400525f704fda79aaae30d28ee61640ad257, same failure)

### Diagnosis
- Container during the gate: user=1000:1000 ro=true mem=256m pids=256 tmpfs=/tmp net=shipedge_apps, running.
- `docker run --rm --network shipedge_apps curlimages/curl http://vuefresh-20261014120744:8081/health` -> 200 (app is healthy).
- kamal-proxy log: `Healthcheck failed ... dial tcp: lookup vuefresh-20261014120744 on 127.0.0.11:53: read udp 127.0.0.1:42722->127.0.0.11:53: read: connection refused`
- caddy log: `lookup crowdsec on 127.0.0.11:53 ... connection refused` -> Docker embedded DNS dead in all edge containers.
- Existing apps through edge (from edge VM, 127.0.0.1:443): vite 500, astro 500, next 500 (astro was 200 at 12:02:57 per kamal-proxy log).
- Cause (journalctl, sudo by another actor, not this test): 11:59-12:03 repeated `nft delete table inet host_fw` / `nft -f /etc/nftables.conf`,
  `systemctl restart nftables`, daemon.json edits, `systemctl restart docker` at 12:02:13, 12:02:26, 12:03:10
  (dockerd ActiveEnterTimestamp 12:03:12). daemon.json has `"live-restore": true`; containers survived the restart
  (kamal-proxy "Up 31 minutes") but lost their embedded-DNS (127.0.0.11) plumbing.
- Polled 12:09:57-12:12:28 every 30s: vite stayed 500, nobody repaired it.
- Attempted `bin/ship edge restart kamal-proxy crowdsec caddy` -> DENIED by the permission system (modifies shared edge). Stopped there.

### Image verified standalone (hardened flags, same digest) on edge VM
`docker run -d --read-only --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 <digest>`:
```
/health 200
/ 200
/about 200          (SPA fallback)
/does/not/exist 200 (SPA fallback)
/version.txt 200 -> 20261014120744 (SHIP_VERSION stamped)
/assets/index-B5wbR1nl.js 200
/assets/index-BxUiX_T9.css 200
inline scripts without src: 0
```

## 4-6. Edge verification, csp-check, fp-crawl, status (NOT RUN / BLOCKED)
Blocked by the broken edge DNS. `bin/ship status vuefresh` (run anyway) prints all routes (astro/next/vite), no vuefresh row:
the filter argument appears to be ignored for the route table, and failed deploys leave no release record.

---
## RESUMED 12:18 UTC (edge repaired by the other operator; vite/astro/next 200 from edge VM before redeploy)

## 3. Deploy (DONE) — deploy4.out
`$V edge 'cd ~/platform && bin/ship deploy ~/apps/vuefresh'`
```
[ship    0s] deploy vuefresh version=20261014121809 profile=ubuntu-lan-verify hosts=[vuefresh.ship.test]
[ship    0s] [1/9] build
[ship    8s] [2/9] scan (grype, fail on >= critical)
[ship   11s]       findings: 0 (none >= critical)
[ship   11s] [3/9] SBOM (syft, SPDX JSON)
[ship   14s]       packages: 0
[ship   14s] [4/9] push
[ship   14s]       localhost:5000/vuefresh@sha256:2858bad95182d2aab61b15db62bded87e8c417dd77d10d0cca8fb73dfc1842ec
[ship   14s] [5/9] sign (cosign, local key, no transparency-log upload)
[ship   15s] [6/9] verify signature before running
[ship   15s] [7/9] run hardened container vuefresh-20261014121809
[ship   15s] [8/9] health-gated switch (kamal-proxy: /health must return 200)
[ship   16s] edge routes reloaded (graceful): astro.ship.test next.ship.test vite.ship.test vuefresh.ship.test
[ship   16s] [9/9] smoke test through the edge
[ship   17s] smoke https://vuefresh.ship.test:443/ -> 200
[ship   17s] DONE vuefresh 20261014121809 -> https://vuefresh.ship.test:443
```

## 4. Through the full edge from client VM 198.51.100.50 (DONE)
CA: `$V edge 'cat ~/platform/secrets/edge-ca.crt' | $V client 'cat > ~/edge-ca.crt'` (subject CN=Caddy Local Authority - 2026 ECC Root)
`C="curl -s --cacert ~/edge-ca.crt --resolve vuefresh.ship.test:443:198.51.100.20"`
```
/ 200 (HTTP/2, body = vuefresh index.html)
/about 200 (same index.html: SPA fallback)
/about?x=1 200, /health 200, /version.txt 200
/assets/index-B5wbR1nl.js 200 text/javascript
/assets/index-BxUiX_T9.css 200 text/css
content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
strict-transport-security: max-age=300
x-content-type-options: nosniff
server-header-count: 0
(+ x-frame-options DENY, referrer-policy, permissions-policy, COOP, CORP)
/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E -> 403
```

## 5. Browser checks on edge (DONE) — step5-6.out
```
tests/csp-check.sh vuefresh.ship.test /
{ "url": "https://vuefresh.ship.test:443/",
  "jsStatus": "vuefresh JS ran at 2026-10-14T12:18:42.725Z",
  "button": { "before": "count is 0", "after": "count is 1" },
  "cspViolations": [], "consoleErrors": [] }
PASS: 0 CSP violations

tests/fp-crawl.sh vuefresh.ship.test / /about
200 GET /  ; 200 /assets/index-B5wbR1nl.js ; 200 /assets/index-BxUiX_T9.css
200 GET /about ; 200 (same 2 assets)
--- summary: 6 200
PASS: 0 blocked (no WAF false positives)
```
No CSP fix needed.

## 6. bin/ship status vuefresh (DONE)
```
Service   Host                Path  Target                        State    TLS  Rollout
astro ... / next ... / vite ... (route table is NOT filtered by the argument)
vuefresh  vuefresh.ship.test  /     vuefresh-20261014121809:8081  running  no   no
vuefresh       current=20261014121809               previous=-                            vuefresh.ship.test
```
App left deployed.
