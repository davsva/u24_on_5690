#!/usr/bin/env bash
# post-upgrade-nm-fix.sh
# Ubuntu 24.04 LTS network repair for Dell Mobile Precision 5690

set -euo pipefail
log(){ echo -e "[NM-FIX] $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"; exit 1
fi

log "Stopping NetworkManager and killing rogue dhclient processes…"
systemctl stop NetworkManager || true
pkill dhclient || true

# --- Netplan → NetworkManager ---
log "Ensuring netplan uses NetworkManager…"
mkdir -p /etc/netplan
cat >/etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
netplan generate
netplan apply || true

# --- Disable systemd-networkd (prevents route conflicts) ---
log "Disabling systemd-networkd…"
systemctl disable --now systemd-networkd 2>/dev/null || true
systemctl mask systemd-networkd 2>/dev/null || true

# --- Core NetworkManager config ---
log "Writing clean NetworkManager configuration…"
cat >/etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=keyfile

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
EOF

mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/dhcp-client.conf <<'EOF'
[main]
dhcp=internal
EOF
cat >/etc/NetworkManager/conf.d/dns.conf <<'EOF'
[main]
dns=systemd-resolved
EOF

# --- Allow NM service to write to /etc ---
log "Adding systemd override so NM can write connection files…"
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat >/etc/systemd/system/NetworkManager.service.d/override.conf <<'EOF'
[Service]
ProtectSystem=off
ProtectHome=off
ReadWritePaths=/etc /var/lib/NetworkManager /run /etc/NetworkManager/system-connections
EOF

# --- DNS integration ---
log "Enabling systemd-resolved and recreating stub resolv.conf…"
systemctl enable --now systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# --- Clean stale NM state/leases ---
log "Cleaning old leases and state…"
rm -f /var/lib/NetworkManager/NetworkManager.state 2>/dev/null || true
rm -f /var/lib/NetworkManager/*lease* 2>/dev/null || true
rm -f /var/lib/dhcp/* 2>/dev/null || true

# --- Restart services ---
log "Reloading systemd and restarting NetworkManager…"
systemctl daemon-reexec
systemctl daemon-reload
systemctl restart NetworkManager

# --- Bring up wired interface if present ---
ETH_IF=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="ethernet"{print $1; exit}' || true)
if [[ -n "${ETH_IF:-}" ]]; then
  log "Bringing up $ETH_IF via NetworkManager…"
  nmcli device set "$ETH_IF" managed yes || true
  if ! nmcli -t -f NAME,DEVICE con show | grep -q ":$ETH_IF$"; then
    nmcli connection add type ethernet ifname "$ETH_IF" con-name "wired-$ETH_IF" ipv4.method auto ipv6.method ignore || true
  fi
  nmcli device connect "$ETH_IF" || true
fi

# --- Final status ---
log "Final network status:"
nmcli device status || true
ip route || true
echo
log "If DNS still fails, run:"
echo "  resolvectl status | sed -n '1,100p'"
echo "  ping -c3 8.8.8.8"
echo "  ping -c3 google.com"
echo
log "Done. Please reboot once for all services to initialize cleanly."
