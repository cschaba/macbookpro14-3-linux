#!/usr/bin/env bash
#
# remove-t2-cruft.sh — remove Apple T2-only packages from a T1 MacBook Pro
#
# This machine is a MacBookPro14,3 (2017, Apple T1 "iBridge" chip). The T2
# package set installed on it targets 2018+ T2 Macs and does nothing here:
#
#   linux-t2 / linux-t2-headers  T2-patched kernel; you boot mainline `linux`
#   tiny-dfr                     Touch Bar daemon for T2 Macs (T1 needs apple-ibridge)
#   t2fanrd                      T2 fan daemon; crash-looping "Error: Fan not found"
#   apple-t2-audio-config        ALSA UCM profiles that only match a card named "AppleT2"
#   apple-bcm-firmware           BCM4377/4378/4387 blobs; this machine has a BCM43602
#
# Usage:  sudo ./remove-t2-cruft.sh [--with-headers] [--dry-run]
#
#   --with-headers  also run `pacman -Syu --needed linux-headers` so DKMS modules
#                   (e.g. the apple-ibridge Touch Bar driver) can build. This does
#                   a full system upgrade, which is the correct thing on Arch but
#                   is a bigger change -- omit the flag to skip it.
#   --keep-kernel   leave linux-t2 / linux-t2-headers installed and only remove the
#                   userspace T2 cruft. Use this if you want to keep the T2 kernel as
#                   a bootable fallback while you work through the other fixes.
#   --dry-run       print what would happen, change nothing.

set -euo pipefail

WITH_HEADERS=0
KEEP_KERNEL=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --with-headers) WITH_HEADERS=1 ;;
    --keep-kernel)  KEEP_KERNEL=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '  + %s\n' "$*"
    "$@"
  fi
}

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
echo "== Preflight checks =="

[[ $EUID -eq 0 ]] || die "must run as root (sudo $0)"

MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
echo "  model:           $MODEL"
case "$MODEL" in
  MacBookPro1[0-4],*|MacBook[0-9],*|MacBookAir[0-7],*|iMac1[0-8],*|Macmini[0-7],*)
    : ;;   # pre-T2 hardware, safe
  *)
    die "expected pre-T2 Apple hardware, got '$MODEL'. If this really is a T1-or-older
       Mac, edit the case statement above. Do NOT run this on a T2 Mac (2018+):
       those genuinely need linux-t2, apple-bce, tiny-dfr and apple-bcm-firmware." ;;
esac

# The T2 chip presents a bridge/NHI device; refuse if one is present.
# awk rather than grep -q: see the SIGPIPE/pipefail note in fix-wifi-nvram.sh.
# This guard silently passed with grep -q, which defeated the whole check.
if lspci -nn 2>/dev/null | awk 'tolower($0) ~ /106b:1801/{f=1} END{exit f?0:1}'; then
  die "an Apple T2 bridge device was detected on the PCI bus -- aborting."
fi

RUNNING=$(uname -r)
echo "  running kernel:  $RUNNING"
OWNER=$(pacman -Qoq "/usr/lib/modules/$RUNNING/vmlinuz" 2>/dev/null || true)
echo "  provided by:     ${OWNER:-<unknown>}"
[[ "$OWNER" == "linux" ]] || die "the running kernel is not provided by the mainline 'linux'
       package (got '${OWNER:-none}'). Boot the mainline kernel first, otherwise
       removing linux-t2 would delete the kernel you are currently running."

pacman -Q linux >/dev/null 2>&1 || die "the mainline 'linux' package is not installed."

echo "  OK -- safe to proceed."
echo

# ------------------------------------------------------------------ backup --
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/t2-removal-$STAMP"
echo "== Recording current state to $BACKUP =="
if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$BACKUP"
  pacman -Qe > "$BACKUP/explicit-packages.txt"
  cp -a /boot/limine.conf "$BACKUP/limine.conf" 2>/dev/null || true
  systemctl list-unit-files --no-pager > "$BACKUP/unit-files.txt" 2>/dev/null || true
  echo "  saved package list, limine.conf and unit state"
