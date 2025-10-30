#!/usr/bin/env bash
# upgrade-to-24.04-precision5690.sh
# Dell Precision 5690: Jammy (22.04) -> Noble (24.04) with OEM/HWE kernel + IPU6 (MTL) stack
set -euo pipefail

STATE_DIR="/var/lib/upgrade-24.04"
LOG="/var/log/upgrade-to-24.04-precision5690.log"
DISABLED_DIR="/etc/apt/disabled.lists"
DELL_LIST="/etc/apt/sources.list.d/dell-somerville.list"
DELL_PREF="/etc/apt/preferences.d/dell-somerville.pref"
TMPFILES_RULE="/etc/tmpfiles.d/camera.conf"
UDEV_RULE="/etc/udev/rules.d/66-intel-ipu6-perms.rules"

DELL_LINE='deb http://dell.archive.canonical.com/ noble somerville'
OEM_META="linux-oem-24.04"
HWE_META="linux-generic-hwe-24.04"

PKG_IPU6=(
  ubuntu-oem-keyring
  gstreamer1.0-icamera
  v4l2-relayd
  libcamhal0
  libcamhal-common
  libcamhal-ipu6epmtl
  libcamhal-ipu6epmtl-common
  linux-modules-ipu6-generic-hwe-24.04
)

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
ts(){ date -Iseconds; }
mark(){ touch "$STATE_DIR/$1.done"; }
donep(){ [[ -e "$STATE_DIR/$1.done" ]]; }

os_id(){ . /etc/os-release; echo "${VERSION_ID:-unknown}"; }
os_code(){ . /etc/os-release; echo "${VERSION_CODENAME:-unknown}"; }
pkg_avail(){ apt-cache policy "$1" | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; }

need_root
echo "=== $(ts) | Precision 5690 LTS upgrader ==="
echo "Log: $LOG"
echo

STEP="00-apt-prep"
if ! donep "$STEP"; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || true
  apt-get install -y --no-install-recommends software-properties-common ca-certificates || true
  add-apt-repository -y universe || true
  add-apt-repository -y multiverse || true
  apt-get update || true
  mark "$STEP"
fi

# -- Firmware early (safe to repeat) --
STEP="01-fwupd"
if ! donep "$STEP"; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends fwupd fwupd-signed || true
  fwupdmgr refresh --force || true
  fwupdmgr get-updates || true
  fwupdmgr update -y || true   # may be no-ops; if updates require reboot, do it later
  mark "$STEP"
fi

CURR_ID="$(os_id)"; CURR_CODE="$(os_code)"
echo "[info] Current OS: $CURR_ID ($CURR_CODE)"

# -- Jammy-only: make sure Prompt!=never, fully update, disable 3rd-party, then upgrade --
if [[ "$CURR_ID" == "22.04" ]]; then

  STEP="02-jammy-fix-prompt"
  if ! donep "$STEP"; then
    if grep -q '^Prompt=never' /etc/update-manager/release-upgrades 2>/dev/null; then
      sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
      echo "[fix] Set Prompt=lts in /etc/update-manager/release-upgrades"
    else
      # ensure it's lts anyway
      if grep -q '^Prompt=' /etc/update-manager/release-upgrades; then
        sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
      else
        echo 'Prompt=lts' >> /etc/update-manager/release-upgrades
      fi
    fi
    mark "$STEP"
  fi

  STEP="03-jammy-update-all"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a || true
    apt-get -f install -y || true
    apt-get update -y
    # Use full-upgrade to clear "kept back" transitions
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade -y
    apt-get autoremove --purge -y || true
    apt-get clean || true
    mark "$STEP"
  fi

  STEP="04-jammy-disable-thirdparty"
  if ! donep "$STEP"; then
    mkdir -p "$DISABLED_DIR"
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list; do
      base=$(basename "$f")
      if ! grep -qE 'ubuntu\.com|canonical\.com|dell\.archive\.canonical\.com' "$f"; then
        mv "$f" "$DISABLED_DIR/$base.disabled"
        echo "[info] Disabled third-party list: $base"
      fi
    done
    apt-get update -y || true
    mark "$STEP"
  fi

  STEP="05-do-release-upgrade"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y update-manager-core ubuntu-release-upgrader-core || true
    echo "[action] Starting non-interactive release upgrade to 24.04..."
    # This may reboot or pause. Just run the script again afterwards.
    do-release-upgrade -f DistUpgradeViewNonInteractive -m server || true
    mark "$STEP"
    echo "[note] If the upgrader requested a reboot, do it now. Then re-run this script."
    exit 0
  fi
fi

