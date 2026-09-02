#!/usr/bin/env bash
#
# fix-touchpad-quirks.sh — palm rejection for the Apple SPI touchpad
#
# Run this ONLY if the pointer still jumps after the input.lua changes
# (sensitivity back to 0, adaptive accel, disable_while_typing = true).
#
# Background: this touchpad reports NO pressure axis. Verified from its ABS
# bitmask -- ABS_MT_TOUCH_MAJOR/MINOR and WIDTH_MAJOR/MINOR are present,
# ABS_PRESSURE and ABS_MT_PRESSURE are not. applespi's report_finger_data()
# simply never reports the pressure field the hardware sends. So every
# AttrPalmPressureThreshold / AttrPressureRange / AttrThumbPressureThreshold
# recipe you will find online is a NO-OP here. Only touch SIZE works.
#
# libinput already ships a matching section ([Apple Laptop Touchpad (SPI)
# applespi driver], MatchBus=spi MatchVendor=0x06CB) with generic thresholds
# inherited from the USB Apple touchpads. This tightens them.
#
# Usage:  sudo ./fix-touchpad-quirks.sh [--palm N] [--down N] [--up N]
#                                       [--measure] [--revert] [--dry-run]

set -euo pipefail

QUIRKS=/etc/libinput/local-overrides.quirks
DEV=$(grep -l 'Apple SPI Touchpad' /sys/class/input/event*/device/name 2>/dev/null | head -1 | sed 's|/sys/class/input/\(event[0-9]*\)/.*|/dev/input/\1|')
PALM=1000; DOWN=200; UP=170
DRY_RUN=0; MEASURE=0; REVERT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --palm) PALM="$2"; shift 2 ;;
    --down) DOWN="$2"; shift 2 ;;
    --up)   UP="$2";   shift 2 ;;
    --measure) MEASURE=1; shift ;;
    --revert)  REVERT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root (sudo $0)"
[[ -n "$DEV" ]] || die "could not locate the Apple SPI Touchpad device node"
echo "touchpad device: $DEV"
echo

if [[ $MEASURE -eq 1 ]]; then
  # Arch's libinput package no longer ships the `libinput measure` CLI, so fall
  # back to reading ABS_MT_TOUCH_MAJOR straight off the evdev node with evtest.
  if command -v libinput >/dev/null; then
    echo "Follow the prompts: press with a finger, then a thumb, then rest a palm."
    exec libinput measure touch-size --touch-thresholds "${DOWN}:${UP}" --palm-threshold "$PALM" "$DEV"
  fi
  command -v evtest >/dev/null || die "needs evtest:  sudo pacman -S evtest"

  sample() { # $1 = seconds, $2 = label
    local secs="$1" label="$2" out
    out=$(timeout "$secs" evtest "$DEV" 2>/dev/null \
          | awk '/ABS_MT_TOUCH_MAJOR/ {v=$NF+0; if (v>0) print v}' | sort -n)
    if [[ -z "$out" ]]; then
      echo "  $label: no touch-size data captured"
      return 1
    fi
    local n min med p95 max
    n=$(printf '%s\n' "$out" | wc -l)
    min=$(printf '%s\n' "$out" | head -1)
    max=$(printf '%s\n' "$out" | tail -1)
    med=$(printf '%s\n' "$out" | awk -v n="$n" 'NR==int(n/2)+1')
    p95=$(printf '%s\n' "$out" | awk -v n="$n" 'NR==int(n*0.95)+1')
    printf "  %-10s samples=%-5s min=%-5s median=%-5s p95=%-5s max=%s\n" \
           "$label:" "$n" "$min" "$med" "$p95" "$max"
    printf '%s' "$med" > "/tmp/.tpmeasure.$label"
    return 0
  }

  echo "Measuring ABS_MT_TOUCH_MAJOR. Two 8-second passes."
  echo
  read -r -p "1/2  FINGERTIP: press Enter, then move one fingertip around the pad. " _
  sample 8 finger || true
  echo
  read -r -p "2/2  PALM: press Enter, then rest your palm on the pad as when typing. " _
  sample 8 palm || true
  echo

  f=$(cat /tmp/.tpmeasure.finger 2>/dev/null || echo "")
  pm=$(cat /tmp/.tpmeasure.palm 2>/dev/null || echo "")
  rm -f /tmp/.tpmeasure.finger /tmp/.tpmeasure.palm
  if [[ -n "$f" && -n "$pm" ]]; then
    if [[ "$pm" -gt "$f" ]]; then
      suggested=$(( (f + pm) / 2 ))
      echo "  finger median $f, palm median $pm"
      echo "  Suggested:  sudo $0 --palm $suggested"
      echo "  (halfway between them; lower = more aggressive palm rejection)"
    else
      echo "  Palm ($pm) did not read larger than finger ($f)."
      echo "  Size-based rejection cannot separate them on this data - re-run and"
      echo "  make sure the palm pass really rests the heel of your hand on the pad."
    fi
  fi
  echo "  For reference, the system default is AttrPalmSizeThreshold=1600."
  exit 0
fi

if [[ -f "$QUIRKS" ]]; then
  BAK="$QUIRKS.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ $DRY_RUN -eq 0 ]]; then cp -a "$QUIRKS" "$BAK"; echo "backed up -> $BAK"; else echo "[dry-run] would back up -> $BAK"; fi
fi

if [[ $REVERT -eq 1 ]]; then
  LAST=$(ls -1t "$QUIRKS".bak.* 2>/dev/null | sed -n 2p || true)
  [[ -n "$LAST" ]] || die "no earlier backup to revert to"
  [[ $DRY_RUN -eq 0 ]] && cp -a "$LAST" "$QUIRKS"
  echo "reverted from $LAST -- log out and back in to apply"
  exit 0
fi

NEW=$(cat <<QEOF
# The stock [Apple Touchpad Override] that used to live here was dead:
#   MatchName=Apple Internal Keyboard / Trackpad   <- that is the USB bcm5974
#     name from pre-2016 MacBooks; this device is named "Apple SPI Touchpad"
#   AttrPalmPressureThreshold=150                  <- no pressure axis exists
# It matched nothing and did nothing. Replaced with a size-based section.

[Apple SPI Touchpad (applespi) local tuning]
MatchUdevType=touchpad
MatchBus=spi
MatchVendor=0x06CB
MatchProduct=0x06D7
MatchName=Apple SPI Touchpad
ModelAppleTouchpad=1
# down:up -- a touch counts as down at >= down, released at <= up.
# Raise 'down' to ignore light grazes and hover. libinput ships 150:130.
AttrTouchSizeRange=${DOWN}:${UP}
# At or above this size the contact is treated as a palm for its whole
# lifetime. LOWER is more aggressive. libinput ships 1600.
AttrPalmSizeThreshold=${PALM}
QEOF
)

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] would write $QUIRKS:"; echo "$NEW" | sed 's/^/    /'
else
  printf '%s\n' "$NEW" > "$QUIRKS"
  echo "wrote $QUIRKS"
fi
echo
echo "Verify the section actually matches:"
echo "  sudo libinput quirks list $DEV"
echo
echo "Then LOG OUT and back in -- libinput reads quirks at device init,"
echo "so 'hyprctl reload' will NOT pick this up."
echo
echo "Too aggressive (real taps ignored)? Raise --palm toward 1600."
echo "Not aggressive enough? Lower it, e.g. --palm 800."
echo "Undo entirely:  sudo $0 --revert"
