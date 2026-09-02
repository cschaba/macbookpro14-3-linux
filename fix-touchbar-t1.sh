#!/usr/bin/env bash
#
# fix-touchbar-t1.sh - build and load the Apple T1 (iBridge) Touch Bar driver.
#
# Mainline Linux has Touch Bar drivers, but they are T2-only:
#   appletbdrm        usb:v05ACp8302   (2018+ MacBook Pro)
#   hid-appletb-kbd   ...p00008302
#   hid-appletb-bl    ...p00008102
# A T1 Touch Bar is 05ac:8600 and matches none of them, which is why the
# panel stays dark even with the firmware present and the device enumerating.
#
# The only T1 driver is Ronald Tschalaer's out-of-tree trio -
# apple-ibridge / apple-ib-tb / apple-ib-als - shipped as source by the
# macbook12-spi-driver-dkms package.
#
# This script deliberately does NOT build that package's applespi module.
# applespi has been in mainline since 5.3, the in-tree copy is driving your
# keyboard and touchpad right now, and a DKMS build would shadow it from
# /lib/modules/<kver>/updates/. Only the three iBridge modules are built.
#
# LICENSING: this repository is MIT, but the kernel-compat patch block below
# embeds short excerpts of, and replacements for, code from
# apple-ibridge.c / apple-ib-tb.c / apple-ib-als.c, which are
# SPDX-License-Identifier: GPL-2.0, Copyright (c) 2017-2018 Ronald Tschalar.
# That patch content is therefore offered under GPL-2.0, not MIT. The rest of
# this script is original work under MIT. No driver source is redistributed
# here - it is read from the copy already installed on your own machine and
# patched in a temporary directory at build time.
#
# Run as root:
#   sudo ./fix-touchbar-t1.sh [--verify] [--fork] [--dry-run] [--revert]
#
# --fork builds from a fork maintained for current kernels instead of the
#        2018 source shipped by the distro package.
set -euo pipefail

SRC_DIR="$(ls -d /usr/src/macbook12-spi-driver-* 2>/dev/null | sort -V | tail -1 || true)"
KVER="$(uname -r)"
INSTALL_DIR="/lib/modules/${KVER}/updates/macbook12-spi-driver"
MODULES=(apple-ibridge apple-ib-tb apple-ib-als)
IBRIDGE_USB="1-3"
FORK_URL="https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver"
DRY=0; VERIFY=0; REVERT=0; USE_FORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --verify)  VERIFY=1; shift ;;
    --revert)  REVERT=1; shift ;;
    --fork)    USE_FORK=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