else
  echo "  [dry-run] would save package list, limine.conf and unit state"
fi
echo

# ----------------------------------------------------------------- services --
echo "== Stopping and disabling T2 services =="
for unit in t2fanrd.service tiny-dfr.service; do
  if systemctl list-unit-files "$unit" --no-pager 2>/dev/null \
     | awk -v u="$unit" 'index($0, u){f=1} END{exit f?0:1}'; then
    run systemctl disable --now "$unit" || true
    run systemctl reset-failed "$unit" || true
  else
    echo "  - $unit not present, skipping"
  fi
done
echo

# ------------------------------------------------------------ header swap --
if [[ $WITH_HEADERS -eq 1 ]]; then
  echo "== Installing mainline linux-headers (full system upgrade) =="
  run pacman -Syu --needed --noconfirm linux-headers
  echo
fi

# ----------------------------------------------------------------- removal --
echo "== Removing T2-only packages =="
T2_PKGS=(tiny-dfr t2fanrd apple-t2-audio-config apple-bcm-firmware)

if [[ $KEEP_KERNEL -eq 1 ]]; then
  echo "  --keep-kernel: leaving linux-t2 and linux-t2-headers installed"
elif pacman -Qq linux-headers >/dev/null 2>&1; then
  T2_PKGS+=(linux-t2 linux-t2-headers)
else
  # linux-t2-headers is currently the ONLY kernel headers package on this system.
  # Dropping it without installing linux-headers leaves DKMS with nothing to build
  # against, which blocks the Touch Bar and audio drivers.
  echo "  WARNING: 'linux-headers' is not installed, so linux-t2-headers is the only"
  echo "           kernel-headers package present. Removing it would leave DKMS unable"
  echo "           to build anything. Keeping the T2 kernel and headers for now."
  echo "           Re-run with --with-headers to install linux-headers and remove both."
  KEEP_KERNEL=1
fi

TO_REMOVE=()
for p in "${T2_PKGS[@]}"; do
  if pacman -Qq "$p" >/dev/null 2>&1; then
    TO_REMOVE+=("$p")
  else
    echo "  - $p not installed, skipping"
  fi
done

if [[ ${#TO_REMOVE[@]} -eq 0 ]]; then
  echo "  nothing to remove."
else
  echo "  removing: ${TO_REMOVE[*]}"
  # -R  remove   -n  don't keep configs   -s  also drop now-orphaned deps
  #     (-s never removes explicitly-installed packages, so this is conservative)
  run pacman -Rns --noconfirm "${TO_REMOVE[@]}"
fi
echo

# -------------------------------------------------------------- bootloader --
echo "== Refreshing limine boot entries =="
# The limine pacman hooks already regenerate entries on kernel removal;
# this is a belt-and-braces re-run.
if command -v limine-update >/dev/null 2>&1; then
  run limine-update || echo "  (limine-update returned non-zero; check /boot/limine.conf by hand)"
else
  echo "  limine-update not found, skipping"
fi
echo

# ------------------------------------------------------------------ report --
echo "== Done =="
echo
echo "Remaining Apple/T2-related packages:"
pacman -Q 2>/dev/null | grep -Ei 't2|tiny-dfr|apple|bce' | sed 's/^/  /' || echo "  (none)"
echo
echo "Boot entries now in /boot/limine.conf:"
grep -E 'Kernel version|kernel-id' /boot/limine.conf 2>/dev/null | sort -u | sed 's/^/  /' || true
echo
echo "State backup: $BACKUP"
echo "To undo the package removal:"
if [[ $KEEP_KERNEL -eq 0 ]]; then
  echo "  pacman -S linux-t2 linux-t2-headers apple-t2-audio-config   # repo"
else
  echo "  pacman -S apple-t2-audio-config                             # repo"
fi
echo "  yay -S tiny-dfr t2fanrd apple-bcm-firmware                  # AUR"
echo
echo "NOTE: the kernel cmdline keeps 'apple_ib_tb.fnmode=1'. That parameter belongs"
echo "      to the *T1* apple-ibridge driver, not to tiny-dfr, so it is correct to"
echo "      leave it in place for the Touch Bar work."
