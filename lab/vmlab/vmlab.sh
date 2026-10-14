#!/usr/bin/env bash
# vmlab — run inside the udp-vmlab container.
#   vmlab serve                         set up bridge/NAT, then idle (container main process)
#   vmlab up <name> <ip-suffix> <mem-MiB> <cpus> <disk-GB>   create (first time) + boot a VM
#   vmlab down <name>                   power off (ACPI, then kill)
#   vmlab ssh <name> [cmd...]           ssh ubuntu@<vm>
#   vmlab ip <name>
# Lab segment: 198.51.100.0/24 (TEST-NET-2) + 2001:db8:5::/64; gateway/NAT .1 / ::1. VM NIC is renamed eth0.
set -euo pipefail
L=/lab; IMG=$L/img/${VM_IMAGE:-ubuntu-26.04-server-cloudimg-amd64.img}   # VM_IMAGE=<file in /lab/img> picks another release
BR=labbr0; P4=198.51.100; P6=2001:db8:5
mkdir -p $L/vms
key() { [ -f $L/id_lab ] || ssh-keygen -q -t ed25519 -N '' -f $L/id_lab -C vmlab; }
SSHO="-i $L/id_lab -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
ipof() { cat $L/vms/$1/ip; }
case "${1:-}" in
serve)
  key
  ip link add $BR type bridge 2>/dev/null || true
  ip addr add $P4.1/24 dev $BR 2>/dev/null || true
  ip -6 addr add $P6::1/64 dev $BR nodad 2>/dev/null || true
  ip link set $BR up
  nft -f - <<NFT
table ip vmlab_nat {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $P4.0/24 oifname "eth0" masquerade
  }
}
NFT
  echo "vmlab ready: bridge $BR $P4.1/24 $P6::1/64"; exec sleep infinity;;
up)
  n=$2; s=$3; mem=$4; cpu=$5; disk=$6; d=$L/vms/$n; mkdir -p $d; key
  mac=$(printf '52:54:00:5a:00:%02x' "$s")
  if [ ! -f $d/disk.qcow2 ]; then
    qemu-img create -q -f qcow2 -F qcow2 -b $IMG $d/disk.qcow2 ${disk}G
    cat > $d/user-data <<UD
#cloud-config
hostname: $n
users:
  - name: ubuntu
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat $L/id_lab.pub)"]
package_update: false
UD
    cat > $d/network-config <<NC
version: 2
ethernets:
  lan:
    match: {macaddress: "$mac"}
    set-name: eth0
    addresses: [$P4.$s/24, "$P6::$s/64"]
    routes: [{to: default, via: $P4.1}, {to: "::/0", via: "$P6::1"}]
    nameservers: {addresses: [1.1.1.1, 9.9.9.9]}
NC
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$n" "$n" > $d/meta-data
    cloud-localds -N $d/network-config $d/seed.iso $d/user-data $d/meta-data
    echo $P4.$s > $d/ip
  fi
  ip tuntap add dev tap-$n mode tap 2>/dev/null || true
  ip link set tap-$n master $BR up
  qemu-system-x86_64 -name $n -enable-kvm -cpu host -smp $cpu -m $mem -display none -daemonize \
    -pidfile $d/pid -serial file:$d/serial.log -monitor unix:$d/mon.sock,server,nowait \
    -drive file=$d/disk.qcow2,if=virtio,cache=unsafe -drive file=$d/seed.iso,if=virtio,format=raw,readonly=on \
    -netdev tap,id=n0,ifname=tap-$n,script=no,downscript=no -device virtio-net-pci,netdev=n0,mac=$mac \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0
  for i in $(seq 1 90); do ssh $SSHO ubuntu@$(ipof $n) true 2>/dev/null && break; sleep 2; done
  ssh $SSHO ubuntu@$(ipof $n) 'cloud-init status --wait >/dev/null 2>&1; echo "$(hostname) up: $(. /etc/os-release; echo $PRETTY_NAME) kernel $(uname -r)"';;
down)
  d=$L/vms/$2; echo system_powerdown | socat - UNIX-CONNECT:$d/mon.sock >/dev/null 2>&1 || true
  for i in $(seq 1 30); do kill -0 "$(cat $d/pid 2>/dev/null)" 2>/dev/null || break; sleep 1; done
  kill "$(cat $d/pid 2>/dev/null)" 2>/dev/null || true; ip link del tap-$2 2>/dev/null || true; echo "$2 down";;
ssh) n=$2; shift 2; exec ssh $SSHO ubuntu@$(ipof $n) "$@";;
ip) ipof $2;;
*) sed -n '2,8p' "$0"; exit 2;;
esac
