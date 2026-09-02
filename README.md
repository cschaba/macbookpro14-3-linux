# Linux on the 2017 15" MacBook Pro (MacBookPro14,3)

Getting the **Touch Bar, camera, audio, Wi-Fi and touchpad** working on a
2016/2017 Touch Bar MacBook Pro running Arch Linux.

Scripts plus a long-form [**RUNBOOK**](RUNBOOK.md) that records not just the
fixes but the evidence behind them, and the dead ends — because several of the
obvious answers on the internet are wrong for this hardware.

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
node, which only ever exists on a T2.

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

`fix-audio-cs8409.sh` must **not** run as root — `yay`/`makepkg` refuse to build
as root. It calls `sudo` itself where needed.

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

## Licence

MIT — see [LICENSE](LICENSE).

The scripts are original work. `fix-touchbar-t1.sh` patches GPL-2.0 kernel
driver sources at build time on your own machine; it does not redistribute them.
