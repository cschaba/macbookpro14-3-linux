#!/usr/bin/env bash
#
# fix-gpu-idle-power.sh — stop the Radeon holding its voltage rail high at idle
#
# THE PROBLEM
#   The Radeon Pro 555 drives the internal panel on this machine (eDP-1 lives
#   on the amdgpu card, and the Intel iGPU has no eDP connector at all), so it
#   can never runtime-suspend. It idles at its lowest clock, 214 MHz, but
#   amdgpu's default power_dpm_state of "performance" keeps the voltage rail
#   up anyway. That costs about 2.6 W of pure heat, continuously.
#
# MEASURED ON A MacBookPro14,3, GPU otherwise idle:
#
#     setting                          sclk      power     temp
#     auto + performance (default)     214 MHz   9.07 W    46 C
#     power_dpm_state = battery        782 MHz  10.23 W    47 C   <- worse!
#     power_dpm_state = balanced       214 MHz   7.48 W    46 C   <- this
#     level = low                      214 MHz   7.14 W    46 C
#     manual + POWER_SAVING            214 MHz   7.06 W    45 C
#
#   Note "battery" is the WORST setting on the list -- it raised the clock to
#   782 MHz. Do not assume the power-sounding name is the low-power one.
#
#   "balanced" is chosen here because it keeps power_dpm_force_performance_level
#   at "auto", so the GPU still ramps up properly for real work. The two lower
#   entries buy another 0.4 W and give that up.
#
# WHAT THIS CANNOT DO
#   The remaining ~7 W is the cost of the Radeon being powered at all. Only
#   moving the panel to the Intel iGPU removes that, and on this machine that
#   is not possible at runtime: i915 never probes an eDP connector, because
#   the firmware hands the panel to the Radeon before the kernel starts. A
#   vga_switcheroo switch to IGD therefore gives you a live panel with no DRM
#   connector to drive it -- a black screen. Tested. The mux is not persistent,
#   so a reboot recovers, but there is nothing here worth chasing.
#
# Usage:
#   sudo ./fix-gpu-idle-power.sh              show current state
#   sudo ./fix-gpu-idle-power.sh --apply      set balanced now
#   sudo ./fix-gpu-idle-power.sh --measure    before/after power comparison
#   sudo ./fix-gpu-idle-power.sh --install    apply at every boot (systemd)
#   sudo ./fix-gpu-idle-power.sh --uninstall
#   sudo ./fix-gpu-idle-power.sh --revert     back to "performance"
#
set -uo pipefail

WANT=balanced
UNIT=/etc/systemd/system/gpu-idle-power.service
MODE=status

for a in "$@"; do
  case $a in
    --apply)     MODE=apply ;;
    --revert)    MODE=revert ;;
    --measure)   MODE=measure ;;
    --install)   MODE=install ;;
    --uninstall) MODE=uninstall ;;
    --help|-h)   awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "$0"; exit 0 ;;
    *)           echo "unknown argument: $a (try --help)" >&2; exit 1 ;;
  esac
done

die() { printf 'fix-gpu-idle-power: %s\n' "$*" >&2; exit 1; }

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
[[ -e $ATTR ]] || die "$ATTR does not exist"

read_power() { sensors 2>/dev/null | awk '/PPT/{print $2; exit}'; }
read_sclk()  { awk '/\*/{print $2}' "$DEV/pp_dpm_sclk" 2>/dev/null; }
read_temp()  { sensors 2>/dev/null | awk '/edge/{print $2; exit}'; }

show() {
  echo "  device   : $DEV"
  echo "  dpm_state: $(cat "$ATTR")"
  echo "  level    : $(cat "$DEV/power_dpm_force_performance_level" 2>/dev/null)"
  echo "  sclk     : $(read_sclk)"
  echo "  power    : $(read_power) W"
  echo "  temp     : $(read_temp)"
  if [[ -f $UNIT ]]; then
    echo "  at boot  : $(systemctl is-enabled gpu-idle-power 2>/dev/null) ($UNIT)"
  else
    echo "  at boot  : not installed (setting is lost on reboot)"
  fi
}

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

set_state() {
  need_root
  printf '%s' "$1" > "$ATTR" 2>/dev/null || die "cannot write $ATTR"
  echo "power_dpm_state -> $(cat "$ATTR")"
}

# Average the power reading; a single sample catches whatever the compositor
# happened to be doing. This is the mistake that made the first diagnosis of
# this problem wrong -- the measuring loop itself was waking the GPU.
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
  status)  echo "=== current ==="; show ;;

  apply)   set_state "$WANT" ;;

  revert)  set_state performance ;;

  measure)
    need_root
    orig=$(cat "$ATTR")
    echo "measuring '$orig' (6s)..."; before=$(avg_power)
    printf '%s' "$WANT" > "$ATTR" 2>/dev/null || die "cannot write $ATTR"
    echo "measuring '$WANT' (6s)..."; after=$(avg_power)
    printf '%s' "$orig" > "$ATTR"
    echo
    printf "  %-14s %s W\n" "$orig" "$before"
    printf "  %-14s %s W\n" "$WANT" "$after"
    awk -v b="$before" -v a="$after" 'BEGIN{
      if (b=="n/a" || a=="n/a") { print "\n  (no PPT sensor reading available)"; exit }
      printf "\n  saving: %.2f W (%.0f%%)\n", b-a, 100*(b-a)/b }'
    echo "  (restored to '$orig'; use --apply or --install to keep it)"
    ;;

  install)
    need_root
    cat > "$UNIT" <<EOU
[Unit]
Description=Lower the discrete Radeon's idle voltage rail (MacBookPro14,3)
Documentation=https://github.com/cschaba/macbookpro14-3-linux
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Resolved by driver at run time, not by card number.
ExecStart=$(readlink -f "$0") --apply

[Install]
WantedBy=multi-user.target
EOU
    systemctl daemon-reload
    systemctl enable --now gpu-idle-power.service
    echo "installed $UNIT"
    echo
    show
    ;;

  uninstall)
    need_root
    systemctl disable --now gpu-idle-power.service 2>/dev/null
    rm -f "$UNIT"
    systemctl daemon-reload
    echo "removed $UNIT (current setting left as-is; --revert to undo)"
    ;;
esac
