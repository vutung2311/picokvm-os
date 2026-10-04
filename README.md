# PicoKVM-OS

A unified build framework and distribution system for the **Luckfox PicoKVM** (Rockchip RV1106).
Combines the Linux kernel, hardware video encoder, LVGL touchscreen UI, and Web/Go application backend into a single reproducible repository with automated patching and image generation.

---

## Architecture & Submodules

The project organizes all required components as git submodules:

| Submodule | Upstream Repository | Purpose |
| :--- | :--- | :--- |
| `sdk/` | [`luckfox-eng29/luckfox-pico`](https://github.com/luckfox-eng29/luckfox-pico.git) (`kvm-develop`) | Rockchip RV1106 SDK, Linux Kernel 5.10, U-Boot, Buildroot, Toolchain |
| `kvm/` | [`LuckfoxTECH/kvm`](https://github.com/LuckfoxTECH/kvm.git) | Go backend, WebRTC streaming, USB HID gadget, React frontend |
| `kvm_display/` | [`luckfox-eng29/kvm_display`](https://github.com/luckfox-eng29/kvm_display.git) | LVGL LCD touchscreen UI daemon |
| `kvm_video/` | [`luckfox-eng29/kvm_video`](https://github.com/luckfox-eng29/kvm_video.git) | RKMPI hardware H.264/H.265 video capture & encoder daemon |
| `kvm_system/` | [`luckfox-eng29/kvm_system`](https://github.com/luckfox-eng29/kvm_system.git) | Stock reference rootfs and OTA partition images |

---

## Patches Applied Automatically

The `make patch` command automatically applies critical hardware and driver improvements:

1. **Kernel CST816X Touchscreen Driver Fix** (`patches/kernel/0001-cst816x-unconditional-touch-release.patch`):
   - In `sysdrv/source/kernel/drivers/input/touchscreen/hynitron-cst816x.c`, `BTN_TOUCH 0` was originally nested inside `if (info.gesture)`. When lifting a finger without a chip-classified gesture, `BTN_TOUCH 0` was never emitted, causing evdev and LVGL's `lv_indev_wait_release()` to stay permanently pressed and ignore subsequent swipes.
   - The patch guarantees unconditional emission of `BTN_TOUCH 0` on touch lift.

2. **Display CPU Spin-Loop Optimization** (`patches/kvm_display/0001-optimize-loop-sleep-tick.patch`):
   - In `kvm_display/screen.c`, `usleep(500)` (0.5 ms) was busy-spinning the single Cortex-A7 core.
   - Changed to `10000` µs (10 ms / 100 Hz), matching LVGL's internal timer period and freeing ~90% idle CPU for video encoding and input handling.

3. **Dual Boot Medium Configurations** (`configs/`):
   - Supports both `sd_card` (MicroSD boot) and `emmc` (onboard storage).

---

## Quick Start

### 1. Initialize Submodules
```bash
make submodules
```

### 2. Complete One-Step Build
```bash
# For PicoKVM Lite (MicroSD card only - default):
make all
# or explicitly:
make all TARGET_MEDIUM=sd_card

# For PicoKVM Standard (onboard eMMC):
make all TARGET_MEDIUM=emmc
```

### 3. Step-by-Step Build (Optional)
```bash
# Apply patches & copy board configs
make patch

# Build bootloader (idblock, uboot, env):
make bootloader TARGET_MEDIUM=sd_card

# Build Linux kernel (boot.img):
make kernel TARGET_MEDIUM=sd_card

# Cross-compile applications (kvm_app, kvm_display, kvm_video):
make apps

# Generate bootable SD image:
make sd-image TARGET_MEDIUM=sd_card

# Generate Web OTA package:
make ota
```

---

## Flashing Instructions

### Method A: Flash to SD Card via PC (Unbrick / Fresh Install)
Insert your MicroSD card into your computer, identify its device node (e.g. `/dev/sdb`), and run:
```bash
sudo dd if=output/picokvm-sdcard.img of=/dev/sdX bs=4M status=progress conv=fsync
```
*(or write `output/picokvm-sdcard.img` using BalenaEtcher or Raspberry Pi Imager).*

### Method B: Flash via Web UI (OTA Update)
1. Open the PicoKVM web interface: `http://<KVM_IP>`
2. Go to **Settings** → **Firmware / Local Update**.
3. Upload `output/picokvm-ota.zip` and click **Update**.
4. Reboot the device when prompted.

---

## Repository Targets Reference

| Command | Action |
| :--- | :--- |
| `make all` | Builds bootloader, kernel, apps, OTA archive, and bootable SD image (`TARGET_MEDIUM=sd_card` or `emmc`) |
| `make bootloader` | Compiles U-Boot, idblock, and env (`TARGET_MEDIUM=sd_card` or `emmc`) |
| `make kernel` | Compiles patched Linux kernel and generates `output/boot.img` (`TARGET_MEDIUM=sd_card` or `emmc`) |
| `make apps` | Cross-compiles `kvm_app`, `kvm_display`, and `kvm_video` |
| `make sd-image` | Generates `output/picokvm-sdcard.img` (`TARGET_MEDIUM=sd_card` or `emmc`) |
| `make ota` | Packages `output/picokvm-ota.zip` |
| `make clean` | Removes compiled binaries and staging files |
