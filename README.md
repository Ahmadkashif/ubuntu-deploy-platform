# ship: a small, fully open-source way to deploy frontends safely onto one Ubuntu box

`ship` deploys any app that ships a Dockerfile with one HTTP port and a health path. Each deploy runs:

**build → grype scan (fails on critical) → syft SBOM → push by digest → cosign sign + verify → run hardened → health-gated cutover (kamal-proxy) → smoke test through the edge → keep the previous release for rollback.**

In front sits one edge: **Caddy 2.11 → CrowdSec bouncer + AppSec → per-IP rate limit → AI-scraper block → Coraza WAF + OWASP CRS 4.25.1 LTS → kamal-proxy → app**.

The host side has three parts:
- a Docker-safe nftables firewall (`inet host_fw`);
- an admin plane that is reachable only over WireGuard;
- an optional **WireGuard + HAProxy PROXY-v2 relay** for homes behind NAT/CGNAT.

Everything is OSI-licensed. There is no Trivy, no UFW, nothing BSL and no PaaS. Every host is described by a **profile** that states its **minimum specs**, so nothing is hand-fitted to one machine.

This repo is the working PoC plus its evidence. The full user guide is **[`platform/README.md`](platform/README.md)**.

## Layout
| Path | What |
|---|---|
| `platform/` | the platform: `bin/ship`, `bin/render.py`, `bin/detect-host.sh`, `up.sh`/`down.sh`, `profiles/`, `templates/` (edge, host, relay, CI), `edge/image`, `examples/`, `tests/` |
| `lab/` | the verification lab: `vmlab/` runs **real KVM VMs (Ubuntu 26.04/24.04 cloud images) inside one container**, with no host install. Also scripts for the real-host firewall test, the relay end-to-end test, zero-downtime under load, and the public-repo scan |
| `proof-linux/` | captured evidence, one file per test (commands + raw outputs) |
| `verification/` | the clean-room app: a brand-new Vue 3 frontend built from the README alone, plus its log |
| `STATUS.md`, `backlog.md` | state, teardown, and deferred ideas |

## Quick try (any Linux with Docker ≥ 29, host untouched)
```bash
cd platform
./up.sh linux-docker-verify                 # edge on 127.0.0.1:19080/19443 only, own compose project
bin/ship deploy examples/astro-static
curl --cacert secrets/edge-ca.crt https://astro.localhost:19443/
tests/run-all.sh /tmp/proof                 # the full behaviour test suite
./down.sh                                   # stop (keeps volumes)
```
For a real server, follow `platform/README.md` §3–5. Pick a profile, `bin/render.py <profile>`, review `build/<profile>/host/install-host.sh`, and run it from a console.

## What was verified (2026-10-14) and what was NOT RUN
Three environments:
- **L**: Linux Docker 29.8.1 on Ubuntu 24.04, loopback profile.
- **V1**: an Ubuntu 26.04.1 KVM VM with the full host kit, Docker 29.9.0 from Docker's apt repo, profile `ubuntu-lan-verify`.
- **V2**: the same VM on `ubuntu-nat-verify`, plus a 512 MB relay VM and a client VM. The lab network uses the documentation ranges 198.51.100.0/24 and 2001:db8:5::/64.

| Item | Result |
|---|---|
| WAF: 13/13 realistic attacks → 403, 5/5 benign → 2xx (L, V1, V2) | **VERIFIED**. CRS PL1 still misses `;id` (documented gap). |
| Rate limit (400 burst → 300×200 + 100×429), CrowdSec scanner ban → 403, TLS ≥1.2 + security headers, AI-crawler UA block | **VERIFIED** |
| Admin plane / registry / CrowdSec / kamal-proxy unreachable from the public side | **VERIFIED** on Docker networks and the real LAN |
| `docker run -p 0.0.0.0:8081` bypass closed by `host_fw` on a **real host**, iptables and nftables backends; DOCKER-ISOLATION between bridges | **VERIFIED** (V1) |
| `install-host.sh` on **Ubuntu 26.04.1** (run twice, idempotent, survives reboot) and **24.04.5** | **VERIFIED** |
| WireGuard admin plane: SSH only via wg0 or the admin LAN | **VERIFIED** (IPv4 tunnel) |
| NAT relay end to end: real client IP at Caddy over **IPv4 and IPv6**, direct-to-home dropped, forged PROXY headers refused, CrowdSec bans the real client through the relay | **VERIFIED** (V2) |
| Zero-downtime redeploy + rollback under load: 30,000 requests at 200 req/s from 10 IPs, each on a new TLS connection | **VERIFIED**: 0 non-200, p99 158 ms |
| Broken release refused by the health gate; signature gate (unsigned digest refused); scan gate refused real criticals | **VERIFIED** |
| Brand-new frontend (Vue 3 + Vite) from the README only, through the full edge and through the relay, v4 + v6, 0 CSP violations | **VERIFIED** |
| 2 GB / 2 vCPU / no swap: idle 643 MiB used (edge + 4 apps); cold Next.js build peak 1614 MiB; cold edge-image build peak 1285 MiB | **VERIFIED**: fits with thin headroom. Disk (~13 GB) is the tighter limit. |
| Relay VPS at 512 MB | **VERIFIED**: 221 MiB used |
| ACME certificates, a public IP or domain, router port-forward, real internet scanning | **NOT RUN**: needs a domain and public exposure (out of scope). Commands are in `platform/README.md` §5. |
| Volumetric L3/L4 DDoS; go-ftw CRS regression; CRS PL2 false-positive pass | **NOT RUN** |
| An actual unattended upgrade plus the 04:30 auto-reboot | **NOT RUN**. The config is live and the Docker CE origin is allowed. |

Bugs found on real Linux and fixed:
- `ufw` detection matched "inactive".
- Ubuntu's `nftables.service` flushed Docker's tables on restart.
- A socket-activated `sshd` made `systemctl reload ssh` abort the install.
- cosign could not read the 0600 key on Linux.
- `detect-host` auto-recommended a host-changing profile.
- IPv6 was unreachable (the published network had no IPv6).
- HTTP :80 through the relay returned 400 (Caddy's auto-redirect server ignores `listener_wrappers`).
- Several test bugs that Docker Desktop had hidden.

Details are in `proof-linux/` and the Phase 3 notes of the research.

## Left out on purpose (safety)
- **No secrets.** There are no cosign keys or password, no CrowdSec bouncer key, no edge CA or PKI, and no `.env` files. `up.sh` generates them per host into `platform/secrets/` (git-ignored).
- **No machine identity.** No hostnames, LAN addresses or tailnet names of the machines used. All lab addresses are RFC 5737/3849 documentation ranges.
- **No code from private repositories.**
- WireGuard public keys in the evidence are redacted.

## License
MIT (see `LICENSE`). Third-party components keep their own licences: Caddy (Apache-2.0), Coraza (Apache-2.0), OWASP CRS (Apache-2.0), CrowdSec (MIT), kamal-proxy (MIT), registry (Apache-2.0), grype/syft (Apache-2.0), cosign (Apache-2.0), HAProxy (GPL-2.0, used as an unmodified package or container), WireGuard tools (GPL-2.0), static-web-server (MIT/Apache-2.0), and ai.robots.txt (MIT; vendored list in `platform/edge/bots.caddy`).
