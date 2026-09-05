#!/usr/bin/env bash
#
# touchbar-fnmode.sh — switch the T1 Touch Bar layout to follow the focused app
#
# WHAT THIS CAN AND CANNOT DO
#   Read this first, because the limit is hardware, not effort.
#
#   The T1 Touch Bar has NO framebuffer and NO digitizer. The iBridge
#   coprocessor draws the bar itself from a fixed set of built-in layouts
#   baked into its firmware; the host only tells it WHICH layout to show, and
#   the bar reports back key codes, never coordinates. Verified on
#   MacBookPro14,3:
#
#     /sys/class/drm/                  card0 (i915), card1 (amdgpu). No bar.
#     Apple Inc. iBridge               capabilities/abs = 0   (no touch axes)
#     apple-ib-tb.c                    zero matches for drm|framebuffer|pixel
#
#   So the whole T2 ecosystem -- tiny-dfr, appletbdrm, appletb_backlight, and
#   every "themed Touch Bar" project built on them -- cannot work here. Those
#   need USB 05ac:8302 and a DRM device. The T1 is 05ac:8600 and has neither.
#
#   What IS available is the driver's fnmode attribute: four layouts, chosen
#   by writing one digit. That is the entire T1 API, and this script drives it
#   from Hyprland's focus events. Terminal gets F-keys, Spotify gets media
#   keys, and so on.
#
#   If you want per-app BUTTONS, GLYPHS or SLIDERS: not possible on T1. Not
#   with this script, not with any script. The pixels are not ours to set.
#
# Usage:
#   ./touchbar-fnmode.sh --status              what mode is set, and why
#   ./touchbar-fnmode.sh --set MODE            set once (name or 0-3)
#   ./touchbar-fnmode.sh --watch               follow the focused window
#   ./touchbar-fnmode.sh --which               print the focused window class
#   ./touchbar-fnmode.sh --match CLASS         test a config rule against a class
#   ./touchbar-fnmode.sh --install-udev        let your user write fnmode (sudo)
#   ./touchbar-fnmode.sh --install-service     systemd --user unit
#   ./touchbar-fnmode.sh --uninstall-service
#
# Requires: fix-touchbar-t1.sh already run (apple-ib-tb loaded and bound).
#
set -euo pipefail

CONFIG="${TOUCHBAR_FNMODE_CONFIG:-$HOME/.config/touchbar-fnmode.conf}"
UDEV_RULE=/etc/udev/rules.d/99-touchbar-fnmode.rules
UNIT="$HOME/.config/systemd/user/touchbar-fnmode.service"
PERM_GROUP=video   # you are already in it; 'input' would grant evdev-wide read

# The four layouts the T1 firmware knows. Names are ours; the digits are the
# driver's APPLETB_FN_MODE_* constants in apple-ib-tb.c.
declare -A MODES=(
  [fkeys]=0     # F1-F12 always
  [normal]=1    # media keys; hold fn for F-keys  (Apple default)
  [inverted]=2  # F-keys; hold fn for media keys
  [special]=3   # media/special keys only
)
declare -A MODE_NAME=([0]=fkeys [1]=normal [2]=inverted [3]=special)

die()  { printf 'touchbar-fnmode: %s\n' "$*" >&2; exit 1; }
warn() { printf 'touchbar-fnmode: %s\n' "$*" >&2; }

