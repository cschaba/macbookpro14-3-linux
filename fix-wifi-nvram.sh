#!/usr/bin/env bash
#
# fix-wifi-nvram.sh — restore 5 GHz on the BCM43602 in a MacBookPro14,x
#
# Problem: linux-firmware ships only brcmfmac43602-pcie.bin, never the per-board
# NVRAM calibration file. Without it the firmware falls back to defaults: the
# 5 GHz band is not registered with cfg80211 at all (`iw phy` shows Band 1 only),
# HT40 is unavailable, the TX power table is uncalibrated, and the interface
# comes up with Broadcom's placeholder MAC 00:90:4c:xx:xx:xx.
#
# This installs the NVRAM file and restores the real Apple MAC from EFI.
#
# Usage:  sudo ./fix-wifi-nvram.sh [--file PATH] [--dry-run] [--verify]
#
#   --file PATH   use a local NVRAM file instead of downloading one
#   --verify      just report current state and exit
#   --dry-run     show what would happen, change nothing
#
# LICENSING - READ THIS BEFORE USING THE DEFAULT DOWNLOAD
#
# This NVRAM file is **Broadcom-proprietary**. It originates from Apple's
# Windows (Boot Camp) driver package, and that is precisely why it is NOT in
# linux-firmware: nobody has established the right to redistribute it.
#
# This script does not ship the file. By default it downloads a copy from an
# *unmerged* Omarchy pull request (basecamp/omarchy#7487), pinned to one commit
# and checksum-verified. That PR's author flagged the licensing question openly
# and left the decision to the maintainers; at the time of writing it is still
# open, so treat that copy as convenience, not as a licensed distribution.
#   https://github.com/basecamp/omarchy/pull/7487
#
# Using this calibration data on a Mac you own - hardware Apple shipped it for -
# is a very different act from redistributing it. If you want to stay clear of
# the third-party copy entirely, extract the file from your own machine's Boot
# Camp driver package or macOS install and pass it with --file. That route
# involves no third-party redistribution at all.
#
# Do not commit the resulting file to a public repository.

set -euo pipefail

NVRAM_URL='https://raw.githubusercontent.com/basecamp/omarchy/eb8c83e8b5f7931e883adcada3f8eab38f650a93/default/firmware/apple/brcmfmac43602-pcie.txt'
NVRAM_SHA='9111375d9552d096cd05ca2ee705e7866882d3bb81372df33b40813bd3a47117'
FW_DIR='/usr/lib/firmware/brcm'
ROM_VAR='/sys/firmware/efi/efivars/ROM-4d1ede05-38c7-4a6a-9cc6-4bcca8b38c14'

SRC_FILE=''
DRY_RUN=0
VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    SRC_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verify)  VERIFY_ONLY=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