run() { if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

find_ibridge() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    if [[ "$(cat "$d/idVendor")" == "05ac" && "$(cat "$d/idProduct")" == "8600" ]]; then
      basename "$d"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- verify ---
if [[ $VERIFY -eq 1 ]]; then
  echo "=== T1 firmware on the ESP ==="
  if [[ -d /boot/EFI/APPLE/EMBEDDEDOS ]]; then
    ls -l /boot/EFI/APPLE/EMBEDDEDOS/ | sed 's/^/  /'
  else
    echo "  ABSENT - Touch Bar cannot work. Firmware must be restored first."
  fi

  echo
  echo "=== iBridge USB device ==="
  if dev="$(find_ibridge)"; then
    cfg="$(cat "/sys/bus/usb/devices/$dev/bConfigurationValue" 2>/dev/null)"
    nif="$(cat "/sys/bus/usb/devices/$dev/bNumInterfaces" 2>/dev/null)"
    echo "  found at $dev (05ac:8600 - firmware is loaded)"
    echo "  bConfigurationValue: ${cfg:-<unconfigured>}"
    echo "  bNumInterfaces     : ${nif:-<none>}"
    [[ -z "${cfg// }" ]] && echo "  NOTE: device is unconfigured - no interfaces are exposed."
  elif lsusb 2>/dev/null | awk '/05ac:1281/{f=1} END{exit f?0:1}'; then
    echo "  05ac:1281 (Recovery Mode) - firmware is MISSING, not just undriven."
  else
    echo "  no Apple iBridge on the USB bus."
  fi

  echo
  echo "=== driver modules ==="
  for m in "${MODULES[@]}"; do
    u="${m//-/_}"
    loaded="$(lsmod | awk -v n="$u" '$1==n{f=1} END{print f?"loaded":"not loaded"}')"
    built="not built"
    [[ -f "${INSTALL_DIR}/${m}.ko" || -f "${INSTALL_DIR}/${m}.ko.zst" ]] && built="built"
    modinfo "$u" >/dev/null 2>&1 && built="$built, resolvable by modprobe"
    printf "  %-16s %s (%s)\n" "$m" "$loaded" "$built"
  done

  echo
  echo "=== which driver holds each iBridge HID interface ==="
  echo "  (the Touch Bar collection is the 634-byte descriptor)"
  found=0
  for d in /sys/bus/hid/devices/*05AC:8600*; do
    [[ -e "$d" ]] || continue
    found=1
    sz="$(wc -c < "$d/report_descriptor" 2>/dev/null || echo '?')"
    printf "  %-24s %5s bytes -> %s\n" "$(basename "$d")" "$sz" \
      "$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo '<none>')"
  done
  [[ $found -eq 1 ]] || echo "  (no iBridge HID interfaces present)"

  echo
  echo "=== camera and ALS ==="
  ls /dev/video* >/dev/null 2>&1 && echo "  camera: $(ls /dev/video* | tr '\n' ' ')" \
                                 || echo "  camera: no /dev/video* (is the iBridge configured?)"
  if [[ -e /sys/bus/iio/devices/iio:device0/name ]]; then
    echo "  ALS   : iio:device0 ($(cat /sys/bus/iio/devices/iio:device0/name))"
  else
    echo "  ALS   : none"
  fi

  echo
  echo "=== kernel headers ==="
  if [[ -d "/lib/modules/${KVER}/build" ]]; then
    echo "  present for running kernel ${KVER}"
  else
    echo "  MISSING for running kernel ${KVER}"
  fi
  echo "  running kernel : ${KVER}"
  echo "  linux package  : $(pacman -Q linux 2>/dev/null | awk '{print $2}')"
  exit 0
fi

# ---------------------------------------------------------------- revert ---
if [[ $REVERT -eq 1 ]]; then
  for m in apple-ib-tb apple-ib-als apple-ibridge; do
    run modprobe -r "${m//-/_}" 2>/dev/null || true
  done
  run rm -rf "$INSTALL_DIR"
  run systemctl disable --now apple-ibridge.service 2>/dev/null || true
  run rm -f /etc/systemd/system/apple-ibridge.service
  run rm -f /usr/local/bin/apple-ibridge-handover
  run rm -f /etc/modules-load.d/apple-ibridge.conf
  run systemctl daemon-reload 2>/dev/null || true
  run depmod -a "$KVER"

  echo "Reverted. The mainline in-tree applespi was never touched."
  exit 0
fi

# -------------------------------------------------------------- preflight ---
if [[ $EUID -ne 0 && $DRY -eq 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

echo "== preflight =="

if [[ $USE_FORK -eq 1 ]]; then
  # The packaged source was last touched upstream in 2018. This fork is
  # maintained by a MacBookPro14,3 owner and tracks current kernels.
  command -v git >/dev/null || { echo "ERROR: git is not installed." >&2; exit 1; }
  SRC_DIR="$(mktemp -d /tmp/ibridge-fork.XXXXXX)"
  echo "  cloning $FORK_URL"
  if ! git clone --depth 1 "$FORK_URL" "$SRC_DIR" >/dev/null 2>&1; then
    echo "ERROR: clone failed. Check network, or drop --fork to build the" >&2
    echo "       packaged 2018 source instead." >&2
    exit 1
  fi
  # The fork keeps sources in a subdirectory on some branches.
  if [[ ! -f "$SRC_DIR/apple-ib-tb.c" ]]; then
    found="$(find "$SRC_DIR" -name apple-ib-tb.c -printf '%h\n' 2>/dev/null | head -1)"
    [[ -n "$found" ]] && SRC_DIR="$found"
  fi
fi

if [[ -z "$SRC_DIR" || ! -f "$SRC_DIR/apple-ib-tb.c" ]]; then
  cat >&2 <<'MSG'
ERROR: driver source not found under /usr/src/macbook12-spi-driver-*.
Install it with:  sudo pacman -S --needed macbook12-spi-driver-dkms
(or: yay -S macbook12-spi-driver-dkms)
Or pass --fork to build from the maintained fork instead.
MSG
  exit 1
fi
echo "  source: $SRC_DIR"

if [[ ! -d /boot/EFI/APPLE/EMBEDDEDOS ]]; then
  cat >&2 <<'MSG'

ERROR: no T1 firmware at /boot/EFI/APPLE/EMBEDDEDOS.

Without it the T1 never boots, the Touch Bar has no display to drive, and
this driver has nothing to talk to. Restore the firmware first.
MSG
  exit 1
fi
echo "  T1 firmware: present"

if ! find_ibridge >/dev/null; then
  if lsusb 2>/dev/null | awk '/05ac:1281/{f=1} END{exit f?0:1}'; then
    echo "ERROR: iBridge is in Recovery Mode (05ac:1281) - firmware not loading." >&2
  else
    echo "ERROR: no Apple iBridge (05ac:8600) on the USB bus." >&2
  fi
  exit 1
fi
IBRIDGE_USB="$(find_ibridge)"
echo "  iBridge: 05ac:8600 at $IBRIDGE_USB"

# apple-ibridge is an ACPI driver (alias acpi*:APP7777:*), not a USB one. It
# binds to this node and only then registers its HID drivers.
if [[ -d /sys/bus/acpi/devices/APP7777:00 ]]; then
  echo "  ACPI node APP7777:00: present"
else
  echo "  WARNING: no ACPI node APP7777:00 - apple-ibridge will build but never probe." >&2
fi

PKG_KVER="$(pacman -Q linux 2>/dev/null | awk '{print $2}' | sed 's/\.arch/-arch/')"
if [[ ! -d "/lib/modules/${KVER}/build" ]]; then
  cat >&2 <<MSG

ERROR: no kernel headers for the running kernel.
  running kernel : ${KVER}
  linux package  : ${PKG_KVER:-unknown}
  missing        : /lib/modules/${KVER}/build

If those two versions differ, the running kernel is an orphan left over from
an update. Installing linux-headers now would give you headers for the NEW
kernel, which cannot build modules for the running one.

  1. reboot                     (into the kernel the linux package provides)
  2. sudo pacman -S linux-headers
  3. re-run this script
MSG
  exit 1
fi
echo "  headers: present for $KVER"
echo

# ------------------------------------------------------------------ build ---
BUILD_DIR="$(mktemp -d /tmp/ibridge-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "== build =="
cp "$SRC_DIR"/*.c "$SRC_DIR"/*.h "$BUILD_DIR"/ 2>/dev/null || true
rm -f "$BUILD_DIR"/applespi.c "$BUILD_DIR"/applespi.h "$BUILD_DIR"/applespi_trace.h

# Only the three iBridge modules. applespi is intentionally excluded so the
# working in-tree driver keeps handling the keyboard and touchpad.
cat > "$BUILD_DIR/Makefile" <<'MK'
obj-m += apple-ibridge.o
obj-m += apple-ib-tb.o
obj-m += apple-ib-als.o
MK

# The 2018 sources predate several kernel API changes. These edits are applied
# to the temporary copy only - /usr/src is never modified, so a package update
# cleanly replaces the original. Each edit is idempotent and reports whether it
# fired, was already current, or could not find its anchor; a missing anchor is
# a warning rather than a failure, since a newer upstream may already carry it.
cat > "$BUILD_DIR/compat.py" <<'PYEOF'
import sys, os

d = sys.argv[1]
changed, skipped, missing = [], [], []

def edit(fname, old, new, label, done_marker=None):
    p = os.path.join(d, fname)
    if not os.path.exists(p):
        missing.append(f"{fname}: {label} (file not present)"); return
    s = open(p).read()
    if done_marker and done_marker in s:
        skipped.append(f"{fname}: {label} (already current)"); return
    if old not in s:
        missing.append(f"{fname}: {label} (anchor not found)"); return
    open(p, 'w').write(s.replace(old, new, 1))
    changed.append(f"{fname}: {label}")

# hid_driver.report_fixup returns const __u8 * (constified in 6.13)
edit("apple-ibridge.c",
     "static __u8 *appleib_report_fixup(struct hid_device *hdev, __u8 *rdesc,",
     "static const __u8 *appleib_report_fixup(struct hid_device *hdev, __u8 *rdesc,",
     "report_fixup returns const __u8 *",
     done_marker="static const __u8 *appleib_report_fixup")

# struct acpi_driver lost its .owner member
edit("apple-ibridge.c",
     "\t.class\t\t= \"topcase\", /* ? */\n\t.owner\t\t= THIS_MODULE,\n",
     "\t.class\t\t= \"topcase\", /* ? */\n",
     "drop acpi_driver.owner")