# --- locating the control node --------------------------------------------
# The HID instance suffix (.0003) is NOT stable: it increments every time the
# iBridge re-enumerates, which the handover helper does on every boot. Always
# resolve by glob, never cache the path across a failure.
fnmode_path() {
  local p
  for p in /sys/bus/hid/devices/*05AC:8600*/fnmode; do
    [[ -e $p ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

require_node() {
  local p
  p=$(fnmode_path) || die "no fnmode attribute found.
  The Touch Bar driver is not bound. Run ./fix-touchbar-t1.sh --verify.
  After a kernel update the modules must be rebuilt before this works."
  printf '%s' "$p"
}

read_mode()  { cat "$(require_node)"; }

write_mode() {
  local want=$1 path
  path=$(require_node)
  if ! printf '%s' "$want" > "$path" 2>/dev/null; then
    die "cannot write $path
  Run: $0 --install-udev
  (that grants group '$PERM_GROUP' write access; you are already a member)"
  fi
}

resolve_mode() {  # accepts a name or a digit, echoes a digit
  local m=${1,,}
  if [[ -n ${MODES[$m]:-} ]]; then printf '%s' "${MODES[$m]}"; return 0; fi
  if [[ $m =~ ^[0-3]$ ]]; then printf '%s' "$m"; return 0; fi
  die "unknown mode '$1' (use: ${!MODES[*]} or 0-3)"
}

# --- config ----------------------------------------------------------------
# Lines are:  <regex matching the window class> = <mode>
# plus one    default = <mode>
# First match wins, so put specific rules above general ones.
write_default_config() {
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<'EOC'
# touchbar-fnmode.conf — which Touch Bar layout each app gets.
#
# Syntax:   <bash regex against the window class> = <mode>
# Modes:    fkeys     F1-F12 always
#           normal    media keys, hold fn for F-keys   (Apple default)
#           inverted  F-keys, hold fn for media keys
#           special   media/special keys only
#
# First match wins. Find a window's class with:  ./touchbar-fnmode.sh --which

# Everything behaves like macOS: media keys on the bar, hold fn for F1-F12.
default = normal

# Per-app overrides are OFF by default, because "normal" already gives you
# F-keys on demand via fn and a bar that never changes under you is easier to
# live with than one that does. Uncomment a line to opt in.
#
# Note that "special" ignores fn entirely -- there is no way back to F-keys
# while it is active.

# Terminals and editors: F-keys at rest, hold fn for media.
#^(Alacritty|com\.mitchellh\.ghostty|kitty|foot|org\.wezfurlong\.wezterm)$ = inverted
#^(neovide|Emacs|jetbrains-.*|code|codium)$                                   = inverted

# Media players: transport controls only.
#^(Spotify|mpv|vlc|io\.bassi\.Amberol|org\.gnome\.Rhythmbox3)$ = special
EOC
  echo "wrote $CONFIG"
}

mode_for_class() {
  local cls=$1 line key val fallback=1
  [[ -f $CONFIG ]] || { printf '1'; return 0; }
  while IFS= read -r line; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    key=${line%%=*}; val=${line#*=}
    key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z $key || -z $val ]] && continue
    if [[ $key == default ]]; then
      fallback=$(resolve_mode "$val"); continue
    fi
    if [[ $cls =~ $key ]]; then resolve_mode "$val"; return 0; fi
  done < "$CONFIG"
  printf '%s' "$fallback"
}

# --- talking to Hyprland ---------------------------------------------------
# systemd --user starts with a clean environment, so HYPRLAND_INSTANCE_SIGNATURE
# is NOT set there and a bare hyprctl call fails with "is hyprland running?".
# Recover it from the runtime directory instead of assuming the variable.
runtime_dir() { printf '%s' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; }

hypr_sig() {
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    printf '%s' "$HYPRLAND_INSTANCE_SIGNATURE"; return 0
  fi
  local dirs=() b
  mapfile -t dirs < <(ls -d "$(runtime_dir)"/hypr/*/ 2>/dev/null)
  (( ${#dirs[@]} == 1 )) || return 1   # zero, or ambiguous: caller decides
  b=${dirs[0]%/}
  printf '%s' "${b##*/}"
}

hypr_socket() {
  local sig; sig=$(hypr_sig) || return 1
  printf '%s' "$(runtime_dir)/hypr/${sig}/.socket2.sock"
}

focused_class() {
  local sig; sig=$(hypr_sig) || return 1
  HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl activewindow 2>/dev/null \
    | awk '/^[[:space:]]*class:/{print $2; exit}'
}

# socat is the clean way to read a unix socket line-by-line; python3 covers
# the case where it is not installed. Bash itself cannot open unix sockets.
stream_events() {
  local sock=$1
  if command -v socat >/dev/null 2>&1; then
    socat -u "UNIX-CONNECT:$sock" -
  elif command -v python3 >/dev/null 2>&1; then
    python3 -u -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
f=s.makefile("r", encoding="utf-8", errors="replace")
for line in f: sys.stdout.write(line)' "$sock"
  else
    die "need socat or python3 to read Hyprland events"
  fi
}

apply_for_class() {
  local cls=$1 want cur
  [[ -z $cls ]] && return 0
  want=$(mode_for_class "$cls")
  cur=$(read_mode 2>/dev/null) || return 0
  # Only write on change: every write wakes the iBridge over USB.
  [[ $want == "$cur" ]] && return 0
  write_mode "$want"
  printf '%s  %-28s -> %s\n' "$(date '+%T')" "$cls" "${MODE_NAME[$want]}"
}

do_watch() {
  local sock cls line
  [[ -f $CONFIG ]] || write_default_config
  require_node >/dev/null

  while :; do
    if ! sock=$(hypr_socket) || [[ ! -S $sock ]]; then
      warn "waiting for Hyprland socket..."; sleep 5; continue
    fi
    apply_for_class "$(focused_class)"   # sync up on (re)connect
    # Process substitution, not a pipe: a pipeline here would put the loop in
    # a subshell and tangle with pipefail if socat dies.
    while IFS= read -r line; do
      case $line in
        activewindow'>>'*)
          cls=${line#activewindow>>}; cls=${cls%%,*}
          apply_for_class "$cls" ;;
      esac
    done < <(stream_events "$sock")
    warn "event stream closed; reconnecting in 3s"
    sleep 3
  done
}

# --- installers ------------------------------------------------------------
install_udev() {
  [[ $EUID -eq 0 ]] && die "run this WITHOUT sudo; it calls sudo itself"
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOR
# Let the desktop user pick the Touch Bar layout without root.
#
# fnmode is created by apple-ib-tb when it binds, which can be after the HID
# 'add' event, so this matches every non-remove action (bind included).
# Group '$PERM_GROUP' rather than 'input': membership of 'input' would grant
# read access to every evdev node on the machine, which is a keylogger.
ACTION!="remove", SUBSYSTEM=="hid", KERNEL=="0003:05AC:8600.*", \\
  RUN+="/bin/sh -c '/usr/bin/chgrp $PERM_GROUP /sys\$devpath/fnmode 2>/dev/null; /usr/bin/chmod 0664 /sys\$devpath/fnmode 2>/dev/null'"
EOR
  sudo install -m 0644 "$tmp" "$UDEV_RULE"
  rm -f "$tmp"
  sudo udevadm control --reload
  # Apply now as well: the bind event for the running driver already fired.
  local p; p=$(require_node)
  sudo chgrp "$PERM_GROUP" "$p"
  sudo chmod 0664 "$p"
  echo "installed $UDEV_RULE"
  ls -l "$p"
  id -nG | tr ' ' '\n' | awk -v g="$PERM_GROUP" '$0==g{f=1} END{
    if (!f) print "WARNING: you are not in group " g "; run: sudo usermod -aG " g " $USER"
  }'
}

install_service() {
  [[ -f $CONFIG ]] || write_default_config
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOU
[Unit]
Description=T1 Touch Bar layout follows the focused window
Documentation=https://github.com/cschaba/macbookpro14-3-linux
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$(readlink -f "$0") --watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOU
  systemctl --user daemon-reload
  systemctl --user enable --now touchbar-fnmode.service
  echo "installed and started $UNIT"
  echo "  status: systemctl --user status touchbar-fnmode"
  echo "  log:    journalctl --user -u touchbar-fnmode -f"
}

uninstall_service() {
  systemctl --user disable --now touchbar-fnmode.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl --user daemon-reload
  echo "removed $UNIT"
  echo "the udev rule, if installed, is still at $UDEV_RULE"
}

do_status() {
  local p cur cls want
  p=$(require_node)
  cur=$(cat "$p")
  cls=$(focused_class || true)
  echo "  node:      $p"
  echo "  writable:  $( [[ -w $p ]] && echo yes || echo "no  (run --install-udev)" )"
  echo "  mode:      $cur = ${MODE_NAME[$cur]:-?}"
  if [[ -f $CONFIG ]]; then echo "  config:    $CONFIG"
  else echo "  config:    $CONFIG  (missing, everything gets 'normal')"; fi
  if [[ -n $cls ]]; then
    want=$(mode_for_class "$cls")
    echo "  focused:   $cls -> ${MODE_NAME[$want]}"
  fi
  echo
  echo "  layouts:   fkeys=0  normal=1  inverted=2  special=3"
  echo "  service:   $(systemctl --user is-active touchbar-fnmode 2>/dev/null || true)"
}

# --- dispatch --------------------------------------------------------------
case ${1:---status} in
  --status)            do_status ;;
  --set)               [[ $# -ge 2 ]] || die "--set needs a mode"
                       m=$(resolve_mode "$2"); write_mode "$m"
                       echo "mode -> $m (${MODE_NAME[$m]})" ;;
  --watch)             do_watch ;;
  --which)             focused_class || echo "(no focused window)" ;;
  --match)             [[ $# -ge 2 ]] || die "--match needs a window class"
                       m=$(mode_for_class "$2")
                       printf '%-30s -> %s (%s)\n' "$2" "${MODE_NAME[$m]}" "$m" ;;
  --write-config)      write_default_config ;;
  --install-udev)      install_udev ;;
  --install-service)   install_service ;;
  --uninstall-service) uninstall_service ;;
  # Print the header comment, however long it grows -- a hardcoded line
  # range silently starts printing code the moment the header is edited.
  --help|-h)           awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "$0" ;;
  *)                   die "unknown option '$1' (try --help)" ;;
esac