run() { if [[ $DRY_RUN -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else printf '  + %s\n' "$*"; "$@"; fi; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

WIFI_IF=$(ls /sys/class/net/ | grep -E '^wl' | head -1 || true)

# The wiphy index is NOT stable: reloading brcmfmac increments it (phy0 -> phy1
# -> ...). Hardcoding phy0 makes a working 5 GHz radio report "0 bands". Always
# resolve the phy from the interface.
wifi_phy() {
  [[ -n "${WIFI_IF:-}" ]] || return 1
  cat "/sys/class/net/$WIFI_IF/phy80211/name" 2>/dev/null
}

report_state() {
  local phy bands
  phy=$(wifi_phy || true)
  echo "  interface:   ${WIFI_IF:-<none found>}"
  echo "  phy:         ${phy:-<none found>}"
  [[ -n "${WIFI_IF:-}" ]] && echo "  MAC:         $(cat "/sys/class/net/$WIFI_IF/address" 2>/dev/null)"
  echo "  NVRAM file:  $(ls "$FW_DIR"/brcmfmac43602-pcie*.txt 2>/dev/null | tr '\n' ' ' || echo '<none installed>')"
  if [[ -n "$phy" ]]; then
    bands=$(iw phy "$phy" info 2>/dev/null | awk '/^[[:space:]]+Band [0-9]+:/{n++} END{print n+0}')
    echo "  bands:       $bands registered$( [[ $bands -ge 2 ]] && echo '  <- 5 GHz present' )"
    iw phy "$phy" info 2>/dev/null | awk '/^[[:space:]]+Band [0-9]+:/{print "              " $0}'
  else
    echo "  bands:       <no phy>"
  fi
  if [[ -n "${WIFI_IF:-}" ]]; then
    echo "  link:"
    iw dev "$WIFI_IF" link 2>/dev/null | sed -n '2,6p' | sed 's/^/               /'
  fi
}

echo "== Current state =="
report_state
echo

if [[ $VERIFY_ONLY -eq 1 ]]; then
  echo "Band 2 present means 5 GHz is available. MAC should NOT start with 00:90:4c."
  echo "(A MAC whose first octet has bit 2 set, e.g. 26:.., is NetworkManager"
  echo " randomisation during reassociation - re-check after it settles.)"
  exit 0
fi

# ---------------------------------------------------------------- preflight --
[[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || die "must run as root (sudo $0)"

MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)
echo "== Preflight =="
echo "  model:  $VENDOR / $MODEL"
# NB: awk, not "grep -q". Under `set -o pipefail`, grep -q exits on the first
# match, the producer dies of SIGPIPE (141), and pipefail turns a SUCCESSFUL
# match into a failed pipeline. awk reads all input and exits cleanly.
lspci -nn 2>/dev/null | awk '/14e4:43ba/{f=1} END{exit f?0:1}' \
  || die "no BCM43602 [14e4:43ba] found on the PCI bus. This script is only for that chip."
echo "  BCM43602 present."
echo

# ------------------------------------------------------------ recover MAC --
echo "== Recovering the real Apple MAC from EFI =="
REAL_MAC=''
if [[ -r "$ROM_VAR" ]]; then
  # efivars carry a 4-byte attribute header; the MAC is the next 6 bytes.
  # od, not xxd: xxd ships with vim and is absent on a minimal Arch install,
  # where it failed with exit 127 and silently took the fallback path below.
  REAL_MAC=$(od -An -tx1 -j4 -N6 "$ROM_VAR" 2>/dev/null \
             | tr -d ' \n' | sed 's/../&:/g; s/:$//' || true)
fi
if [[ "$REAL_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && "$REAL_MAC" != "00:00:00:00:00:00" ]]; then
  echo "  found: $REAL_MAC"
else
  echo "  could not read a sane MAC from EFI (got '${REAL_MAC:-nothing}')."
  echo "  The macaddr= line will be REMOVED from the NVRAM instead, which lets the"
  echo "  driver keep using the address it already has. This is the safe fallback."
  REAL_MAC=''
fi
echo

# -------------------------------------------------------------- obtain file --
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "== Obtaining NVRAM =="
if [[ -n "$SRC_FILE" ]]; then
  [[ -r "$SRC_FILE" ]] || die "cannot read --file '$SRC_FILE'"
  cp "$SRC_FILE" "$TMP/nvram.txt"
  echo "  using local file: $SRC_FILE"
  echo "  sha256: $(sha256sum "$TMP/nvram.txt" | cut -d' ' -f1)  (not verified - you supplied it)"
else
  echo "  downloading from basecamp/omarchy PR #7487 (pinned commit)"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would curl $NVRAM_URL"
  else
    curl -fsSL "$NVRAM_URL" -o "$TMP/nvram.txt" || die "download failed"
    GOT=$(sha256sum "$TMP/nvram.txt" | cut -d' ' -f1)
    [[ "$GOT" == "$NVRAM_SHA" ]] || die "checksum mismatch!
       expected $NVRAM_SHA
       got      $GOT
       Refusing to install. The pinned file may have changed - re-check the PR."
    echo "  checksum verified: $GOT"
  fi
fi
echo

# ------------------------------------------------------------- patch macaddr --
if [[ $DRY_RUN -eq 0 ]]; then
  echo "== Setting macaddr =="
  if [[ -n "$REAL_MAC" ]]; then
    if grep -q '^macaddr=' "$TMP/nvram.txt"; then
      sed -i "s/^macaddr=.*/macaddr=$REAL_MAC/" "$TMP/nvram.txt"
    else
      printf 'macaddr=%s\n' "$REAL_MAC" >> "$TMP/nvram.txt"
    fi
    echo "  macaddr=$REAL_MAC"
  else
    sed -i '/^macaddr=/d' "$TMP/nvram.txt"
    echo "  macaddr line removed (no reliable MAC available)"
  fi
  echo
fi

# ----------------------------------------------------------------- install --
echo "== Installing =="
# brcmfmac tries the DMI-specific name first, then the generic one. The DMI name
# legitimately contains spaces (sys_vendor is "Apple Inc."); linux-firmware ships
# such names too, e.g. "brcmfmac43241b4-sdio.Intel Corp.-VALLEYVIEW C0 PLATFORM.txt".
# Both paths below are quoted, so this is correct - do not "fix" it.
DMI_NAME="brcmfmac43602-pcie.${VENDOR}-${MODEL}.txt"
for f in "brcmfmac43602-pcie.txt" "$DMI_NAME"; do
  if [[ -e "$FW_DIR/$f" ]]; then
    run cp -a "$FW_DIR/$f" "$FW_DIR/$f.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  run install -m0644 "$TMP/nvram.txt" "$FW_DIR/$f"
done
echo

# ------------------------------------------------------------------ reload --
echo "== Reloading brcmfmac =="
echo "  (this drops the Wi-Fi connection for a few seconds)"
run modprobe -r brcmfmac_wcc || true
run modprobe -r brcmfmac || true
run modprobe brcmfmac
[[ $DRY_RUN -eq 0 ]] && sleep 4
echo

echo "== New state =="
WIFI_IF=$(ls /sys/class/net/ | grep -E '^wl' | head -1 || true)
# NetworkManager assigns a randomised locally-administered MAC while the
# interface reassociates, so an immediate read shows the wrong address. Wait for
# the real one (or give up after ~15s and report whatever is there).
for _ in $(seq 15); do
  mac=$(cat "/sys/class/net/${WIFI_IF:-none}/address" 2>/dev/null || true)
  [[ -n "$mac" && "$mac" != "00:90:4c:"* && $(( 0x${mac%%:*} & 2 )) -eq 0 ]] && break
  sleep 1
done

report_state
echo
echo "Expected: 'Band 2' now listed, and the MAC no longer starting 00:90:4c."
echo "If Band 2 is still missing, reboot once - a live reload does not always"
echo "re-run the firmware's channel-list setup."
echo
echo "Then prefer 5 GHz on your network (replace <name> with your connection):"
echo "  nmcli -g NAME,TYPE connection show | grep wireless"
echo "  nmcli connection modify <name> 802-11-wireless.band a"
echo "  nmcli connection up <name>"
echo "  iw dev ${WIFI_IF:-wlp3s0} link      # expect freq 5xxx, width 80MHz"
echo
echo "Note: 'no clm_blob available' in dmesg is EXPECTED and stays. Broadcom"
echo "never licensed that file for redistribution; the NVRAM alone restores 5 GHz."
