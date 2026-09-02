#!/usr/bin/env bash
#
# fix-audio-cs8409.sh — working audio on a MacBookPro14,x (Cirrus CS8409)
#
# Problem: mainline's snd-hda-codec-cs8409 has NO Apple support. Its quirk table
# (sound/hda/codecs/cirrus/cs8409-tables.c) contains only Dell subsystem IDs
# (0x1028*). This machine is 0x106b3900, so no fixup matches and the driver falls
# through to the generic HDA parser. The generic path never runs the I2C init for
# the CS42L83 sub-codec (headphones + headset mic) and never writes the vendor
# coefficients that bring the external I2S speaker amps out of shutdown. Result:
# a bare 'PCM' mixer control, no Master/Speaker/Headphone, and silence.
#
# Fix: davidjo/snd_hda_macbookpro, which carries
#   SND_PCI_QUIRK(0x106b, 0x3900, "MacBookPro 14,3", CS8409_MBP143)
#
# Second, independent bug this also clears: WirePlumber pins an output-only
# 'analog-surround-21' card profile, which leaves the machine with NO capture
# source at all. That is why the mic is dead even at the ALSA level.
#
# Usage:  ./fix-audio-cs8409.sh [--verify] [--reset-profile-only] [--dry-run]
#
# Run as your NORMAL USER, not root -- AUR builds refuse to run as root.
# It calls sudo itself where it needs to.

set -euo pipefail

DRY_RUN=0
VERIFY_ONLY=0
PROFILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --verify)              VERIFY_ONLY=1 ;;
    --reset-profile-only)  PROFILE_ONLY=1 ;;
    --dry-run)             DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

run() { if [[ $DRY_RUN -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else printf '  + %s\n' "$*"; "$@"; fi; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

report_state() {
  echo "  codec driver loaded: $(lsmod | awk '$1=="snd_hda_codec_cs8409"{f=1} END{print f?"yes":"no"}')"
  # Ask modprobe which file it would actually load, rather than picking the
  # first match off the filesystem - both the stock in-tree module and the DKMS
  # one exist, and updates/dkms wins only because depmod says so.
  local ko marker
  ko=$(modinfo -n snd_hda_codec_cs8409 2>/dev/null)
  [[ -n "$ko" ]] || ko=$(find "/usr/lib/modules/$(uname -r)/updates" -name 'snd-hda-codec-cs8409.ko*' 2>/dev/null | head -1)
  echo "  module modprobe would load:"
  echo "                       ${ko:-<none found>}"
  echo "  Apple quirk in module:"
  if [[ -n "$ko" && -f "$ko" ]]; then
    # davidjo's build exposes the Apple codepath as cs_8409_apple_* symbols and
    # a cirrus_apple.h reference. It does NOT contain the literal "MacBookPro",
    # so do not test for that - it gives a false negative on a good install.
    marker=$({ case "$ko" in *.zst) zstd -dc "$ko";; *) cat "$ko";; esac; } 2>/dev/null \
            | strings | grep -ciE 'cs_8409_apple|cs8409_apple|cirrus_apple')
    if [[ ${marker:-0} -gt 0 ]]; then
      echo "                       YES - patched driver is installed ($marker Apple symbols)"
    else
      echo "                       no  - stock mainline driver (this is the bug)"
    fi
  else
    echo "                       <module not found>"
  fi
  echo "  loaded module is:    $(cat /sys/module/snd_hda_codec_cs8409/srcversion 2>/dev/null | sed 's/^/srcversion /' || echo '<not loaded>')"
  # Card 0 is the ATI HDMI codec on this machine, NOT the analog one. Hardcoding
  # card 0 reports the HDMI card's IEC958 (S/PDIF) controls and makes a perfectly
  # working analog card look broken. Find the CS8409 by codec name instead.
  local cs_card cs_id
  cs_card=""
  for f in /proc/asound/card*/codec#*; do
    [[ -r "$f" ]] || continue
    if head -1 "$f" 2>/dev/null | /usr/bin/grep -qi 'CS8409'; then
      cs_card=$(printf '%s' "$f" | sed -n 's|.*/card\([0-9]\+\)/.*|\1|p')
      break
    fi
  done
  if [[ -n "$cs_card" ]]; then
    cs_id=$(cat "/proc/asound/card$cs_card/id" 2>/dev/null)
    echo "  CS8409 ALSA card:    card $cs_card [$cs_id]"
    echo "  playback device:     $(aplay -l 2>/dev/null | awk -v c="card $cs_card:" '$0 ~ c {print; exit}')"
    echo "  mixer controls:      $(amixer -c "$cs_card" scontrols 2>/dev/null \
        | sed -e "s/Simple mixer control //" -e "s/'//g" | paste -sd", " -)"
  else
    echo "  CS8409 ALSA card:    <not present - codec did not attach>"
    echo "  mixer controls:      <none>"
  fi
  # Report every card's profile, labelled; the analog one is what matters. The
  # old code took the first "Active Profile" line, which was the HDMI card.
  echo "  card profiles:"
  pactl list cards 2>/dev/null \
    | awk '/^\tName: /{n=$2} /Active Profile:/{sub(/^[^:]*: /,""); printf "                       %-34s %s\n", n, $0}'
  echo "  default sink:        $(pactl get-default-sink 2>/dev/null)"
  echo "  sink volume/mute:    $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | sed 's/.*\/ *\([0-9]*%\).*/\1/') / $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | sed 's/Mute: //')"
  echo "  sources:             $(pactl list sources short 2>/dev/null | awk '!/monitor/{n++} END{print n+0}') non-monitor"
  # The CS8409's hardware playback stage is NOT driven by PipeWire's slider on
  # this driver, and it can sit far below 0 dB. That is heard as "audio works
  # but is very quiet" with a volume control that never gets loud enough.
  if [[ -n "${cs_card:-}" ]]; then
    local pcm db
    pcm=$(amixer -c "$cs_card" sget PCM 2>/dev/null | tail -2 | head -1 | sed 's/.*Playback //')
    if [[ -n "$pcm" ]]; then
      echo "  hardware PCM gain:   $pcm"
      db=$(printf '%s' "$pcm" | sed -n 's/.*\[\(-\?[0-9.]*\)dB\].*/\1/p')
      if [[ -n "$db" ]] && awk -v d="$db" 'BEGIN{exit !(d < -20)}'; then
        echo "                       ^ well below 0 dB - this is why it sounds quiet."
        echo "                         raise it:  amixer -c $cs_card sset PCM 90%"
        echo "                         persist:   sudo alsactl store"
      fi
    fi
  fi
  echo "  pinned profile file: $( [[ -f ~/.local/state/wireplumber/default-profile ]] && cat ~/.local/state/wireplumber/default-profile | tr '\n' ' ' || echo '<none>' )"
}

echo "== Current audio state =="
report_state
echo
[[ $VERIFY_ONLY -eq 1 ]] && {
  echo "Working looks like: Apple quirk YES, a CS8409 ALSA card with a PCM control,"
  echo "an analog-stereo profile active on the pci-0000_00_1f.3 card, an unmuted"
  echo "sink,"
  echo "and at least one non-monitor source."
  exit 0
}

[[ $EUID -ne 0 ]] || die "do NOT run this as root - makepkg/yay refuse to build as root.
       Run it as your normal user; it calls sudo where needed."

# ------------------------------------------------- reset WirePlumber state --
reset_profile() {
  echo "== Clearing pinned WirePlumber profile =="
  local d="$HOME/.local/state/wireplumber"
  if [[ -d "$d" ]]; then
    run systemctl --user stop wireplumber pipewire pipewire-pulse || true
    for f in default-profile default-routes default-nodes; do
      [[ -f "$d/$f" ]] && run mv "$d/$f" "$d/$f.bak.$(date +%Y%m%d-%H%M%S)"
    done
    run systemctl --user start pipewire pipewire-pulse wireplumber || true
    [[ $DRY_RUN -eq 0 ]] && sleep 2
  else
    echo "  no wireplumber state dir, nothing to clear"
  fi
  echo
}

if [[ $PROFILE_ONLY -eq 1 ]]; then
  reset_profile
  echo "== New state =="
  report_state
  exit 0
fi

# ---------------------------------------------------------------- preflight --
echo "== Preflight =="
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
echo "  model: $MODEL"
case "$MODEL" in
  MacBookPro14,*|MacBookPro13,*) : ;;
  *) die "this driver targets MacBookPro13,x/14,x. Got '$MODEL'.
       Check the quirk table in patch_cirrus/cirrus_apple.h before forcing it." ;;