# platform_driver.remove returns void (converted in 6.11)
for f, drv, cleanup in (
    ("apple-ib-tb.c",  "appletb",  "appletb_free_device(tb_dev);"),
    ("apple-ib-als.c", "appleals", "kfree(als_dev);"),
):
    edit(f,
         f"static int {drv}_platform_remove(struct platform_device *pdev)",
         f"static void {drv}_platform_remove(struct platform_device *pdev)",
         "platform remove returns void",
         done_marker=f"static void {drv}_platform_remove")
    edit(f,
         f"\t{cleanup}\n\n\treturn 0;\n\nerror:\n\treturn rc;\n}}",
         f"\t{cleanup}\n\n\treturn;\n\nerror:\n\tdev_err(&pdev->dev,\n\t\t\"Failed to unregister hid driver: %d\\n\", rc);\n}}",
         "platform remove error path")

for x in changed: print(f"  patched  {x}")
for x in skipped: print(f"  skipped  {x}")
for x in missing: print(f"  WARNING  {x}")
PYEOF

echo "  applying kernel-compat patches"
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] python3 compat.py $BUILD_DIR"
else
  python3 "$BUILD_DIR/compat.py" "$BUILD_DIR"
fi
rm -f "$BUILD_DIR/compat.py"

echo "  building apple-ibridge, apple-ib-tb, apple-ib-als against $KVER"
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] make -C /lib/modules/$KVER/build M=$BUILD_DIR modules"
else
  LOG="$BUILD_DIR/build.log"
  if ! make -C "/lib/modules/${KVER}/build" M="$BUILD_DIR" modules >"$LOG" 2>&1; then
    KEEP="/tmp/ibridge-build-failed.log"
    cp "$LOG" "$KEEP" 2>/dev/null || true
    cat >&2 <<MSG

