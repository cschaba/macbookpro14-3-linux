#!/usr/bin/env bash
#
# diagnose-key-chatter.sh — is it a failing switch, or just key repeat?
#
# These look identical when typing but have completely different fixes:
#
#   COMPOSITOR REPEAT  one press, then the compositor repeats it.
#                      Fixed by repeat_delay / repeat_rate (already reset to
#                      Hyprland's defaults 600 / 25 in ~/.config/hypr/input.lua).
#
#   HARDWARE CHATTER   the switch physically bounces, emitting genuine separate
#                      press/release pairs milliseconds apart. NO compositor
#                      setting can suppress this -- libinput deliberately does
#                      not debounce keyboards ("must be implemented higher in
#                      the stack"), and Wayland has no AccessX/BounceKeys.
#                      Needs evdev-layer filtering.
#
# Usage:  sudo ./diagnose-key-chatter.sh [seconds]     (default 20)

set -euo pipefail
SECS="${1:-20}"

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
command -v evtest >/dev/null || { echo "ERROR: needs evtest:  pacman -S evtest" >&2; exit 1; }

KBD=$(grep -l 'Apple SPI Keyboard' /sys/class/input/event*/device/name 2>/dev/null | head -1 | sed 's|/sys/class/input/\(event[0-9]*\)/.*|/dev/input/\1|')
[[ -n "$KBD" ]] || { echo "ERROR: could not find the Apple SPI Keyboard" >&2; exit 1; }

echo "Recording $KBD for ${SECS}s."
echo "Type the key that doubles, repeatedly and at normal speed. Go."
echo

LOG=$(mktemp)
timeout "$SECS" evtest "$KBD" > "$LOG" 2>/dev/null || true

echo "== Analysis =="
awk '
  /EV_KEY/ && /value 1/ { split($3,t,","); now=t[1]+0
    if (key[$(NF-2)] && (now-key[$(NF-2)])<0.060)
      printf "  CHATTER: %s repressed after %.1f ms\n", $(NF-2), (now-key[$(NF-2)])*1000
    key[$(NF-2)]=now }
  /EV_KEY/ && /value 2/ { rep++ }
  END { printf "\n  autorepeat events seen: %d\n", rep+0 }
' "$LOG" | sed 's/^/ /'

echo
if grep -q 'value 2' "$LOG"; then
  echo "  Autorepeat (value 2) present -- but libinput discards these and Wayland"
  echo "  regenerates repeat client-side, so they are not what you see on screen."
fi
echo "  VERDICT:"
echo "    Any 'CHATTER' lines above (re-press within 60 ms of the previous"
echo "    press, with a release in between) => failing switch. Fix below."
echo "    No CHATTER lines, doubles still seen => compositor repeat; the"
echo "    input.lua defaults should already have fixed it."
echo
echo "  Raw capture kept at: $LOG"
echo
cat <<'HINT'
  If it IS chatter, the only working route is evdev-layer filtering:

    sudo pacman -S interception-tools          # official repo
    cargo install debouncer-udevmon            # not packaged anywhere
    sudo install -m755 ~/.cargo/bin/debouncer-udevmon /usr/local/bin/

    /etc/interception/udevmon.d/debounce.yaml:
      - JOB: "intercept -g $DEVNODE | /usr/local/bin/debouncer-udevmon | uinput -d $DEVNODE"
        DEVICE:
          NAME: "Apple SPI Keyboard"

    /etc/debouncer.toml:
      debounce_time = 25   # SEE "CHOOSING debounce_time" BELOW
      # never delay modifiers: LEFTCTRL LEFTSHIFT RIGHTSHIFT LEFTALT RIGHTCTRL RIGHTALT LEFTMETA
      exceptions = [29, 42, 54, 56, 97, 100, 125]

    sudo systemctl enable --now udevmon.service

  CHOOSING debounce_time: it must be LARGER than the longest interval reported
  above, or the chatter passes straight through. Classic switch bounce is
  5-30 ms, but a degrading butterfly switch produces longer gaps -- 52 ms was
  measured on this machine, which the stock 25 ms would have missed entirely.
  Take your worst measured value and add ~10 ms.

  The cost: any deliberate same-key double-tap faster than debounce_time is
  swallowed. Real double letters (letter, sleep, book) usually land 80-150 ms
  apart, so 60-70 ms is normally safe -- but that is close enough to warrant
  testing before you trust it.

  SAFETY: this grabs your only keyboard. Have a USB keyboard plugged in the
  first time, so a typo in the YAML cannot lock you out.

  Note: keyd, kmonad and evremap all LACK a chatter filter -- do not reach for
  them here. And understand the ceiling: this is the 2nd-gen butterfly defect.
  Apple's repair programme closed in Nov 2024. Debounce masks a switch that
  will keep degrading; a top-case replacement or external keyboard is the cure.
HINT