esac

KREL=$(uname -r)
if [[ ! -e "/usr/lib/modules/$KREL/build" ]]; then
  die "no kernel headers for the RUNNING kernel ($KREL).
       /usr/lib/modules/$KREL/build does not exist, so DKMS cannot build anything.
       Fix first:   sudo pacman -Syu linux-headers
       If you just upgraded the kernel, REBOOT first so the running kernel and
       the installed headers match, then re-run this script."
fi
echo "  headers OK: /usr/lib/modules/$KREL/build"
command -v yay >/dev/null || die "yay not found (needed for the AUR package)"
echo

# ------------------------------------------------------------------ install --
echo "== Installing the patched CS8409 driver =="
echo "  Trying the AUR package first; falling back to an upstream build."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  [dry-run] would: yay -S --needed snd-hda-macbookpro-dkms-git"
else
  if yay -S --needed --noconfirm snd-hda-macbookpro-dkms-git; then
    echo "  AUR package installed."
  else
    echo
    echo "  AUR package failed. Falling back to a direct upstream install."
    BUILD=$(mktemp -d)
    git clone --depth 1 https://github.com/davidjo/snd_hda_macbookpro.git "$BUILD/src"
    ( cd "$BUILD/src" && sudo ./install.cirrus.driver.sh -i ) \
      || die "upstream install failed. Read the output above; the installer needs
       to fetch kernel sources matching $KREL and that is the usual failure."
    echo "  built from $BUILD/src (left in place for inspection)"
  fi
fi
echo

reset_profile

# ------------------------------------------------------------------- finish --
echo "== Done =="
echo
echo "REBOOT NOW. The codec driver cannot be swapped cleanly on a live system."
echo
echo "After rebooting, verify with:"
echo "  ./fix-audio-cs8409.sh --verify"
echo
echo "You should see Master / Speaker / Headphone controls appear. If the card is"
echo "still on a surround profile:"
echo "  pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:analog-stereo+input:analog-stereo"
echo
echo "If sound works but is far too quiet, the hardware gain stage is the cause, not
a limiter. PipeWire's slider does not drive it on this driver:
  amixer -c 1 sset PCM 90%     # then find the highest level that stays clean
  sudo alsactl store           # persist across reboots

The headset-mic capture switch ships off; enable it if you use one:"
echo "  amixer -c 0 sset 'Mic' cap"
echo
echo "WARNING from upstream: raw ALSA devices (hw:0,0 / plughw:0,0) have NO volume"
echo "control and play at full output. Test through PipeWire, not speaker-test on hw:0,0."
