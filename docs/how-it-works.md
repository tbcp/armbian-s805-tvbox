# How it works

## The stock boot chain

The S805 boot ROM loads **u-boot from the internal NAND**, and it won't boot from SD while a valid bootloader is there. So the box's stock u-boot (a 2011-era Amlogic fork) always runs first, and anything we want to boot has to be started by it.

On a factory box, u-boot's `bootcmd` runs `storeboot`, which boots Android from NAND.

**Update mode** (reset button, or Android's `reboot update`) makes u-boot look for a script called **`aml_autoscript`** on the SD card or a USB stick and run it. Amlogic meant it for firmware updates. The TV-box community uses it to rewrite the u-boot environment. [`boot/aml_autoscript.cmd`](../boot/aml_autoscript.cmd), from balbes150's S805 images:

```
defenv                     reset the environment to defaults
setenv bootfromnand 0
setenv start_mmc_autoscript / start_usb_autoscript / start_autoscript   (load + run s805_autoscript)
setenv bootcmd 'run start_autoscript; run storeboot'
setenv reboot_mode normal
saveenv                    store it in NAND
reset
```

From then on, every boot:

1. tries to load and run **`s805_autoscript`** from a USB stick (FAT),
2. then from the SD card (FAT),
3. and if neither exists, or the script falls through, runs `storeboot`: **Android as usual**.

Both scripts are legacy u-boot script images (`mkimage -T script`), not plain text. The old u-boot boots kernels with `bootm`, so the kernel has to be a `uImage` and the initrd a `uInitrd`. Armbian's Onecloud image already ships both.

## Why the official Onecloud image, and why not as-is

The Thunder OneCloud is also an S805 device, and its mainline support went into Armbian, which publishes official Onecloud images. The kernel (Armbian's generic `meson` kernel, with the device trees of all meson8b boards) and the Debian rootfs work on any S805 box. Two things don't:

1. **The bootloader.** The Onecloud images expect a modern u-boot flashed to the OneCloud's eMMC and boot through `boot.scr`. The stock u-boot never looks at `boot.scr`; it only runs `aml_autoscript` and `s805_autoscript`.
2. **The device tree.** `meson8b-onecloud.dtb` has no SD card slot (the OneCloud has none). The image also contains `meson8b-mxq.dtb` for the TRONFY MXQ, an M201-design box with the same Ethernet PHY and an SD slot. It fits this board unmodified.

So: **official Armbian Onecloud image + `meson8b-mxq.dtb` from that image + our own `s805_autoscript`**, plus the fixes below.

## `s805_autoscript`

[`boot/s805_autoscript.cmd`](../boot/s805_autoscript.cmd):

| Part | Why |
|---|---|
| Only `setenv`, `if … then … fi`, `fatload`, `bootm` | Commands this old u-boot certainly has. Armbian's `boot.scr` uses things like `env import` that it lacks. |
| `root=UUID=ac42c4c1-…` | The rootfs UUID of the official image, hard-coded because the old u-boot can't read `armbianEnv.txt`. **Change it if you switch to a different Armbian release.** |
| `rootflags=init_itable=0` | Works around a kernel 6.12 bug that can leave `ext4lazyinit` spinning at 100% CPU forever ([details](fixes.md#ext4lazyinit-stuck-at-100-cpu)). |
| `console=ttyAML0,115200n8 console=tty1` | Serial port and HDMI. `tty1` last makes HDMI the main console, so the first-login wizard shows on the TV. |
| Load addresses `0x14000000` / `0x15000000` / `0x11800000` | Staging addresses from balbes150's scripts, proven on stock S805 u-boots. `bootm` then moves the kernel to its load address `0x00208000`. |
| `fatload mmc 0 …` | `mmc 0` is the SD slot on the stock u-boot. |
| `meson8b-xsr.dtb` → `meson8b-mxq.dtb` → `dtb.img` | The custom device tree (SD on the faster controller, Wi-Fi) if present, else Armbian's stock MXQ one, else a fallback copy. |
| Final `echo` | If any load fails, the script ends and `bootcmd` continues with `storeboot`: the box **boots Android instead of hanging**. |

## What `build-image.sh` changes

On the **boot partition** (FAT), added with `mtools`:

| File | Purpose |
|---|---|
| `aml_autoscript`, `aml_autoscript.zip` | One-time boot-order change (update mode / "Update & Backup" app) |
| `s805_autoscript` | Boots Armbian on every start |
| `dtb/meson8b-xsr.dtb` | Stock MXQ device tree with the SD slot moved to the faster controller and the Wi-Fi enabled, prebuilt from this exact image's `meson8b-mxq.dtb` |
| `dtb.img` | Fallback copy of the stock device tree |
| `*.cmd` | Sources of the two scripts, for reference |

On the **root partition** (ext4), written with `debugfs`:

| File | Purpose |
|---|---|
| `/etc/default/cpufrequtils` | CPU fixed at 1.536 GHz, `performance` governor ([why](fixes.md#freezes-cpu-frequency)) |
| `/usr/local/sbin/s805-pin-mac` + `s805-pin-mac.service` | Generates a stable MAC on first boot ([why](fixes.md#stable-mac-address)). With `MAC=…`, the `.link` file is written at build time instead. |
| `/usr/local/sbin/xsr-dtb-build` + `/etc/apt/apt.conf.d/99xsr-dtb` | Rebuilds `meson8b-xsr.dtb` after every `apt` run, so kernel and DTB updates carry over ([details](fixes.md#faster-sd-card-the-sdhc-controller)) |

Everything else is byte-identical to the official image.

## Kernel updates

`s805_autoscript` loads `uImage`, `uInitrd` and the DTB straight from `/boot`, and those are exactly the files Armbian's kernel packages update (`uInitrd` is regenerated by `/etc/initramfs/post-update.d/99-uboot`). The APT hook rebuilds `meson8b-xsr.dtb` from the new stock DTB. Tested with an upgrade from trunk.130 to trunk.137. None of the other added files belong to a package, so updates never overwrite them. Only `armbian-config`'s CPU settings would rewrite `cpufrequtils`.