BUILD FAILED.

This driver was last touched upstream in 2018. Kernel ${KVER} is far newer,
and the HID and IIO interfaces it uses have changed since. A build failure
here is a realistic outcome, not a mistake in your setup.

First 40 lines of the first errors:
MSG
    grep -E 'error:|warning: implicit' "$LOG" | head -40 | sed 's/^/  /' >&2
    echo >&2
    echo "Full log kept at: $KEEP" >&2
    echo >&2
    echo "Next thing to try: a fork that has been updated for current kernels," >&2
    echo "e.g. the apple-ibridge patches carried by the t2linux community." >&2
    exit 1
  fi
  echo "  build OK"
fi
echo

# ---------------------------------------------------------------- install ---
echo "== install =="
run mkdir -p "$INSTALL_DIR"
for m in "${MODULES[@]}"; do
  if [[ $DRY -eq 1 ]]; then
    echo "  [dry-run] install $m.ko -> $INSTALL_DIR/"
  else
    install -m 0644 "$BUILD_DIR/$m.ko" "$INSTALL_DIR/$m.ko"
    echo "  installed $m.ko"
  fi
done
run depmod -a "$KVER"

# hid-sensor-hub matches the iBridge's sensor collection and, depending on load
# order, wins the interface that actually carries the Touch Bar. On this machine
# that interface has a 634-byte report descriptor - the exact size
# appleib_report_fixup() tests for - while the one apple-ibridge is left with is
# an 83-byte boot keyboard. Hand every iBridge HID interface to apple-ibridge-hid.
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] install /usr/local/bin/apple-ibridge-handover"
else
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/apple-ibridge-handover <<'HELPER'
#!/usr/bin/env bash
# Bring the Apple iBridge into a usable state:
#   1. make sure it is configured and exposing all four interfaces
#   2. give every iBridge HID interface to apple-ibridge-hid
# Safe to run repeatedly; it does nothing when the state is already correct.
set -u
TARGET=/sys/bus/hid/drivers/apple-ibridge-hid
[[ -d $TARGET ]] || { echo "apple-ibridge-hid not loaded" >&2; exit 1; }

