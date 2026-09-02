# MacBookPro14,3 on Omarchy/Arch — findings & runbook

Machine: **MacBookPro14,3** (2017 15", Touch Bar)
Board `Mac-551B86E5744E2388` · Omarchy / Arch · mainline `linux` · Hyprland · limine · LUKS+btrfs
Investigated 2026-09-01/02, on Arch (Omarchy), kernel 7.2, Hyprland, limine,
LUKS + btrfs.

This is a working log kept while fixing one machine, not a polished guide. It
records the evidence behind each fix and the dead ends, because several of the
obvious answers are wrong for this hardware. Dates and "confirmed working"
blocks are kept deliberately — they tell you what was actually verified, and
when, rather than what merely ought to work.

---

## The one thing to remember

**This is a T1 Mac, not a T2 Mac.**

The T2 chip starts with the 2018 models (MacBookPro15,x). The 2016/2017 Touch Bar
models have the earlier **T1 / "iBridge"**. Almost every Linux-on-Mac guide you
will find is written for T2, and applying it here wastes hours and installs
packages that silently do nothing.

This machine had been set up with a full T2 package set: `linux-t2`,
`linux-t2-headers`, `tiny-dfr`, `t2fanrd`, `apple-t2-audio-config`,
`apple-bcm-firmware`. None of it applies. All were removed on 2026-09-01.

**Never install on this machine:** `linux-t2`, `apple-bce`, `tiny-dfr`, `t2fanrd`,
`apple-bcm-firmware`, `apple-t2-audio-config`, `facetimehd`, `facetimehd-firmware`,
`apple-ib-drv-dkms-git`.

> **One exception, added later:** `macbook12-spi-driver-dkms` is on that list only
> because its `applespi` module duplicates and shadows the in-tree one. Its
> *other* three modules — `apple-ibridge`, `apple-ib-tb`, `apple-ib-als` — are the
> only T1 Touch Bar driver that exists. Keep the package for its source, but
> build **only those three**. `fix-touchbar-t1.sh` does exactly that.

---

## Status of the seven problems

| # | Problem | Root cause | Status |
|---|---|---|---|
| 1 | Touchpad too sensitive | Non-default Hyprland input settings | **Fixed** |
| 2 | Keyboard double characters | Butterfly switch defect (**confirmed**) + too-fast repeat | Repeat fixed; chatter accepted for now |
| 3 | Touch Bar dead | T1 firmware erased + no T1 driver | **Fixed** |
| 4 | Audio dead | Mainline has no Apple quirk for the CS8409 | **Fixed** |
| 5 | Camera dead | Same as #3, plus iBridge stuck in a 2-interface config | **Fixed** |
| 6 | Wi-Fi bad | BCM43602 NVRAM blob missing → no 5 GHz at all | **Fixed** |
| 7 | Fingerprint dead | Same as #3, **and no Linux driver exists** | Not fixable (unchanged) |

**Problems 3, 5 and 7 are one single fault**, not three. That fault — the missing
T1 firmware — was **fixed on 2026-09-01**. What is left is a pure driver problem.

---

## 1 · Touchpad — FIXED

### Cause

Nothing to do with drivers. `~/.config/hypr/input.lua` had three non-default
settings working against each other:

```lua
sensitivity  = 0.35            -- default 0
accel_profile = "flat"         -- default adaptive
touchpad = { disable_while_typing = false }   -- default true
```

`accel_profile = "flat"` removes the pointer acceleration curve, so a 1 mm palm
twitch and a deliberate 5 cm swipe get **identical gain**. `sensitivity = 0.35`
then multiplies it. And with `disable_while_typing = false`, palms resting on a
160 mm-wide pad move the cursor while you type.

### Trap: `input.conf` is dead code

Omarchy migrated to **Lua** (hyprlang deprecated since Hyprland 0.55) but left
both file sets in `~/.config/hypr/`. Only the `.lua` files are read.

```bash
grep -m1 "config found at" /run/user/1000/hypr/*/hyprland.log
# -> Using lua config found at /home/<you>/.config/hypr/hyprland.lua
```

Editing `input.conf`, `hyprland.conf`, `bindings.conf` etc. does **nothing**.

### The fix (already applied)

In `~/.config/hypr/input.lua`: comment out `sensitivity` and `accel_profile`,
set `disable_while_typing = true`, then:

```bash
hyprctl reload && hyprctl configerrors
hyprctl getoption input:sensitivity
hyprctl getoption input:touchpad:disable_while_typing
```

Backup: `~/.config/hypr/input.lua.bak.1788280035`

### If it is still twitchy

**This touchpad has no pressure sensor.** Verified from its ABS capability
bitmask (`0x27f800000000003`): `ABS_MT_TOUCH_MAJOR/MINOR` and
`WIDTH_MAJOR/MINOR` are present, `ABS_PRESSURE` and `ABS_MT_PRESSURE` are **not**.
The `applespi` driver never reports the pressure field the hardware sends.

So every `AttrPalmPressureThreshold` / `AttrPressureRange` recipe online is a
**no-op here**. Only touch *size* works. Run `./fix-touchpad-quirks.sh`
(`--measure` first to get real numbers).

There was a dead `/etc/libinput/local-overrides.quirks` on this machine matching
`Apple Internal Keyboard / Trackpad` — that is the USB `bcm5974` name from
pre-2016 MacBooks. This device is `Apple SPI Touchpad` (bus `spi`, vendor
`0x06cb`). The section never matched anything.

---

## 2 · Keyboard double characters

### Two different problems that look identical

| | Mechanism | Fix |
|---|---|---|
| **Compositor repeat** | one press, compositor repeats it | `repeat_delay` / `repeat_rate` |
| **Hardware chatter** | switch bounces → real separate press/release pairs | evdev-layer debounce only |

`repeat_rate = 40, repeat_delay = 250` was set (defaults are 25 / 600). At those
values a key held a quarter second fires every 25 ms. **Already reset to defaults.**

### Diagnose before installing anything

```bash
sudo ./diagnose-key-chatter.sh
```

Re-press within ~5–30 ms with a release in between = **hardware chatter**.

### Why no compositor setting can fix chatter

libinput deliberately does not debounce keyboards — *"must be implemented higher
in the stack, libinput is limited to hardware debouncing"*. Wayland has no
AccessX/BounceKeys. **`keyd`, `kmonad` and `evremap` all lack a chatter filter** —
do not reach for them. The only working route is `interception-tools` +
`debouncer-udevmon` (~25 ms), documented inside the diagnose script.

> ⚠️ That grabs your only keyboard. Have a USB keyboard plugged in the first time.

### Measured 2026-09-02

```
CHATTER: (KEY_H), repressed after 52.1 ms
autorepeat events seen: 0
```

**`autorepeat events seen: 0` settles it.** Compositor repeat is not involved;
the `repeat_rate`/`repeat_delay` reset already did its job. What remains is the
switch. Do not go back to `input.lua` for this.

Rate at the time of measurement: one event in 20 s of deliberate typing on the
affected key. Decision taken: **live with it**, re-measure if it worsens.

> If you do enable debouncing later, **`debounce_time = 25` would not have
> caught this.** The measured interval was 52 ms — a degrading butterfly switch
> bounces far slower than the classic 5–30 ms. Use your worst measured value
> plus ~10 ms (so ~60–65 ms here), and be aware that deliberate double letters
> land at 80–150 ms, so the margin is thinner than it looks. The script's
> detection window is 60 ms.

### The honest ceiling

This is the 2nd-gen **butterfly keyboard defect**. Apple's Keyboard Service
Program covered this model and **closed in November 2024**. Debounce masks a
switch that will keep degrading. The cures are a top-case replacement or an
external keyboard.

Unrelated but useful on a German ISO layout: `applespi.iso_layout=1` fixes
swapped `^` / `<`.

---

## 3, 5, 7 · Touch Bar, camera, Touch ID — one fault

### What hangs off the T1

USB device `05ac:8600` carries **Touch Bar, FaceTime HD camera, Touch ID, and the
ambient light sensor**. All four fail together.

> **RESOLVED 2026-09-01 — the external SSD route worked.**
> macOS Ventura installed to an external USB SSD wrote the firmware to the
> **internal** ESP, not the external one. `lsusb` now reports `05ac:8600`.
> Details and what remains in [Outcome](#outcome-of-the-recovery) below.

### The diagnosis

```bash
lsusb | grep 05ac
# 05ac:1281 Apple, Inc. Apple Mobile Device [Recovery Mode]   <- BAD
# 05ac:8600 would be a healthy iBridge
```

**The T1 has no boot ROM.** macOS writes its firmware to the *Apple* EFI System
Partition at `EFI/APPLE/EMBEDDEDOS/combined.memboot` (+ `FDRData`,
`version.plist`), and Apple's boot firmware loads it into the chip at every
power-on. A **whole-disk Linux install erases that partition**, and the T1 then
halts in iBoot recovery forever.

Confirmed on this machine:

```
find /boot -ipath '*APPLE*'   ->  nothing
nvme0n1p1     2G  vfat  EFI System   /boot    <- Omarchy's own ESP
nvme0n1p2 231.8G  crypto_LUKS
```

There is no Apple ESP left. No `/dev/video*` exists either.

**No driver can fix this.** The firmware is absent, not unbound.

### The camera needs no driver

On Touch Bar Macs the webcam is a plain **UVC** device on interfaces 0/1 of the
iBridge. `uvcvideo` binds it the moment `05ac:8600` appears *and the device is
configured* — see the caveat under [Outcome](#outcome-of-the-recovery); an
enumerated-but-unconfigured iBridge exposes no interfaces at all, so no camera. The PCIe
`facetimehd` camera only exists on the *non*-Touch Bar 13,1 — which is why
`lspci` shows no camera device here. Guides telling you to install `facetimehd`
on a 2017 Touch Bar Mac are simply wrong.

### Touch ID will never work

No Linux support exists on any T1 or T2 Mac, and none is in progress. The sensor
is wired to the Secure Enclave and speaks an encrypted, Apple-signed protocol.
`libfprint` has nothing for it. Even after a perfect firmware restore, Touch ID
stays dead. Plan around it.

### Recovery — what does NOT work

- **Apple Configurator 2 revive/restore** — supports Apple silicon and T2 only.
  Intel support starts at 2018 + iMac Pro. This model is excluded. There is no
  DFU cable procedure for a T1.
- **`idevicerestore` / libimobiledevice** — no public iBridge1,1 restore IPSW
  exists. The image ships only inside macOS and must be TSS-personalized.
- **Copying the files from another Mac** — they are signed per-ECID. They will
  not work, and they identify your device. Do not accept or publish them.
- **SMC / NVRAM reset** — cannot restore missing files.
  > ⚠️ NVRAM reset is *dangerous* here: limine registers an EFI boot variable
  > rather than `\EFI\BOOT\BOOTX64.EFI`, so `Cmd-Opt-P-R` can leave the machine
  > unbootable. This machine already has `/boot/EFI/BOOT/BOOTX64.EFI` present,
  > so the fallback exists — but there is still no reason to do it.

### Recovery — the external SSD route (try this first)

Non-destructive to the internal disk. Unverified for T1, but the only cost is time.

The mechanism: `EmbeddedOSInstallService` runs on **every macOS boot**. If
`combined.memboot` is missing from the ESP it performs a repair — building a
personalized bundle from `/usr/standalone/firmware/iBridge1_1Customer.bundle`,
making a TSS request to `gs.apple.com`, and writing the result to the ESP. The
open question is whether it targets the *internal* `disk0s1` or the ESP of the
disk it booted from.

1. Get a USB-C SSD (any size ≥ 64 GB) and a wired or WPA2 network. Activation
   needs `gs.apple.com`, so **the network must work inside macOS**.
2. Boot Internet Recovery: power on holding **⌥ + ⌘ + R**. The built-in keyboard
   is SPI and works in EFI/Recovery independently of the T1. Max macOS for this
   model is **Ventura 13**.
3. In Disk Utility, erase the external SSD as **APFS / GUID Partition Map**.
   **Do not touch `disk0`.**
4. Install macOS Ventura **to the external SSD**.
5. **Boot into it at least once, online.** The firmware is written at first boot,
   not during install. Let it sit at the desktop a few minutes.
6. Check whether the Touch Bar lights up in macOS. Then check the internal ESP:
   ```bash
   diskutil list
   sudo diskutil mount disk0s1
   ls -l /Volumes/EFI/EFI/APPLE/EMBEDDEDOS/
   ```
   You want `combined.memboot`, `FDRData`, `version.plist`.
7. **If those files exist on the internal ESP → you won.** Back them up
   (step below), reboot into Linux, and confirm:
   ```bash
   lsusb | grep 05ac        # want 05ac:8600, not 1281
   ls /dev/video*           # camera should appear
   ```
8. If they only landed on the *external* SSD's ESP, the external route did not
   work for T1. Fall back to the full route below — but you now have a macOS
   installer ready to go, so it is faster.

### Recovery — the full route (documented, ~95% success)

This is what everyone who has actually recovered a T1 did.

1. **Back up all Linux data.** This route wipes the internal disk.
2. Internet Recovery (**⌥ + ⌘ + R**) → install macOS Ventura to the internal disk.
3. **Boot into macOS once, online.** EOSIS runs at first boot and writes the ESP.
4. Verify `ls /Volumes/EFI/EFI/APPLE/EMBEDDEDOS/` as above.
5. **Back up the ESP immediately:**
   ```bash
   tar -C /Volumes/EFI -cf - EFI | gzip -6 > esp-files.tar.gz
   sudo dd if=/dev/rdisk0s1 bs=1m | gzip -6 > esp-raw.img.gz
   ```
   Verify using the tar stream, not the raw image — FAT tail blocks are not
   bit-stable.
6. Reinstall Omarchy with a **free-space install — never whole-disk.** Abort at
   the confirmation screen if the installer lists the ~300 MB Apple ESP as being
   formatted. Target layout:
   ```
   nvme0n1p1   300M  vfat        <- Apple ESP, T1 firmware, UNTOUCHED
   nvme0n1p2   ...   apfs        <- macOS (keep ~30 GB: the only way to take
                                     future Apple EFI/T1 firmware updates)
   nvme0n1p3   2G    vfat /boot  <- Omarchy ESP
   nvme0n1p4   ...   LUKS
   ```

<a id="outcome-of-the-recovery"></a>
### Outcome of the recovery — what actually happened

The external SSD route **worked**, and it answered the open question: macOS
repaired the **internal** ESP, not the ESP of the disk it booted from.

```
/boot/EFI/APPLE/EMBEDDEDOS/combined.memboot   30,725,398 bytes   Sep  1 14:34
/boot/EFI/APPLE/EMBEDDEDOS/FDRData               209,892 bytes
/boot/EFI/APPLE/EMBEDDEDOS/version.plist             360 bytes   iBridgeOS 910
/boot/EFI/APPLE/LOG/BOOT-1.LOG                                   Sep  2 08:41
```

`/boot` **is** `nvme0n1p1` — Omarchy's own ESP. Because Omarchy installed a
2 GB ESP rather than reusing Apple's 300 MB one, there was room, and macOS
simply wrote into it. `BOOT-1.LOG` carries the timestamp of the *Linux* boot,
which is proof that Apple's EFI reads and loads the firmware on every power-on
regardless of which OS is being booted.

```bash
lsusb | grep 05ac
# Bus 001 Device 002: ID 05ac:8600 Apple, Inc. iBridge     <- healthy
```

**Back this up now.** It is personalised to this machine's ECID, irreplaceable,
and one careless installer away from being gone again:

```bash
sudo ./backup-t1-firmware.sh --out ~/backups
# restore later:  sudo ./backup-t1-firmware.sh --restore <archive>
```

Consequences of the layout: the firmware now lives on the partition mounted at
`/boot`. Anything that reformats `/boot` destroys it again. Any future Omarchy
reinstall must **preserve `nvme0n1p1`** or restore the archive afterwards.

### Why the Touch Bar was dark, and what fixed it

Firmware present and the device enumerating is **not** enough — nothing in
mainline drives a T1 Touch Bar:

```bash
modinfo appletbdrm      | grep alias   # usb:v05ACp8302...   T2 only
modinfo hid-appletb-kbd | grep alias   # ...p00008302        T2 only
modinfo hid-appletb-bl  | grep alias   # ...p00008102        T2 only
```

A T1 Touch Bar is **8600** and matches none of them. This is also why removing
`tiny-dfr` was correct: it renders onto the `appletbdrm` DRM node, which never
exists on a T1.

The T1 driver is the out-of-tree `apple-ibridge` / `apple-ib-tb` /
`apple-ib-als` trio. `macbook12-spi-driver-dkms` ships the source but it had
never been compiled (`dkms status` → `added`, not `installed`), because there
were no kernel headers.

**Everything below is automated by `fix-touchbar-t1.sh`.** It is recorded here
because each step was a separate dead end, and any one of them alone leaves the
strip dark.

#### a. The 2018 source does not build on a current kernel

Four instances of ordinary API drift, all mechanical:

| Error | Kernel change |
|---|---|
| `report_fixup` pointer type | `hid_driver.report_fixup` returns `const __u8 *` (6.13) |
| `struct acpi_driver has no member 'owner'` | field removed |
| `.remove` type mismatch, ×2 | `platform_driver.remove` returns `void` (6.11) |
| `asm/unaligned.h` missing | moved to `linux/unaligned.h` (6.12) — `applespi` only |

Patched, all three iBridge modules build clean on 7.2.2. **No fork was needed.**
The script patches a temp copy, never `/usr/src`, so a package update replaces
the original cleanly; the edits are idempotent and skip themselves if a future
version already carries them.

> Build **only** `apple-ibridge`, `apple-ib-tb`, `apple-ib-als` — never the
> package's `applespi`. It would install to `/lib/modules/<kver>/updates/` and
> shadow the working in-tree driver behind your keyboard and touchpad.

#### b. `apple-ibridge` is an ACPI driver, not a USB one

Its alias is `acpi*:APP7777:*`. It binds to the ACPI node and only then
registers its HID drivers. If `/sys/bus/acpi/devices/APP7777:00` is absent the
modules load and silently do nothing.

#### c. The iBridge sits in a crippled USB configuration

This was the real surprise, and it explains the camera too.

At cold boot the T1 exposed **only its two HID interfaces**. `uvcvideo`
registered two seconds after enumeration and found nothing — the UVC interfaces
were not there. Separately, the device drops to **configuration 0** within about
two minutes when no driver claims it, at which point it exposes nothing at all.

Both are cured by forcing re-enumeration:

```bash
echo 1-3 | sudo tee /sys/bus/usb/drivers/usb/unbind
echo 1-3 | sudo tee /sys/bus/usb/drivers/usb/bind
```

after which:

```
1-3:1.0  class=0e  -> uvcvideo    camera
1-3:1.1  class=0e  -> uvcvideo    camera
1-3:1.2  class=03  -> usbhid      HID (boot keyboard)
1-3:1.3  class=03  -> usbhid      HID (Touch Bar + ALS)
```

**`/dev/video0` and `/dev/video1` appear at this point.** The camera never
needed a driver — it needed the device to be in the right configuration.

#### d. `hid-sensor-hub` steals the Touch Bar interface

The classic trap, and the one that makes everything *look* right while the strip
stays dark. Tell them apart by report-descriptor size, not by guessing:

```bash
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  echo "$(basename $h)  $(wc -c < $h/report_descriptor) bytes  ->  \
        $(basename $(readlink -f $h/driver))"
done
```

```
0003:05AC:8600.0007    83 bytes -> apple-ibridge-hid     boot keyboard, useless
0003:05AC:8600.0008   634 bytes -> hid-sensor-hub        <-- the Touch Bar
```

**634 is the exact size `appleib_report_fixup()` tests for** (`if (*rsize == 634
&& ...)`), so it is a reliable identifier. Hand it over:

```bash
echo -n '0003:05AC:8600.0008' | sudo tee /sys/bus/hid/drivers/hid-sensor-hub/unbind
echo -n '0003:05AC:8600.0008' | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind
```

> The HID device numbers change on every re-enumeration (`.0001` → `.0003` →
> `.0005` → `.0007`…). Match on the **634-byte descriptor**, never on a
> remembered id.

`/usr/local/bin/apple-ibridge-handover` does (c) and (d) together, conditionally
— it re-enumerates only when the device is unconfigured or exposing fewer than
four interfaces, so it never yanks a camera that is in use.

#### e. Confirmed working state

```
apple-ibridge / apple-ib-tb / apple-ib-als   loaded
/sys/bus/platform/devices/apple-ib-tb        bound
/sys/bus/platform/devices/apple-ib-als       bound
0003:05AC:8600.0007    83 bytes -> apple-ibridge-hid
0003:05AC:8600.0008   634 bytes -> apple-ibridge-hid
camera: /dev/video0 /dev/video1
ALS   : iio:device0 (als), now under .0008 i.e. apple-ib-als
```

Touch Bar functional, function row shown, `fn` switches modes.

Tunables live on the input device, not in `/sys/module`:

```bash
ls /sys/class/input/input18/device/    # dim_timeout  idle_timeout  fnmode
```

`idle_timeout` defaults to 300 s (strip switches off), `dim_timeout` to -2.
Any internal keyboard, touchpad or Touch Bar input wakes it.

> Loading is done by `apple-ibridge.service`, ordered **after
> `multi-user.target`** — never `/etc/modules-load.d/`. This driver has a known
> self-deadlock on load; from a late unit the worst case is a dark strip on a
> system you can still log into, not a hung boot. The unit re-runs the handover
> on every boot.

`apple_ib_tb.fnmode=1` is on the kernel command line and in
`/etc/modprobe.d/apple.conf`, both left over from the `linux-t2` era. Both are
correct for this driver — leave them.

> This source exposes only `idle_timeout`, `dim_timeout` and `fnmode`. There is
> **no `tb_mode_param`**; that belongs to a different fork. Do not chase it.

### Still broken: Touch ID

Unchanged and unfixable. See above — no Linux support exists on any T1 or T2.

---

## 4 · Audio

### Cause

**Mainline `snd-hda-codec-cs8409` has zero Apple support.** Its quirk table
(`sound/hda/codecs/cirrus/cs8409-tables.c`) contains only Dell subsystem IDs
(`0x1028*`). This machine is `0x106b3900`. Verified against the shipped binary:

```bash
zstd -dc /usr/lib/modules/$(uname -r)/.../snd-hda-codec-cs8409.ko.zst \
  | strings | grep -i macbook     # -> nothing
```

With no fixup matching, the driver falls through to the generic HDA parser. The
generic path never runs the I²C init for the **CS42L83** sub-codec (headphones +
headset mic) and never writes the vendor coefficients that bring the external
I²S speaker amps out of shutdown. Symptom: a bare `PCM` mixer control with no
Master/Speaker/Headphone and no mute.

### Second, independent bug

WirePlumber had pinned an **output-only** profile:

```
~/.local/state/wireplumber/default-profile
  alsa_card.pci-0000_00_1f.3=output:analog-surround-21
```

With no input side, there is **no capture source at all** — the mic is dead at
the profile level regardless of the codec.

### Fix

```bash
sudo pacman -Syu linux-headers     # REQUIRED first — see below
./fix-audio-cs8409.sh              # as your normal user, NOT root
sudo reboot
./fix-audio-cs8409.sh --verify
```

Driver: [`davidjo/snd_hda_macbookpro`](https://github.com/davidjo/snd_hda_macbookpro),
which carries `SND_PCI_QUIRK(0x106b, 0x3900, "MacBookPro 14,3", CS8409_MBP143)`.

> ⚠️ Raw ALSA devices (`hw:0,0`, `plughw:0,0`) have **no volume control** and play
> at full output. Test through PipeWire, not `speaker-test` on `hw:0,0`.

If the card is still on a surround profile afterwards:
```bash
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:analog-stereo+input:analog-stereo
amixer -c 0 sset 'Mic' cap     # headset mic capture switch ships off
```

`apple-t2-audio-config` was **not** the cause — its UCM profiles only match a card
named `AppleT2x2/x4/x6`, and this card is `HDA-Intel` / `PCH` on the ACP path.

---

### Third gotcha: the hardware gain stage is not the volume slider

Symptom: audio works, nothing is muted, the desktop volume control goes to
100% — and it is still far too quiet. It reads like a limiter. It is not.

```bash
amixer -c 1 sget PCM
#   75 [29%] [-36.00dB]      <- hardware playback stage, near the bottom
pactl get-sink-volume @DEFAULT_SINK@
#   85% / -4.24 dB           <- what the desktop thinks
```

**PipeWire's slider does not drive this control on this driver.** Verify it
yourself — move PipeWire and watch ALSA stay put:

```bash
pactl set-sink-volume @DEFAULT_SINK@ 60%;  amixer -c 1 sget PCM | grep -o '\[[0-9]*%\]'
pactl set-sink-volume @DEFAULT_SINK@ 100%; amixer -c 1 sget PCM | grep -o '\[[0-9]*%\]'
# unchanged at 29% both times
```

So PipeWire applies software attenuation on top of a hardware stage cutting
**−36 dB** — roughly 63× in amplitude. No amount of sliding recovers it.

Fix the hardware stage once, then use PipeWire normally:

```bash
amixer -c 1 sset PCM 90%     # 0 dB is 100%; find the highest that stays clean
sudo alsactl store           # persist via alsa-restore.service
```

> Lower PipeWire first. Going from −36 dB to 0 dB is a very large jump, and
> these are small speakers — full output distorts on bass and is not kind to
> them. Check headphones separately; that path may want a different level.

`fix-audio-cs8409.sh --verify` reports this gain and flags it when it is below
−20 dB.

### Confirmed working state (2026-09-02)

```
CS8409 ALSA card:  card 1 [PCH]
playback device:   card 1: PCH, device 0: CS8409/CS42L83 Analog
mixer controls:    PCM, Mic, Internal Mic, Internal Mic Boost
card profiles:     alsa_card.pci-0000_01_00.1   off      (ATI HDMI)
                   alsa_card.pci-0000_00_1f.3   output:analog-stereo+input:analog-stereo
default sink:      alsa_output.pci-0000_00_1f.3.analog-stereo   RUNNING
```

Requires `linux-headers` and a **reboot** — the codec module cannot be swapped
on a live system. DKMS rebuilds it automatically on kernel updates (unlike the
Touch Bar driver, which must be re-run manually).

---

## 6 · Wi-Fi

### Cause

`linux-firmware` ships `brcmfmac43602-pcie.bin` but **never the per-board NVRAM
calibration file**. Without it:

- the **5 GHz band is not registered with cfg80211 at all** — `iw phy phy0 info`
  shows only `Band 1`. This is not a regulatory restriction; the channels do not
  exist.
- HT caps `0x1020` — HT20 only, no HT40. Ceiling ~144 Mbit/s PHY.
- the interface comes up with Broadcom's placeholder MAC `00:90:4c:xx:xx:xx`
  (this is the firmware's literal built-in fallback, not just a generic OUI).
- TX power and BT coexistence run uncalibrated.

Measured baseline: **19 Mbit/s**, −76 dBm on channel 6, rates collapsing under
load. Reference machines with the NVRAM reach ~780/866 Mbit/s on 5 GHz.

### Fix

```bash
sudo ./fix-wifi-nvram.sh --verify     # baseline
sudo ./fix-wifi-nvram.sh
sudo reboot                            # if Band 2 does not appear from the reload
```

The script recovers the real Apple MAC from
`/sys/firmware/efi/efivars/ROM-4d1ede05-…` and writes both filenames brcmfmac
looks for (DMI-specific first, generic fallback).

> ⚠️ The NVRAM comes from an **unmerged** Omarchy PR (basecamp/omarchy#7487),
> pinned to one commit and checksum-verified. It is third-party RF calibration
> data. Review it, or supply your own with `--file`.

Then prefer 5 GHz:
```bash
nmcli connection modify <name> 802-11-wireless.band a
nmcli connection up <name>
iw dev wlp3s0 link      # expect freq 5xxx, width 80MHz
```
`band a` makes the profile fail if 5 GHz is out of range — for a roaming laptop,
pin the 5 GHz BSSID or keep a second profile instead.

### Expected and harmless

```
brcmfmac: no clm_blob available (err=-2)
brcmfmac: no txcap_blob available (err=-2)
brcmf_inetaddr_changed: fail to get arp ip table err:-52
Bluetooth: hci0: BCM: firmware Patch file not found
```
Broadcom never licensed the CLM blob for redistribution. **The NVRAM alone
restores 5 GHz.** Do not chase these.

### Already correct — do not "fix"

- `/etc/modprobe.d/brcmfmac.conf: options brcmfmac feature_disable=0x82000` is
  **load-bearing** for WPA2/WPA3 association on Apple hardware. Leave it.
- Power save is already off via NetworkManager `wifi.powersave = 2`.

At −76 dBm you also have a real distance/obstruction problem. Even after the fix,
if 5 GHz does not reach where you sit, move the AP.

---

## After every kernel update

`fix-touchbar-t1.sh` installs to `/lib/modules/<kver>/updates/`, which is
version-specific. **After a kernel upgrade the Touch Bar and camera will be gone
until you re-run it:**

```bash
sudo pacman -S linux-headers    # if the version moved
sudo ./fix-touchbar-t1.sh
```

The packaged DKMS build will keep failing on every kernel update — it tries to
build `applespi` too, which needs a fifth patch (`asm/unaligned.h` →
`linux/unaligned.h`) and which we deliberately do not want installed. That
failure is noise; ignore it, or drop the package once you have copied its source
somewhere stable.

---

## Prerequisite for everything DKMS

```bash
sudo pacman -Syu linux-headers
```

`-Syu`, not `-S` — plain `-S` risks a partial upgrade. Removing the T2 set took
`linux-t2-headers` with it and left the machine with **no kernel headers**, so
`/usr/lib/modules/$(uname -r)/build` was missing and DKMS could build nothing.

If this pulls a newer kernel, **reboot before building anything** so the running
kernel and the installed headers match.

---

## Scripts

All live in the repository root. All support `--dry-run`; most support `--verify`.

| Script | Run as | Purpose |
|---|---|---|
| `remove-t2-cruft.sh` | root | Remove the T2 package set (only if it was installed) |
| `fix-wifi-nvram.sh` | root | BCM43602 NVRAM → 5 GHz + real MAC |
| `fix-audio-cs8409.sh` | **normal user** | Patched CS8409 driver + clear pinned profile |
| `fix-touchpad-quirks.sh` | root | Size-based palm rejection (only if needed) |
| `diagnose-key-chatter.sh` | root | Chatter vs. compositor repeat |
| `backup-t1-firmware.sh` | root | **Archive the restored T1 firmware. Do this first.** Also `--restore` |
| `fix-touchbar-t1.sh` | root | Build/load the T1 Touch Bar driver — **done, works** (`--verify`, `--revert`) |

`fix-audio-cs8409.sh` must **not** run as root — `yay`/`makepkg` refuse to build
as root. It calls `sudo` itself where needed.

---

## Diagnostic cheat sheet

```bash
# identity
cat /sys/class/dmi/id/product_name              # MacBookPro14,3
lsusb | grep 05ac                               # 8600 = T1 healthy, 1281 = dead

# which hypr config is live
grep -m1 "config found at" /run/user/1000/hypr/*/hyprland.log
hyprctl getoption input:touchpad:disable_while_typing

# audio
aplay -l; amixer -c 0 scontrols
pactl list cards | grep -A2 'Active Profile'
cat ~/.local/state/wireplumber/default-profile

# wifi
iw phy phy0 info | grep -E '^\s+Band [0-9]'     # Band 2 = 5 GHz works
ip link show wlp3s0 | grep ether                # must NOT be 00:90:4c
journalctl -b -k | grep -i brcm

# input
cat /proc/bus/input/devices | grep -A8 'Apple SPI'
sudo libinput quirks list /dev/input/event5
sudo evtest /dev/input/event4

# T1 firmware + iBridge health
ls -l /boot/EFI/APPLE/EMBEDDEDOS/     # want combined.memboot, FDRData, version.plist
lsusb | grep 05ac                     # want 8600, not 1281
cat /sys/bus/usb/devices/1-3/bConfigurationValue   # empty == unconfigured
ls /dev/video*

# kernel headers present?
ls -d /usr/lib/modules/$(uname -r)/build
```

---

## Suggested order

0. **`sudo ./backup-t1-firmware.sh --out ~/backups`**, then copy the archive off
   this disk. Everything below is redoable; this is not. If the firmware is
   already missing, do the recovery in section 3/5/7 first.
1. **Check `uname -r` against `pacman -Q linux`.** If they differ, the running
   kernel is an orphan left by an update — reboot before going further, or
   `linux-headers` will build for the wrong version and nothing DKMS will work.
2. `sudo pacman -S linux-headers` — unblocks both the Touch Bar and audio.
3. `sudo ./fix-touchbar-t1.sh` — Touch Bar, camera and ALS. Check `ls /dev/video*`
   afterwards. **Re-run this after every kernel update** (see below).
4. `sudo ./fix-wifi-nvram.sh` → reboot → verify Band 2 present
5. `./fix-audio-cs8409.sh` (as your normal user) → reboot → verify
6. Live with the touchpad for a few days. If the pointer still jumps, turn off
   tap-to-click first, then `fix-touchpad-quirks.sh --measure`.
7. `sudo ./diagnose-key-chatter.sh` only if you see doubled characters.

---

## Gotchas that cost real time here

Four bugs bit during this work that had nothing to do with the hardware. All are
fixed in the scripts; they are recorded because they are easy to reintroduce.

**1. `grep -q` inside a pipeline under `set -o pipefail`.**
`grep -q` exits as soon as it matches. The producer then dies of SIGPIPE, and
`pipefail` reports the *whole pipeline* as failed — so a **successful match reads
as a failure**:

```bash
set -o pipefail
lspci -nn | grep -q '14e4:43ba'   # exit=141, PIPESTATUS=141 0
```

This made `fix-wifi-nvram.sh` claim the Wi-Fi chip was absent, and it silently
disabled the T2-machine safety guard in `remove-t2-cruft.sh` — that check could
never fire. Use `awk`, which consumes all input:

```bash
lspci -nn | awk '/14e4:43ba/{f=1} END{exit f?0:1}'
```

**2. The wiphy index is not stable.** Reloading `brcmfmac` moves `phy0` → `phy1`.
Anything hardcoding `phy0` reports a perfectly working 5 GHz radio as
"0 bands registered". Resolve it from the interface:

```bash
cat /sys/class/net/wlp3s0/phy80211/name
```

**3. `xxd` is not installed.** It ships with vim. Reading the Apple MAC from EFI
failed with exit 127, and a `|| true` swallowed it, so the script quietly took a
fallback path. Use `od` (coreutils):

```bash
od -An -tx1 -j4 -N6 /sys/firmware/efi/efivars/ROM-4d1ede05-38c7-4a6a-9cc6-4bcca8b38c14 \
  | tr -d ' \n' | sed 's/../&:/g; s/:$//'
```

**4. Grepping a module for the wrong marker.** `davidjo/snd_hda_macbookpro`
contains **no literal string `MacBookPro`**. Its Apple path shows up as
`cs_8409_apple_*` symbols and `cirrus_apple.h`, so testing for "MacBookPro"
reports a correct install as broken. Also ask `modinfo -n` which file modprobe
would load rather than taking the first `find` hit — the stock in-tree module and
the DKMS one both exist on disk.

**5. Card 0 is not the analog card.** On this machine `card 0` is the ATI HDMI
codec and `card 1` is the Cirrus CS8409:

```
0 [HDMI]: HDA-Intel - HDA ATI HDMI
1 [PCH ]: HDA-Intel - HDA Intel PCH      <- CS8409/CS42L83 Analog
```

`amixer -c 0` therefore returns the HDMI card's IEC958 (S/PDIF) controls and
makes a perfectly working analog card look dead. Likewise `pactl list cards |
grep -A1 'Active Profile' | head -1` returns the HDMI card's profile, which is
correctly `off`. Resolve the card by codec name:

```bash
for f in /proc/asound/card*/codec#*; do
  head -1 "$f" | grep -qi CS8409 && echo "${f#/proc/asound/card}" && break
done
```

Also note this driver exposes **`PCM`**, not `Master`/`Speaker`/`Headphone` —
testing for those names reports a working install as broken.

Related: a MAC starting `26:`, `02:`, `0a:` etc. (bit 2 of the first octet set)
is a NetworkManager randomised address during reassociation, not a failure. Wait
for it to settle before judging.

---

## Sources

- [Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux) — per-model support matrix
- [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1) — MacBookPro14,2 on Omarchy, Touch Bar traps
- [F13-Kr1pt0n/macbook-pro-touchbar-driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) — the maintained T1 Touch Bar fork
- [roadrunner2's Linux-on-MBP gist](https://gist.github.com/roadrunner2/1289542a748d9a104e7baec6a92f9cd7) — "back up the ESP" warning
- Erik Gomez, *The Untouchables* [pt 1](https://blog.eriknicolasgomez.com/2016/11/27/the-untouchables-apples-new-os-activation-for-touch-bar-macbook-pros/) / [pt 2](https://blog.eriknicolasgomez.com/2016/11/30/the-untouchables-pt-2-offline-touchbar-activation-with-a-purged-disk/) — how EOSIS writes the T1 firmware
- [Apple: revive or restore Mac firmware](https://support.apple.com/en-us/108900) — confirms T1 is excluded
- [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) — the CS8409 driver
- [basecamp/omarchy PR #7487](https://github.com/basecamp/omarchy/pull/7487) — the BCM43602 NVRAM
- [libinput: palm detection](https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html) · [button debouncing](https://wayland.freedesktop.org/libinput/doc/latest/button-debouncing.html)
- [Apple ends butterfly keyboard service program (Nov 2024)](https://www.macrumors.com/2024/11/19/apple-ends-mac-butterfly-keyboard-service-program/)
