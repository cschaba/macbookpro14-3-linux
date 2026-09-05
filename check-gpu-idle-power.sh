#!/usr/bin/env bash
#
# check-gpu-idle-power.sh — measure the discrete GPU's idle draw, and show why
#                           there is nothing here to tune
#
# READ THIS BEFORE YOU GO LOOKING FOR A WIN
#   The Radeon Pro 555 drives the internal panel (eDP-1 is on the amdgpu card;
#   the Intel iGPU has no eDP connector at all), so it can never runtime-
#   suspend. It costs about 7 W continuously. That is the floor, and no sysfs
#   setting moves it.
#
#   In particular, power_dpm_state does NOTHING on this chip:
#
#       # echo balanced > /sys/class/drm/card1/device/power_dpm_state
#       # cat /sys/class/drm/card1/device/power_dpm_state
#       performance
#
#   The write is accepted -- no error, exit status 0 -- and silently ignored.
#   It is a deprecated legacy interface. Any script that sets it and reports
#   success is lying to you, which is exactly what an earlier version of this
#   file did. Always read the value back.
#
# HOW THE WRONG ANSWER HAPPENED, SO YOU DO NOT REPEAT IT
#   A first pass measured five settings, one sample each, and produced a
#   convincing table: 9.07 W at the default, 7.48 W at "balanced", 2.6 W
#   apparently saved. All of it was noise. The desktop was busy and varying
#   underneath, and the same setting later read 9.07, 10.10 and 7.06 W at
#   different moments. The spread between repeats was larger than the effect.
#
#   With the desktop quiet, ten consecutive samples read 7.06 W with zero
#   variance, at every setting. There was never anything to save.
#
#   Two rules came out of it, and this script follows both:
#     - average several samples, never trust one
#     - read the value back after writing; an accepted write is not an
#       applied write
#
# WHAT WOULD ACTUALLY HELP
#   Only moving the panel to the Intel iGPU, which removes the ~7 W entirely.
#   That does not work on this machine -- see the README. Beyond that it is
#   physical: dust and eight-year-old thermal paste.
#
# Usage:
#   sudo ./check-gpu-idle-power.sh             current state and idle draw
#   sudo ./check-gpu-idle-power.sh --measure   A/B a setting, with read-back
#
set -uo pipefail

MODE=status
for a in "$@"; do
  case $a in
    --measure) MODE=measure ;;
    --help|-h) awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "$0"; exit 0 ;;
    *)         echo "unknown argument: $a (try --help)" >&2; exit 1 ;;
  esac
done

die() { printf 'check-gpu-idle-power: %s\n' "$*" >&2; exit 1; }

# Resolve the amdgpu card by DRIVER, never by card number: which card is 0 and
# which is 1 is not guaranteed across boots, and this repo has been bitten by
# that assumption twice already (ALSA card order, wiphy index).
amdgpu_dev() {
  local c d
  for c in /sys/class/drm/card[0-9]*; do
    d=$c/device
    [[ -e $d/uevent ]] || continue
    if awk -F= '/^DRIVER=/{ if ($2=="amdgpu") found=1 } END{ exit found?0:1 }' "$d/uevent"; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

DEV=$(amdgpu_dev) || die "no amdgpu device found (is the discrete GPU present?)"
ATTR=$DEV/power_dpm_state

read_power() { sensors 2>/dev/null | awk '/PPT/{print $2; exit}'; }
read_sclk()  { awk '/\*/{print $2}' "$DEV/pp_dpm_sclk" 2>/dev/null; }
read_temp()  { sensors 2>/dev/null | awk '/edge/{print $2; exit}'; }

# Six samples, one per second. A single reading catches whatever the compositor
# happened to be doing at that instant -- that is how the wrong answer above
# got made.
avg_power() {
  local i p sum=0 n=0
  for i in $(seq 1 6); do
    p=$(read_power); [[ -n $p ]] || continue
    sum=$(awk -v a="$sum" -v b="$p" 'BEGIN{print a+b}'); n=$((n+1))
    sleep 1
  done
  (( n > 0 )) || { echo "n/a"; return; }
  awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.2f", s/n}'
}

case $MODE in
  status)
    echo "=== current ==="
    echo "  device   : $DEV"
    echo "  dpm_state: $(cat "$ATTR" 2>/dev/null)  (deprecated; writes are ignored)"
    echo "  level    : $(cat "$DEV/power_dpm_force_performance_level" 2>/dev/null)"
    echo "  sclk     : $(read_sclk)"
    echo "  power    : $(read_power) W"
    echo "  temp     : $(read_temp)"
    echo
    echo "  ~7 W with sclk at its 214 MHz minimum is this machine's floor."
    echo "  It is the cost of the Radeon driving the panel. Nothing to tune."
    ;;

  measure)
    [[ $EUID -eq 0 ]] || die "run as root"
    orig=$(cat "$ATTR")
    echo "measuring '$orig' (6s)..."; before=$(avg_power)

    printf 'balanced' > "$ATTR" 2>/dev/null
    got=$(cat "$ATTR")
    if [[ $got != balanced ]]; then
      echo
      echo "  NOTE: wrote 'balanced', read back '$got'."
      echo "  The kernel accepted the write and ignored it. This is expected;"
      echo "  power_dpm_state is a deprecated interface. The comparison below"
      echo "  is therefore the same setting measured twice -- which is still"
      echo "  useful: it shows you the noise floor of the measurement."
    fi

    echo "measuring '$got' (6s)..."; after=$(avg_power)
    printf '%s' "$orig" > "$ATTR" 2>/dev/null
    echo
    printf "  %-14s %s W\n" "$orig" "$before"
    printf "  %-14s %s W\n" "$got" "$after"
    awk -v b="$before" -v a="$after" 'BEGIN{
      if (b=="n/a" || a=="n/a") { print "\n  (no PPT sensor reading available)"; exit }
      d=b-a; if (d<0) d=-d
      printf "\n  difference: %.2f W", d
      if (d < 0.5) print "  -- within noise; there is no saving here."
      else print "  -- larger than expected; re-run with the desktop idle."
    }'
    ;;
esac
