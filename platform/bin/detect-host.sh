#!/usr/bin/env bash
# Detect this host and compare it with the `minimum:` block of every profiles/*.yaml.
#   bin/detect-host.sh                 -> facts + per-profile verdict + RECOMMENDED=<profile>
#   bin/detect-host.sh --check <name>  -> exit 0 if the host meets <name>'s minimum, 3 if not
#   bin/detect-host.sh --facts         -> KEY=VALUE facts only
# Hard requirements: OS, arch, RAM. Soft (warn only): CPU cores, free disk, Docker major version.
# Exposure (public IP vs NAT) cannot be detected reliably without contacting the internet, so it is NOT probed:
# pick ubuntu-vps-small / ubuntu-home-public / ubuntu-home-nat yourself (see README "Which profile?").
# SAFETY: RECOMMENDED only ever names a profile that renders NO host kit (render.host=false: loopback, no firewall /
# daemon.json / sshd / sysctl). Profiles that change the host or expose ports must be chosen explicitly, because
# ./up.sh with no argument uses RECOMMENDED. Shared-host signals (other containers, listeners on 80/443, an existing
# daemon.json, Tailscale, UFW) are printed so you can see why a host-kit profile would be risky here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R() { python3 "$ROOT/bin/render.py" --get "$1" "$2"; }
MODE=table; CHECK=""
case "${1:-}" in
  --check) MODE=check; CHECK="${2:?profile name}";;
  --facts) MODE=facts;;
  -h|--help) sed -n '2,9p' "$0"; exit 0;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH="$(uname -m)";; esac
if [ "$OS" = darwin ]; then
  RAM_GB="$(awk -v b="$(sysctl -n hw.memsize)" 'BEGIN{printf "%.1f", b/1073741824}')"
  CORES="$(sysctl -n hw.ncpu)"; DISTRO="macos-$(sw_vers -productVersion 2>/dev/null || echo ?)"
else
  RAM_GB="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
  # honour a cgroup memory limit (containers / small VMs) if lower than MemTotal
  if [ -r /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != max ]; then
    CG="$(awk '{printf "%.1f", $1/1073741824}' /sys/fs/cgroup/memory.max)"
    awk -v a="$CG" -v b="$RAM_GB" 'BEGIN{exit !(a<b)}' && RAM_GB="$CG"
  fi
  CORES="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
  # honour a cgroup CPU quota (e.g. docker --cpus / small VMs)
  if [ -r /sys/fs/cgroup/cpu.max ] && ! grep -q '^max' /sys/fs/cgroup/cpu.max; then
    CORES="$(awk -v c="$CORES" '{q=$1/$2; if (q<c) c=q; printf "%g", c}' /sys/fs/cgroup/cpu.max)"
  fi
  DISTRO="$( . /etc/os-release 2>/dev/null && echo "${ID:-linux}-${VERSION_ID:-?}" || echo linux)"
fi
DISK_GB="$(df -Pk "$ROOT" | awk 'NR==2{printf "%.0f", $4/1048576}')"
DOCKER=absent
if command -v docker >/dev/null 2>&1; then DOCKER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo not-running)"; fi
DOCKER_MAJOR="$(printf '%s' "$DOCKER" | awk -F. '/^[0-9]/{print $1; exit}')"
# Linux-only extra facts (read-only): uplink, cgroup, Docker firewall backend, OpenSSH, shared-host signals
UPLINK=""; CGROUP=""; FWB=""; SSHV=""; SSH_SOCKET=""; SHARED=""
if [ "$OS" = linux ]; then
  UPLINK="$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  CGROUP="$( [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ] && echo v2 || echo v1)"
  if [ "$DOCKER_MAJOR" ]; then FWB="$(docker info --format '{{if .FirewallBackend}}{{.FirewallBackend.Driver}}{{end}}' 2>/dev/null || true)"; fi
  SSHV="$( (ssh -V 2>&1 || true) | awk '{print $1}' | tr -d ',')"
  systemctl is-enabled ssh.socket >/dev/null 2>&1 && SSH_SOCKET=yes || SSH_SOCKET=no
  if [ "$DOCKER_MAJOR" ]; then
    n="$(docker ps --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | grep -cvE '^(shipedge|shipverify)$' || true)"
    if [ "${n:-0}" -gt 0 ]; then SHARED="$SHARED other-containers=$n"; fi
  fi
  if command -v ss >/dev/null && ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'; then SHARED="$SHARED listener-on-80/443"; fi
  if [ -f /etc/docker/daemon.json ]; then SHARED="$SHARED existing-daemon.json"; fi
  if command -v tailscale >/dev/null 2>&1; then SHARED="$SHARED tailscale"; fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then SHARED="$SHARED ufw-active"; fi