# Re-evaluate after potential reboot/upgrade
CURR_ID="$(os_id)"; CURR_CODE="$(os_code)"
echo "[info] Current OS: $CURR_ID ($CURR_CODE)"

# -- Noble (24.04) post-steps (Path B, kernel, camera, perms) --
if [[ "$CURR_ID" == "24.04" ]]; then

  STEP="06-add-dell-archive"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends ubuntu-oem-keyring || true
    if ! grep -qs "^deb .*dell.archive.canonical.com.* noble somerville" "$DELL_LIST" 2>/dev/null; then
      echo "$DELL_LINE" > "$DELL_LIST"
    fi
    mkdir -p "$(dirname "$DELL_PREF")"
    cat > "$DELL_PREF" <<'EOF'
Package: *
Pin: origin "dell.archive.canonical.com"
Pin-Priority: 100

Package: libcamhal0
Pin: origin "dell.archive.canonical.com"
Pin-Priority: 1001
EOF
    apt-get update -y || true
    mark "$STEP"
  fi

  STEP="07-kernel-meta"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    if pkg_avail "$OEM_META"; then
      echo "[kernel] Installing $OEM_META"
      apt-get install -y "$OEM_META"
    else
      echo "[kernel] $OEM_META not available, installing $HWE_META"
      apt-get install -y "$HWE_META"
    fi
    mark "$STEP"
  fi

  STEP="08-ipu6-stack"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "${PKG_IPU6[@]}" || true
    mark "$STEP"
  fi

  STEP="09-permissions"
  if ! donep "$STEP"; then
    # udev: cover ipu-psys*/ipu-isys* and intel_ipu6_* as seen on your box
    cat > "$UDEV_RULE" <<'EOF'
# Intel IPU6 device access for non-root users (video group)
SUBSYSTEM=="misc", KERNEL=="intel_ipu6_psys*", MODE="0660", GROUP="video"
SUBSYSTEM=="misc", KERNEL=="intel_ipu6_isys*", MODE="0660", GROUP="video"
KERNEL=="ipu-psys*", MODE="0660", GROUP="video"
KERNEL=="ipu-isys*", MODE="0660", GROUP="video"
SUBSYSTEM=="media", ATTR{name}=="*ipu*", MODE="0660", GROUP="video"
EOF
    udevadm control --reload-rules || true
    udevadm trigger || true

    # runtime dir for CamHAL
    echo 'D /run/camera 1777 root root -' > "$TMPFILES_RULE"
    systemd-tmpfiles --create || true

    # auto-remove stale SysV SHM segments on process exit
    echo 'kernel.shm_rmid_forced = 1' > /etc/sysctl.d/99-camhal.conf
    sysctl --system || true

    # add invoking user to groups
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
      usermod -aG video,render "$SUDO_USER" || true
      echo "[info] Added $SUDO_USER to groups: video, render (re-login required)."
    fi
    mark "$STEP"
  fi

  STEP="10-relay-defaults"
  if ! donep "$STEP"; then
    # Provide a sane v4l2-relayd config (optional; safe if service exists)
    install -d /etc
    cat > /etc/v4l2-relayd/config.ini <<'EOF'
[relay]
source = icamerasrc num-buffers=0
caps   = video/x-raw,format=NV12,width=1280,height=720,framerate=30/1
sink   = /dev/video51
EOF
    systemctl enable --now v4l2-relayd 2>/dev/null || true
    systemctl restart v4l2-relayd 2>/dev/null || true
    journalctl -u v4l2-relayd -b --no-pager | tail -n 60 || true
    mark "$STEP"
  fi

  STEP="11-final-upgrade"
  if ! donep "$STEP"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get dist-upgrade -y || true
    apt-get autoremove --purge -y || true
    mark "$STEP"
  fi
fi

echo
echo "=== SUMMARY ==="
echo "• OS now: $(os_id) ($(os_code))"
if dpkg -l | grep -q "^ii  ${OEM_META//./\\.}"; then
  echo "• Kernel meta: $OEM_META (installed)"
elif dpkg -l | grep -q "^ii  ${HWE_META//./\\.}"; then
  echo "• Kernel meta: $HWE_META (installed)"
else
  echo "• Kernel meta: (no OEM/HWE meta detected — check 'apt-cache policy $OEM_META $HWE_META')"
fi
echo "• Firmware updated via fwupd (if available)."
echo "• Dell OEM archive: $DELL_LINE"
echo "• IPU6 (MTL) stack: ${PKG_IPU6[*]}"
echo "• udev/tmpfiles/sysctl configured for camera access."
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
  echo "• Re-login recommended so '$SUDO_USER' picks up video/render groups."
fi
echo "All done. Re-run this script anytime; it will resume safely."
