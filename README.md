# Linux on the 2017 15" MacBook Pro (MacBookPro14,3)

Getting the **Touch Bar, camera, audio, Wi-Fi and touchpad** working on a
2016/2017 Touch Bar MacBook Pro running Arch Linux.

Scripts plus a long-form [**RUNBOOK**](RUNBOOK.md) that records not just the
fixes but the evidence behind them, and the dead ends — because several of the
obvious answers on the internet are wrong for this hardware.

> [!WARNING]
> **These scripts run as root and change how your system boots, loads drivers
> and talks to hardware. Back up your data first, and read
> [Before you run anything](#before-you-run-anything).** They are shared in the
> hope they are useful, with no warranty of any kind — see [LICENSE](LICENSE).

---

## Read this first: your Mac has a T1, not a T2

The T2 chip starts with the **2018** models (MacBookPro15,x). The 2016 and 2017
Touch Bar models have the earlier **T1 / "iBridge"**.

Almost every "Linux on a MacBook Pro" guide you will find is written for T2.
Applying it here wastes hours and installs packages that silently do nothing.
This machine had a full T2 package set installed — `linux-t2`, `tiny-dfr`,
`t2fanrd`, `apple-t2-audio-config`, `apple-bcm-firmware` — none of which
applies, and one of which (`t2fanrd`) was crash-looping.

**Check which you have:**

```bash
cat /sys/class/dmi/id/product_name
# MacBookPro13,x or 14,x  -> T1, this repo applies
# MacBookPro15,x or later -> T2, use https://t2linux.org instead
```

**Never install on a T1 machine:** `linux-t2`, `apple-bce`, `tiny-dfr`,
`t2fanrd`, `apple-bcm-firmware`, `apple-t2-audio-config`, `facetimehd`,
`facetimehd-firmware`.

`tiny-dfr` in particular is useless here: it renders onto the `appletbdrm` DRM
node, which only ever exists on a T2. The same goes for every themed-Touch-Bar
project built on it — see [What the T1 Touch Bar can and cannot
do](#what-the-t1-touch-bar-can-and-cannot-do) before you spend an evening on one.

---

## What works after this

| Component | Status | How |
|---|---|---|
| Touch Bar | Working | Out-of-tree `apple-ibridge` trio, patched for current kernels |
| FaceTime camera | Working | No driver needed — the USB device just has to be configured |
| Audio (speakers + mic) | Working | Patched CS8409 driver; mainline has Dell-only quirks |
| Wi-Fi 5 GHz | Working | BCM43602 NVRAM blob + real MAC from EFI |
| Ambient light sensor | Working | Comes with the Touch Bar driver |
| Touchpad palm rejection | Improved | Size-based; this pad reports no pressure |
| Keyboard chatter | Mitigated | Diagnosis + debounce recipe; hardware defect underneath |
| **Touch ID** | **Never** | No Linux support exists on any T1 or T2. Plan around it |

Tested on Arch (Omarchy) with kernel 7.2, Hyprland, limine, LUKS + btrfs.
Most of it is distro-agnostic; the package names are Arch's.

---

## The prerequisite nobody mentions: the T1 firmware

**The T1 has no boot ROM.** macOS writes its firmware to the EFI System
Partition at `EFI/APPLE/EMBEDDEDOS/combined.memboot`, and Apple's boot firmware
loads it into the chip at *every power-on*.

A whole-disk Linux install erases that partition. The T1 then halts in recovery
forever, and **Touch Bar, camera, Touch ID and the ambient light sensor all die
together** — one fault, not four.

```bash
lsusb | grep 05ac
# 05ac:8600  healthy iBridge
# 05ac:1281  "Apple Mobile Device (Recovery Mode)" -> firmware is GONE
```

No driver can fix `1281`. Only macOS can rewrite the firmware, and the files are
TSS-personalised per device — they cannot be copied from another Mac.

**If your firmware is intact, back it up before anything else:**

```bash
sudo ./backup-t1-firmware.sh --out ~/backups
```

If it is gone, [RUNBOOK.md](RUNBOOK.md) documents two recovery routes. The
non-destructive one — installing macOS to an **external USB SSD** and booting it
once online — worked here, and repaired the *internal* ESP. That answer was not
documented anywhere before; most sources assume a full internal reinstall.

---

## Before you run anything

This is a record of fixing **one** machine. It worked there. Your Mac has a
different history — a different kernel, a different bootloader, packages someone
installed two years ago — and these scripts touch parts of the system that make
the difference between booting and not booting.

**Use them at your own risk. There is no warranty, express or implied. If
something here breaks your system, that is on you to repair.** The MIT licence
says the same thing in legal language, and it means it.

That is not a reason to avoid them. It is a reason to do four things first:

1. **Back up your data**, to something that is not this disk. Not "the important
   files" — everything you would mind losing.
2. **Back up the T1 firmware** if you still have it, with
   `sudo ./backup-t1-firmware.sh --out ~/backups`, and copy the archive
   somewhere else. Restoring it needs a working macOS installer and an
   internet connection; recreating it from nothing is a much longer day.
3. **Run `--verify` and `--dry-run` first.** Every script supports them, they
   change nothing, and they tell you what state you are actually in rather than
   what this README assumes.
4. **Read the script before running it as root.** They are commented heavily and
   explain *why* at each step, precisely so you can judge them rather than trust
   them.

### The parts that can actually hurt

| What | Risk |
|---|---|
| `remove-t2-cruft.sh` | Removes packages, potentially including a kernel. It refuses to leave you without one, but verify with `--dry-run` and keep a live USB nearby. |
| `fix-touchbar-t1.sh` | Loads an out-of-tree driver with a known load deadlock. It installs a systemd unit ordered *after* `multi-user.target` so a bad load costs a dark Touch Bar rather than a hung boot — but it does taint your kernel. |
| `backup-t1-firmware.sh --restore` | Writes to your EFI System Partition. On this setup that partition is also `/boot`. |
| The macOS recovery route | Involves an installer that can repartition disks. Erase the *external* target only, and never `disk0`. Get this wrong and you lose the Linux install. |
| `fix-wifi-nvram.sh` | Reloads `brcmfmac`; you lose network for a few seconds. Do not run it over SSH on the link you are using. |
| The keyboard debounce recipe | `interception-tools` grabs your only keyboard. Have a USB keyboard plugged in the first time, so a typo in the YAML cannot lock you out. |

Nothing here is irreversible except a wiped partition and a lost firmware
backup. Those two are worth being careful about; the rest is recoverable.

---

## Quick start

```bash
git clone https://github.com/cschaba/macbookpro14-3-linux
cd macbookpro14-3-linux

sudo ./backup-t1-firmware.sh --out ~/backups   # if firmware is present
sudo ./remove-t2-cruft.sh --dry-run            # only if T2 packages were installed
sudo pacman -S linux-headers                   # needed by two of the fixes
sudo ./fix-touchbar-t1.sh                      # Touch Bar + camera + ALS
sudo ./fix-wifi-nvram.sh                       # 5 GHz
./fix-audio-cs8409.sh                          # NOT root
# reboot
```

Every script supports `--dry-run`, most support `--verify`, and the ones that
change system state support `--revert`. **Run `--verify` first** — it changes
nothing and tells you what state you are actually in.

---

## Scripts

| Script | Run as | What it does |
|---|---|---|
| `backup-t1-firmware.sh` | root | Archive/restore the T1 firmware from the ESP. **Do this first.** |
| `fix-touchbar-t1.sh` | root | Build + load `apple-ibridge`/`apple-ib-tb`/`apple-ib-als`, patched for modern kernels. Also fixes the camera. |
| `fix-wifi-nvram.sh` | root | Install the BCM43602 NVRAM blob; restores 5 GHz and the real Apple MAC. |
| `fix-audio-cs8409.sh` | **user** | Install the patched CS8409 driver and clear a stuck WirePlumber profile. |
| `fix-touchpad-quirks.sh` | root | Size-based palm rejection (this touchpad has no pressure axis). |
| `diagnose-key-chatter.sh` | root | Tell hardware key chatter apart from compositor key-repeat. |
| `remove-t2-cruft.sh` | root | Remove T2-only packages that do nothing on a T1. |
| `touchbar-fnmode.sh` | **user** | Swap the Touch Bar between media keys and F-keys. |
| `check-gpu-idle-power.sh` | root | Measure the discrete GPU's idle draw, and show why it cannot be tuned. |

`fix-audio-cs8409.sh` must **not** run as root — `yay`/`makepkg` refuse to build
as root. It calls `sudo` itself where needed.

---

## What the T1 Touch Bar can and cannot do

People keep finding beautiful Touch Bar projects — themed buttons, ring gauges,
browser tabs with favicons, sliders, dictation — and asking whether they can be
ported to a T1. The answer is no, and it is worth knowing exactly why so you can
recognise the pattern yourself.

Those projects are all content generators for **`tiny-dfr`**, which renders
pixels to the Touch Bar's DRM device. Two things make that impossible here.

**The T1 has no framebuffer.** The iBridge coprocessor draws the bar *itself*,
from a fixed set of layouts baked into the firmware. The host only says which
layout to show. There is no pixel path at all:

```bash
ls /sys/class/drm/          # card0 (i915), card1 (amdgpu). No Touch Bar node.
lsusb -d 05ac:8600          # T1 iBridge. appletbdrm binds 05ac:8302 (T2 only).
grep -ic 'drm\|framebuffer\|pixel' /usr/src/macbook12-spi-driver*/apple-ib-tb.c
# 0
```

**The T1 has no digitizer.** It reports key codes, never coordinates, so
sliders, drag and swipe cannot work even in principle:

```bash
cat /sys/class/input/event*/device/name        # find "Apple Inc. iBridge"
cat .../capabilities/abs                       # 0  -- no absolute axes
```

So the T1's entire Touch Bar API is four layout constants and three brightness
states, from `apple-ib-tb.c`:

```c
APPLETB_CMD_MODE_ESC / _FN / _SPCL / _OFF     /* 4 layouts   */
APPLETB_CMD_DISP_ON  / _DIM / _OFF            /* 3 brightness */
```

### What you *can* do: swap media keys for F-keys

The bar shows one of two useful things, and `touchbar-fnmode.sh` switches
between them by writing one digit to the driver's `fnmode` attribute.

| mode | what the bar shows |
|---|---|
| `normal` | media keys — brightness, volume, play/pause; hold **fn** for F1–F12 |
| `inverted` | F1–F12; hold **fn** for media keys |

```bash
./touchbar-fnmode.sh --install-udev    # once: write access for your user (sudo)

./touchbar-fnmode.sh --set inverted    # F-keys on the bar
./touchbar-fnmode.sh --set normal      # media keys on the bar (Apple default)
./touchbar-fnmode.sh --status          # what is set, and where it lives
```

`normal` is what the driver starts in, and it is usually the one you want: the
media keys are there when you glance down, and **fn** gets you F1–F12 whenever
a terminal app needs them. Switch to `inverted` if you use F-keys constantly
and would rather hold **fn** for volume.

Two further layouts exist, mostly for completeness:

| mode | digit | what the bar shows |
|---|---|---|
| `fkeys` | 0 | F1–F12 only — **fn** does nothing |
| `special` | 3 | media keys only — **fn** does nothing |

Neither offers a route back to the other set without another `--set`, so reach
for `normal` or `inverted` unless you have a reason not to.

Note the `fnmode` node's HID suffix (`0003:05AC:8600.0003`) **increments each
time the iBridge re-enumerates**, which the boot-time handover helper does every
boot. The script resolves it by glob every time; do not hardcode it.

### Optional: a different layout per application

The script can also watch Hyprland's focus events and switch layout as you move
between windows — F-keys in a terminal, media keys in a music player.

**This is off by default**, and it is worth understanding why before turning it
on: `normal` already gives you F-keys on demand via **fn**, so per-app switching
mostly buys you a bar that changes under you as you alt-tab.

```bash
./touchbar-fnmode.sh --install-service   # follow the focused window
./touchbar-fnmode.sh --uninstall-service # stop
```

Rules live in `~/.config/touchbar-fnmode.conf` as `<window-class regex> = <mode>`,
first match wins:

```
default = normal                        # media keys; hold fn for F1-F12

#^(Alacritty|kitty|foot)$ = inverted    # F-keys at rest, fn for media
#^(Spotify|mpv|vlc)$      = special     # media transport only
```

Find a window's class with `./touchbar-fnmode.sh --which`, and test a rule
without switching windows using `./touchbar-fnmode.sh --match <class>`.

The layout only changes when the new app maps to a different mode, because every
write wakes the iBridge over USB. Focusing the bare desktop leaves the last
app's layout in place.

---

## The discrete GPU is always on, and you cannot do anything about it

The internal panel is wired to the Radeon Pro 555 — `eDP-1` lives on the amdgpu
card, and the Intel iGPU has **no eDP connector at all**. So the discrete GPU can
never runtime-suspend. It idles at its lowest clock, 214 MHz, and draws about
**7 W continuously**. That is the floor.

```bash
sudo ./check-gpu-idle-power.sh            # current state and idle draw
sudo ./check-gpu-idle-power.sh --measure  # A/B a setting, with read-back
```

### `power_dpm_state` does nothing — and lies about it

This is the trap. The write is accepted, exit status 0, no error:

```console
# echo balanced > /sys/class/drm/card1/device/power_dpm_state
# cat /sys/class/drm/card1/device/power_dpm_state
performance
```

It is a deprecated legacy interface, silently ignored on this chip. Any script
that sets it and reports success is lying to you — including an earlier version
of the one in this repo, which is why it is now a measurement tool and not a fix.

**Always read the value back. An accepted write is not an applied write.**

### How the wrong answer got made

A first pass measured five settings, one sample each, and produced a convincing
table: 9.07 W at the default, 7.48 W at `balanced`, 2.6 W apparently saved.

All of it was noise. The desktop was busy and varying underneath, and the *same*
setting later read 9.07 W, 10.10 W and 7.06 W at different moments — the spread
between repeats was larger than the effect being claimed. With the desktop quiet,
ten consecutive samples read **7.06 W with zero variance, at every setting**.

There was never anything to save. Two rules came out of it:

- average several samples, never trust one
- read the value back after writing

### Do not bother trying to move the panel to the Intel GPU

This is the only change that would remove the 7 W, and `vga_switcheroo` is
registered, so it looks possible:

```
0:DIS:+:Pwr:0000:01:00.0     <- Radeon, driving the panel
2:IGD: :Pwr:0000:00:02.0     <- Intel, powered but idle
```

It is not. Apple's firmware hands the panel to the Radeon before the kernel
starts, so **i915 never probes an eDP connector**. Switching the mux at runtime
gives the Intel chip a live panel it has no DRM connector for: black screen,
confirmed by testing. The mux is not persistent, so holding the power button and
rebooting recovers every time — but there is nothing here to find.

Doing it properly would mean programming gmux before boot (the `apple_set_os`
EFI trick, or GRUB-level register writes). On a T1 whose firmware you have
already had to recover once, that is a poor trade for 7 W.

What is left is physical: dust in the fan ducts and eight-year-old thermal paste.

---

---

## Things that cost real time here

Documented in full in [RUNBOOK.md](RUNBOOK.md); the short version:

- **`apple-ibridge` is an ACPI driver** (`acpi*:APP7777:*`), not a USB one. If
  that ACPI node is missing, the modules load and silently do nothing.
- **The iBridge boots into a crippled USB configuration** — only its two HID
  interfaces, no UVC — and drops to configuration 0 entirely within ~2 minutes
  when nothing claims it. Forcing re-enumeration is what makes the camera
  appear. This is why `/dev/video*` can be missing on a machine whose firmware
  is perfectly fine.
- **`hid-sensor-hub` steals the Touch Bar's HID interface.** Everything looks
  right, `dmesg` shows no error, the strip stays dark. Identify the correct
  interface by report-descriptor size — **634 bytes** — not by device id, which
  changes on every re-enumeration.
- **The 2018 driver source does not build on a modern kernel.** Four mechanical
  API changes, all patched automatically by the script. No fork required.
- **`disable_while_typing` only suppresses touches that *begin* while typing.**
  A palm already resting keeps tracking. It is not a substitute for palm
  rejection.
- **Audio can work but be far too quiet, and it is not a limiter.** The
  CS8409's hardware playback stage can sit at −36 dB, and PipeWire's slider
  does not drive it — so the desktop control tops out on an already-crushed
  signal. Raise `amixer -c 1 sset PCM` and `alsactl store` it.
- **This touchpad reports no pressure axis**, so every `AttrPalmPressureThreshold`
  recipe online is a no-op. Only touch *size* works.

---

## Kernel updates

`fix-touchbar-t1.sh` installs to `/lib/modules/<kver>/updates/`, which is
version-specific. **After a kernel upgrade the Touch Bar and camera stop working
until you re-run it:**

```bash
sudo pacman -S linux-headers    # if the version moved
sudo ./fix-touchbar-t1.sh
```

Audio does not need this — DKMS rebuilds the CS8409 driver automatically.

And once your firmware is on the partition mounted at `/boot`: **never reformat
it**, and make sure any reinstall preserves that partition or restores your
backup.

---

## Credits

Standing on other people's work:

- [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver)
  — Ronald Tschalär's `applespi` and the `apple-ibridge` trio. The Touch Bar
  driver is his; this repo only patches it for current kernel APIs.
- [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) —
  the CS8409 audio driver.
- [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1)
  — documented the `hid-sensor-hub` interface-stealing trap.
- [t2linux.org](https://t2linux.org) — for T2 machines. Not this one, but the
  best reference for its own hardware.

## Licensing, and what this repo does *not* ship

**No firmware, binaries or third-party source are distributed here.** Every file
in this repository is text that was written for it. Everything else is fetched
or read on your machine at run time.

### The scripts — MIT

[LICENSE](LICENSE) covers the original work. One carve-out: the kernel-compat
patch block inside `fix-touchbar-t1.sh` embeds short excerpts of and
replacements for `apple-ibridge.c` / `apple-ib-tb.c` / `apple-ib-als.c`, which
are `SPDX-License-Identifier: GPL-2.0`, © 2017–2018 Ronald Tschalär. **That
patch content is offered under GPL-2.0**, not MIT, and is noted as such in the
script header. It reads the driver source already installed on your machine and
patches a temporary copy; nothing is redistributed.

### The Wi-Fi NVRAM — proprietary, and not ours to give you

The BCM43602 NVRAM file is **Broadcom-proprietary**, originating from Apple's
Windows (Boot Camp) driver package. That is exactly why it is absent from
`linux-firmware`: nobody has established a right to redistribute it.

`fix-wifi-nvram.sh` does not contain it. By default it downloads a copy from an
*unmerged* pull request ([basecamp/omarchy#7487](https://github.com/basecamp/omarchy/pull/7487)),
pinned to a single commit and checksum-verified. That PR's author raised the
licensing question openly and left the call to the maintainers; it was still
open when this was written. Treat that copy as a convenience, not as a licensed
distribution.

Using this calibration data on a Mac you own — hardware Apple shipped it for —
is a different act from redistributing it. If you would rather avoid the
third-party copy, extract the file from your own Boot Camp driver package or
macOS install and pass it with `--file`. **Do not commit the resulting file
anywhere public.**

### The T1 firmware — never share it

`backup-t1-firmware.sh` archives Apple's `combined.memboot` and `FDRData` from
your own ESP so that *you* can restore *your own* machine. Those files are
TSS-personalised to a single device's ECID: they are useless on any other Mac,
they identify yours, and they are Apple's code. `.gitignore` blocks them.

Do not publish them, do not accept them from anyone else, and do not ask for
them — a copy from another machine cannot work anyway.

### Things this repo only links to

| Project | Licence | How it is used |
|---|---|---|
| [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver) | GPL-2.0 | Read from your installed `macbook12-spi-driver-dkms` package |
| [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) | GPL-2.0 | Cloned at run time by the audio script (or via AUR) |
| [F13-Kr1pt0n/macbook-pro-touchbar-driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) | GPL-2.0 | Cloned only when you pass `--fork` |

All three are source-only and carry no binary blobs.
