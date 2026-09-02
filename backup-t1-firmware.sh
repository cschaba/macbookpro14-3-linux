#!/usr/bin/env bash
#
# backup-t1-firmware.sh - archive the Apple T1 (iBridge) firmware from the ESP.
#
# The T1 has no boot ROM. Apple's EFI loads its OS image from
# EFI/APPLE/EMBEDDEDOS/ on the EFI system partition at every power-on. Wipe
# that partition and the Touch Bar, camera and Touch ID all go dead until
# macOS is made to re-download a device-personalised copy.
#
# The files are tied to this machine's ECID. They are worthless on another
# Mac and irreplaceable on this one. Keep a copy off this disk.
#
# Run as root:  sudo ./backup-t1-firmware.sh [--out DIR] [--restore ARCHIVE]
set -euo pipefail

ESP_MOUNT="/boot"
FW_SUBDIR="EFI/APPLE"
OUT_DIR="${SUDO_USER:+/home/$SUDO_USER}"
OUT_DIR="${OUT_DIR:-$PWD}"
RESTORE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT_DIR="$2"; shift 2 ;;
    --restore) RESTORE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root (it reads the ESP)." >&2
  exit 1
fi

if [[ -n "$RESTORE" ]]; then
  # --- restore path ---------------------------------------------------
  [[ -f "$RESTORE" ]] || { echo "No such archive: $RESTORE" >&2; exit 1; }
  echo "About to restore into ${ESP_MOUNT}/${FW_SUBDIR}"
  echo "Archive: $RESTORE"
  tar -tzf "$RESTORE" | head -20
  echo
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  tar -C "$ESP_MOUNT" -xzf "$RESTORE"
  sync
  echo "Restored. Power the machine fully off (not reboot) so Apple's EFI"
  echo "re-reads the firmware at the next cold boot."
  exit 0
fi

# --- backup path -------------------------------------------------------
FW_DIR="${ESP_MOUNT}/${FW_SUBDIR}/EMBEDDEDOS"

if [[ ! -d "$FW_DIR" ]]; then
  cat >&2 <<'MSG'
ERROR: no EFI/APPLE/EMBEDDEDOS directory on the ESP.

There is nothing to back up: the T1 firmware is absent. That is the state
that leaves the Touch Bar dark and /dev/video* missing. See the runbook
section "Recovery - the external SSD route".
MSG
  exit 1
fi

missing=0
for f in combined.memboot FDRData version.plist; do
  if [[ ! -s "$FW_DIR/$f" ]]; then
    echo "WARNING: $f is missing or empty" >&2
    missing=1
  fi
done
[[ $missing -eq 0 ]] || echo "Backing up anyway, but this set looks incomplete." >&2

VER="$(grep -A1 CFBundleShortVersionString "$FW_DIR/version.plist" 2>/dev/null \
        | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1)"
VER="${VER:-unknown}"

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown-model)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${OUT_DIR}/t1-firmware-${MODEL}-v${VER}-${STAMP}.tar.gz"

mkdir -p "$OUT_DIR"
tar -C "$ESP_MOUNT" -czf "$ARCHIVE" "$FW_SUBDIR"
sync

if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER" "$ARCHIVE" 2>/dev/null || true
fi
chmod 0600 "$ARCHIVE"

echo "Model            : $MODEL"
echo "iBridgeOS version: $VER"
echo "Archive          : $ARCHIVE"
echo "Size             : $(du -h "$ARCHIVE" | cut -f1)"
echo "SHA256           : $(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
echo
echo "Contents:"
tar -tzf "$ARCHIVE" | sed 's/^/  /'
echo
echo "NEXT: copy this file somewhere that is not this disk."
echo "Restore later with:  sudo $0 --restore $ARCHIVE"