fi

if [ "$MODE" = facts ]; then
  printf 'OS=%s\nARCH=%s\nDISTRO=%s\nRAM_GB=%s\nCPU_CORES=%s\nDISK_FREE_GB=%s\nDOCKER=%s\n' \
    "$OS" "$ARCH" "$DISTRO" "$RAM_GB" "$CORES" "$DISK_GB" "$DOCKER"
  [ "$OS" = linux ] && printf 'UPLINK=%s\nCGROUP=%s\nDOCKER_FIREWALL_BACKEND=%s\nOPENSSH=%s\nSSH_SOCKET_ACTIVATED=%s\nSHARED_HOST_SIGNALS=%s\n' \
    "$UPLINK" "$CGROUP" "$FWB" "$SSHV" "$SSH_SOCKET" "${SHARED# }"
  exit 0
fi

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
inlist() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

printf 'Host: os=%s arch=%s distro=%s ram=%sGB cores=%s disk_free=%sGB docker=%s\n' \
  "$OS" "$ARCH" "$DISTRO" "$RAM_GB" "$CORES" "$DISK_GB" "$DOCKER"
if [ "$OS" = linux ]; then
  printf 'Linux: uplink=%s cgroup=%s docker-firewall=%s openssh=%s ssh.socket=%s\n' "${UPLINK:-?}" "$CGROUP" "${FWB:-?}" "${SSHV:-?}" "$SSH_SOCKET"
  printf 'Shared-host signals: %s\n' "${SHARED:- none}"
fi
echo
printf '%-20s %-16s %s\n' PROFILE STATUS VERDICT
best=""; best_ram=-1; rc=3
for f in "$ROOT"/profiles/*.yaml; do
  p="$(basename "$f" .yaml)"
  hard=""; soft=""
  inlist "$OS" "$(R "$p" minimum.os)" || hard="$hard os $OS not in [$(R "$p" minimum.os)];"
  inlist "$ARCH" "$(R "$p" minimum.arch)" || hard="$hard arch $ARCH not in [$(R "$p" minimum.arch)];"
  ram="$(R "$p" minimum.ram_gb)"; ge "$RAM_GB" "$ram" || hard="$hard RAM ${RAM_GB}<${ram}GB;"
  ge "$CORES" "$(R "$p" minimum.cpu_cores)" || soft="$soft cores ${CORES}<$(R "$p" minimum.cpu_cores);"
  ge "$DISK_GB" "$(R "$p" minimum.disk_free_gb)" || soft="$soft disk ${DISK_GB}<$(R "$p" minimum.disk_free_gb)GB;"
  dm="$(R "$p" minimum.docker_major)"
  if [ -z "$DOCKER_MAJOR" ]; then soft="$soft docker $DOCKER (need >= $dm);"
  else ge "$DOCKER_MAJOR" "$dm" || soft="$soft docker ${DOCKER_MAJOR}<${dm};"; fi
  if [ -z "$hard" ]; then
    v="OK"; [ -n "$soft" ] && v="OK (warn:$soft)"
    [ "$p" = "$CHECK" ] && rc=0
    # auto-recommend only profiles that leave the host untouched (render.host=false), for this OS
    if [ "$(R "$p" platform)" = "$OS" ] && [ "$(R "$p" render.host)" = false ]; then
      if ge "$ram" "$best_ram" && [ "$ram" != "$best_ram" ]; then best="$p"; best_ram="$ram"; fi
    fi
  else
    v="below minimum:$hard"
  fi
  printf '%-20s %-16s %s\n' "$p" "$(R "$p" status)" "$v"
done
if [ "$OS" = linux ]; then
  echo; echo "NOTE: host-kit profiles (firewall, daemon.json, sshd, sysctl) are never auto-recommended — pick one explicitly:"
  echo "      public IP -> ubuntu-vps-small / ubuntu-home-public; behind NAT/CGNAT -> ubuntu-home-nat; LAN only -> ubuntu-lan-verify."
  [ -z "$SHARED" ] || echo "      This host shows shared-host signals (${SHARED# }): do NOT run install-host.sh here; use a dedicated host or VM."
fi
echo; echo "RECOMMENDED=${best:-none}"
if [ "$MODE" = check ]; then exit "$rc"; fi
[ -n "$best" ] || exit 2
