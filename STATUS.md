# STATUS — ubuntu-deploy-platform (2026-10-14)

**State: DONE for everything that can be verified without a public domain.** Going public (domain, ACME, router/VPS exposure) stays NOT RUN by design.

| Area | Status |
|---|---|
| `platform/` updated (same layout) | done. 10 Linux-found bugs fixed in templates/scripts/tests (see `phase-3/deep-dive.md` §3.2) |
| New profiles | `ubuntu-lan-verify` (LAN, local CA, min 2 cores / 3.5 GB / 25 GB), `ubuntu-nat-verify` (relay path, local CA), `linux-docker-verify` (shared-host try-out, loopback only) |
| `proof-linux/` | fresh evidence per test for 3 environments (live Linux Docker, 26.04 VM LAN profile, 26.04 VM NAT profile + relay) |
| Brand-new frontend through the full edge | VERIFIED: Vue 3 app built by a clean-room agent from the README only, served over LAN and the relay, IPv4 + IPv6 |
| VERIFIED / NOT VERIFIED table | `phase-4/synthesis.md` (+ findings) |
| Live-host changes | **none** (no sudo or host config; only new Docker objects under `shipverify` / `udp-vmlab`) |
| Public repo | see findings (URL + commit) |
| Stack | stopped, volumes kept (live host: `./down.sh`; VMs powered off, disks kept) |

## Where things are
- Live host stack: `platform/` with `.profile = linux-docker-verify`, compose project `shipverify`, stopped.
- VM lab: container `udp-vmlab` (stopped). VM disks, keys and serial logs live in the session scratchpad
  (`.../scratchpad/vmlab/`): **ephemeral**. Rebuild the VMs with `lab/vmlab` if they are gone (≈20 s boot + install).

## Resume
```bash
cd platform && ./up.sh linux-docker-verify            # live host, loopback only
LAB_DIR=<dir> docker compose -p udp-vmlab -f lab/vmlab/compose.yaml up -d   # VM lab (KVM inside a container)
docker exec udp-vmlab vmlab up edge 20 4096 4 40      # + relay 30 512 1 8, client 50 1024 2 12
```

## Teardown (each line is independent; nothing here touches anything not created by this work)
```bash
# live-host edge stack (verify profile): stop only (keeps volumes)            -> already done
cd platform && ./down.sh
# remove it completely (containers, 5 networks, 7 volumes; asks to confirm)
cd platform && ./down.sh --purge && docker volume rm shipverify_grype_db
# VM lab: power off VMs, remove the lab container, its network and image
docker exec udp-vmlab vmlab down edge; docker exec udp-vmlab vmlab down relay; docker exec udp-vmlab vmlab down client
docker compose -p udp-vmlab -f lab/vmlab/compose.yaml down && docker image rm udp-vmlab:1
rm -rf <scratchpad>/vmlab                                  # VM disks + cloud images (~10 GB)
# images pulled/built for this work (skip any you also use elsewhere)
docker image rm shipverify-caddy:v2.11.4-crs4.25.1 ship-fwlab:24.04 chromedp/headless-shell:latest \
  $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost:15055/')
docker image rm crowdsecurity/crowdsec:v1.8.1 basecamp/kamal-proxy:v0.10.0 registry:3.1.1 anchore/grype:v0.119.0 \
  anchore/syft:v1.52.0 ghcr.io/sigstore/cosign/cosign:v3.1.3 haproxy:3.2.23-alpine rhysd/actionlint:1.7.12 koalaman/shellcheck:v0.11.0
# build cache: `docker builder prune` is GLOBAL on this Docker; run it only if nothing else here depends on the cache.
```