# --- 1. configuration -----------------------------------------------------
# At cold boot the T1 has been seen exposing only its two HID interfaces; the
# two UVC (camera) interfaces appear only after a re-enumeration. It also drops
# to configuration 0 within a couple of minutes when no driver claims it. Both
# are fixed by unbinding and rebinding the USB device - but only do that when
# something is actually wrong, so an in-use camera is never yanked.
usbdev=""
for d in /sys/bus/usb/devices/*; do
  [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
  [[ "$(cat "$d/idVendor")" == "05ac" && "$(cat "$d/idProduct")" == "8600" ]] || continue
  usbdev="$(basename "$d")"; break
done

if [[ -n $usbdev ]]; then
  cfg="$(cat "/sys/bus/usb/devices/$usbdev/bConfigurationValue" 2>/dev/null || true)"
  nif="$(cat "/sys/bus/usb/devices/$usbdev/bNumInterfaces" 2>/dev/null || true)"
  cfg="${cfg// /}"; nif="${nif// /}"
  if [[ -z $cfg || $cfg == 0 || -z $nif || $nif -lt 4 ]]; then
    echo "iBridge at $usbdev: config='${cfg:-none}' interfaces='${nif:-none}' - re-enumerating"
    printf '%s' "$usbdev" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
    sleep 1
    printf '%s' "$usbdev" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
    sleep 2
  fi
fi

moved=0
for dev in /sys/bus/hid/devices/*05AC:8600*; do
  [[ -e $dev ]] || continue
  id=$(basename "$dev")
  cur=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null)
  [[ $cur == apple-ibridge-hid ]] && continue
  if [[ -n $cur && -w /sys/bus/hid/drivers/$cur/unbind ]]; then
    printf '%s' "$id" > "/sys/bus/hid/drivers/$cur/unbind" 2>/dev/null || true
  fi
  if printf '%s' "$id" > "$TARGET/bind" 2>/dev/null; then
    echo "handed $id from ${cur:-<none>} to apple-ibridge-hid"
    moved=$((moved + 1))
  else
    echo "could not bind $id to apple-ibridge-hid" >&2
  fi
done
exit 0
HELPER
  chmod 0755 /usr/local/bin/apple-ibridge-handover
  echo "  installed /usr/local/bin/apple-ibridge-handover"
fi

# Load at boot from a late systemd unit, NOT from /etc/modules-load.d/.
# This driver has a known self-deadlock on load: it can wedge modprobe in
# uninterruptible sleep. From modules-load.d that hangs the boot; from a unit
# ordered after multi-user.target the worst case is a dark Touch Bar on a
# system you can still log into and fix.
#
# fnmode is already set twice - /etc/modprobe.d/apple.conf and
# apple_ib_tb.fnmode=1 on the kernel command line - both left over from the
# old linux-t2 setup and both correct for this driver.
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] write /etc/systemd/system/apple-ibridge.service"
else
  cat > /etc/systemd/system/apple-ibridge.service <<'UNIT'
[Unit]
Description=Load Apple T1 iBridge Touch Bar driver
After=multi-user.target
ConditionPathExists=/boot/EFI/APPLE/EMBEDDEDOS/combined.memboot

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=30
ExecStart=/usr/bin/modprobe industrialio_triggered_buffer
ExecStart=/usr/bin/modprobe apple_ib_tb
ExecStart=/usr/local/bin/apple-ibridge-handover
# Deliberately no ExecStop. systemd runs it at shutdown, and unloading this
# driver risks the same deadlock as loading it - which would hang poweroff
# rather than merely leaving the strip dark. Use --revert to remove it.

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable apple-ibridge.service >/dev/null 2>&1 || true
  echo "  wrote and enabled apple-ibridge.service (after multi-user.target)"
fi
echo

# ------------------------------------------------------------------- load ---
echo "== load =="
run modprobe industrialio_triggered_buffer 2>/dev/null || true
if [[ $DRY -eq 0 ]]; then
  if ! timeout 30 modprobe apple_ib_tb 2>/tmp/ibridge-modprobe.err; then
    rc=$?
    echo "modprobe apple_ib_tb failed:" >&2
    sed 's/^/  /' /tmp/ibridge-modprobe.err >&2
    if [[ $rc -eq 124 ]]; then
      cat >&2 <<'MSG'

modprobe hung and was killed after 30s. This is the known self-deadlock in
this driver; the modprobe process is now likely stuck in D state and cannot
be killed, and this module can no longer be loaded or unloaded until reboot.

This source exposes only idle_timeout, dim_timeout and fnmode - there is no
tb_mode_param here, so the workaround quoted for other forks does not apply.

The systemd unit is ordered after multi-user.target, so this cannot hang your
boot: reboot, then either try --fork for a source with the deadlock fixed, or
run "sudo ./fix-touchbar-t1.sh --revert" to stop loading it at boot.
MSG
    fi
    exit 1
  fi
  echo "  apple_ib_tb loaded (pulls in apple_ibridge)"
else
  echo "  [dry-run] modprobe apple_ib_tb"
fi

# hid-generic and hid-sensor-hub grab the iBridge interfaces at boot, before
# apple-ibridge exists. Re-enumerate so the specific driver gets its chance.
echo "  re-binding $IBRIDGE_USB so apple-ibridge can claim it"
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] echo $IBRIDGE_USB > /sys/bus/usb/drivers/usb/{unbind,bind}"
else
  echo "$IBRIDGE_USB" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 1
  echo "$IBRIDGE_USB" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
  sleep 2
fi

echo "  handing iBridge HID interfaces to apple-ibridge-hid"
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] /usr/local/bin/apple-ibridge-handover"
else
  /usr/local/bin/apple-ibridge-handover 2>&1 | sed 's/^/    /'
  sleep 1
fi
echo

echo "== result =="
if [[ $DRY -eq 0 ]]; then
  "$0" --verify | sed -n '/=== driver modules ===/,$p'
  echo
  echo "The Touch Bar should now show the function row. Press fn to switch modes."
  echo
  echo "If it is still dark, check the table above: apple-ibridge-hid must hold the"
  echo "634-byte interface. If hid-sensor-hub still has it, re-run:"
  echo "  sudo /usr/local/bin/apple-ibridge-handover"
  echo
  echo "apple-ibridge.service repeats the handover on every boot."
fi
