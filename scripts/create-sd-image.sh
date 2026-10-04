#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/output"
IMAGE_PATH="$OUTPUT_DIR/picokvm-sdcard.img"

mkdir -p "$OUTPUT_DIR"

# Locate partition images
BOOT_IMG="${1:-$OUTPUT_DIR/boot.img}"
if [ ! -f "$BOOT_IMG" ]; then
    BOOT_IMG="$ROOT_DIR/sdk/output/image/boot.img"
fi

if [ ! -f "$BOOT_IMG" ]; then
    echo "Error: boot.img not found. Run 'make kernel' first." >&2
    exit 1
fi

# Ensure reference components exist from kvm_system or sdk
UBOOT_IMG="$ROOT_DIR/sdk/output/image/uboot.img"
if [ ! -f "$UBOOT_IMG" ]; then
    UBOOT_IMG="$ROOT_DIR/kvm_system/uboot.img"
fi
if [ ! -f "$UBOOT_IMG" ] && [ -f "$ROOT_DIR/kvm_system/split_and_check_md5.sh" ]; then
    echo "Extracting reference uboot from kvm_system..."
    cat "$ROOT_DIR/kvm_system"/update_system.tar.split.* | tar -xC "$OUTPUT_DIR" uboot.img 2>/dev/null || true
    UBOOT_IMG="$OUTPUT_DIR/uboot.img"
fi

ROOTFS_IMG="$ROOT_DIR/sdk/output/image/rootfs.img"
if [ ! -f "$ROOTFS_IMG" ]; then
    ROOTFS_IMG="$ROOT_DIR/kvm_system/system.img"
fi
if [ ! -f "$ROOTFS_IMG" ] && [ -f "$ROOT_DIR/kvm_system/split_and_check_md5.sh" ]; then
    echo "Extracting reference system.img from kvm_system..."
    cat "$ROOT_DIR/kvm_system"/update_system.tar.split.* | tar -xC "$OUTPUT_DIR" system.img 2>/dev/null || true
    ROOTFS_IMG="$OUTPUT_DIR/system.img"
fi

IDBLOCK_IMG="$ROOT_DIR/sdk/output/image/idblock.img"
if [ ! -f "$IDBLOCK_IMG" ]; then
    IDBLOCK_IMG="$ROOT_DIR/kvm_system/idblock.img"
fi

echo "==> Creating raw bootable SD card image: $IMAGE_PATH"
# Create 1.5GB sparse disk image
dd if=/dev/zero of="$IMAGE_PATH" bs=1M count=0 seek=1600 status=none

# Write Rockchip bootloader components (512-byte sectors)
if [ -f "$IDBLOCK_IMG" ]; then
    echo "  Writing idblock.img @ sector 64..."
    dd if="$IDBLOCK_IMG" of="$IMAGE_PATH" seek=64 bs=512 conv=notrunc status=none
fi

if [ -f "$UBOOT_IMG" ]; then
    echo "  Writing uboot.img @ sector 1088..."
    dd if="$UBOOT_IMG" of="$IMAGE_PATH" seek=1088 bs=512 conv=notrunc status=none
fi

echo "  Writing boot.img @ sector 1600..."
dd if="$BOOT_IMG" of="$IMAGE_PATH" seek=1600 bs=512 conv=notrunc status=none

if [ -f "$ROOTFS_IMG" ]; then
    echo "  Writing rootfs/system.img @ sector 1640000..."
    dd if="$ROOTFS_IMG" of="$IMAGE_PATH" seek=1640000 bs=512 conv=notrunc status=none
fi

echo "==> Bootable SD image created successfully:"
ls -lh "$IMAGE_PATH"
echo "You can flash this image directly to your SD card using:"
echo "  sudo dd if=$IMAGE_PATH of=/dev/sdX bs=4M status=progress conv=fsync"
