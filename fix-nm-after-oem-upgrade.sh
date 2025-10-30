#!/usr/bin/env bash
set -euo pipefail
echo "=== $(date -Iseconds) | Fix NetworkManager after OEM kernel upgrade ==="

# 1) Ensure NetworkManager service sandbox allows configuration writes
sudo mkdir -p /etc/systemd/system/NetworkManager.service.d
sudo tee /etc/systemd/system/NetworkManager.service.d/override.conf >/dev/null <<'EOF'
[Service]
ProtectSystem=off
ProtectHome=off
ReadWritePaths=/etc /var/lib/NetworkManager /run /etc/NetworkManager/system-connections
EOF

# 2) Reset dhcp-client backend to internal (systemd one fails under some OEM kernels)
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/dhcp-client.conf >/dev/null <<'EOF'
[main]
dhcp=internal
EOF

# 3) Ensure network devices are handled by NetworkManager
sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=none
EOF

# 4) Re-exec NM under the new kernel’s environment
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart NetworkManager

echo "[ok] NetworkManager restarted and DHCP client reset."
echo "Try reconnecting to your Wi-Fi now, or run:"
echo "  nmcli device wifi connect <SSID> password <PASSWORD>"
