#!/usr/bin/env bash
# fix-oem-kernel-5690.sh
# Dell Precision 5690 — keep OEM kernel track on Ubuntu 24.04
# - Installs OEM kernel (or HWE if OEM meta unavailable)
# - Ensures firmware is present
# - UNHOLDs linux-oem-24.04 (so OEM kernels keep updating)
# - HOLDs linux-generic* (so system won't flip away from OEM)
# Safe to re-run.

set -euo pipefail
LOG="/var/log/fix-oem-kernel-5690.log"
exec > >(tee -a "$LOG") 2>&1

need_root(){ [[ $EUID -eq 0 ]] || { echo "Run with sudo/root."; exit 1; }; }
pkg_avail(){ apt-cache policy "$1" | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; }
pkg_inst(){ dpkg -l "$1" 2>/dev/null | awk '/^ii/{ok=1} END{exit ok?0:1}'; }
running_oem(){ uname -r | grep -q -- '-oem'; }

need_root
. /etc/os-release || { echo "Missing /etc/os-release"; exit 1; }
if [[ "${VERSION_ID:-}" != "24.04" ]]; then
  echo "This script targets Ubuntu 24.04 (Noble). Detected: ${VERSION_ID:-unknown}."
  exit 1
fi

OEM_META="linux-oem-24.04"
HWE_META="linux-generic-hwe-24.04"

echo "=== $(date -Iseconds) | Precision 5690 OEM-kernel guard ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true

# Firmware that often matters for AX2xx & friends
apt-get install -y --no-install-recommends linux-firmware linux-firmware-intel || true

# Prefer OEM kernel meta; fall back to HWE if OEM meta not available
if pkg_avail "$OEM_META"; then
  echo "[kernel] Installing/ensuring $OEM_META"
  apt-get install -y "$OEM_META"
else
  echo "[warn] $OEM_META not in your repos; installing $HWE_META as fallback"
  apt-get install -y "$HWE_META"
fi

# Optional Dell helpers (best-effort)
for opt in oem-release oem-kernel-support oem-somerville-meta; do
  if pkg_avail "$opt"; then
    apt-get install -y "$opt" || true
  fi
done

# --- Pinning policy (best practice) ---
# 1) Ensure OEM meta is NOT held, so it can pull newer OEM kernels
if pkg_inst "$OEM_META"; then
  if apt-mark showhold | grep -qx "$OEM_META"; then
    echo "[pin] Unholding $OEM_META so OEM kernel updates continue"
    apt-mark unhold "$OEM_META" || true
  else
    echo "[pin] $OEM_META is not held (good)."
  fi
else
  echo "[info] $OEM_META not installed (you may be on HWE)."
fi

# 2) Hold generic tracks so APT won't switch you off OEM
for g in linux-generic linux-generic-hwe-24.04; do
  if pkg_inst "$g"; then
    if ! apt-mark showhold | grep -qx "$g"; then
      echo "[pin] Holding $g to prevent kernel track flip"
      apt-mark hold "$g" || true
    else
      echo "[pin] $g already held."
    fi
  fi
done

echo
echo "[info] Kernel images installed:"
dpkg -l 'linux-image-*' | awk '/^ii/{print $2, $3}' | sort
echo "[info] Running kernel: $(uname -r)"

echo
echo "[info] Current holds:"
apt-mark showhold || true

if running_oem; then
  echo "[ok] You are running an OEM kernel."
else
  if pkg_inst "$OEM_META"; then
    echo "[next] OEM kernel installed but not running. Reboot to load it, then re-run this script to verify."
  else
    echo "[note] OEM meta unavailable/unused. You are on HWE/generic; acceptable, but OEM is recommended for the 5690."
  fi
fi

echo "[done] Log: $LOG"
