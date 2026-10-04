#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/output"
IMAGE_PATH="$OUTPUT_DIR/picokvm-sdcard.img"

mkdir -p "$OUTPUT_DIR"

BOOT_IMG="${1:-$OUTPUT_DIR/boot.img}"
MEDIUM="${2:-sd_card}"

# Locate or build bootloader components (env, idblock, uboot)
ENV_IMG="$OUTPUT_DIR/env.img"
IDBLOCK_IMG="$OUTPUT_DIR/idblock.img"
UBOOT_IMG="$OUTPUT_DIR/uboot.img"

if [ ! -f "$ENV_IMG" ] || [ ! -f "$IDBLOCK_IMG" ] || [ ! -f "$UBOOT_IMG" ]; then
    echo "  Building bootloader (idblock, uboot, env) for $MEDIUM..."
    "$ROOT_DIR/scripts/build-bootloader.sh" "$MEDIUM"
    ENV_IMG="$OUTPUT_DIR/env.img"
    IDBLOCK_IMG="$OUTPUT_DIR/idblock.img"
    UBOOT_IMG="$OUTPUT_DIR/uboot.img"
fi

if [ ! -f "$BOOT_IMG" ] && [ -f "$ROOT_DIR/sdk/output/image/boot.img" ]; then
    BOOT_IMG="$ROOT_DIR/sdk/output/image/boot.img"
fi
if [ ! -f "$BOOT_IMG" ]; then
    echo "  Building kernel for $MEDIUM..."
    "$ROOT_DIR/scripts/build-kernel.sh" "$MEDIUM"
    BOOT_IMG="$OUTPUT_DIR/boot.img"
fi

SYSTEM_IMG="$OUTPUT_DIR/system.img"
if [ ! -f "$SYSTEM_IMG" ] && [ -f "$ROOT_DIR/sdk/output/image/rootfs.img" ]; then
    SYSTEM_IMG="$ROOT_DIR/sdk/output/image/rootfs.img"
fi
if [ ! -f "$SYSTEM_IMG" ] && [ -f "$ROOT_DIR/kvm_system/split_and_check_md5.sh" ]; then
    echo "  Extracting reference system.img from kvm_system..."
    cat "$ROOT_DIR/kvm_system"/update_system.tar.split.* | tar -xC "$OUTPUT_DIR" system.img 2>/dev/null || true
    SYSTEM_IMG="$OUTPUT_DIR/system.img"
fi

# Verify required files
for img in "$ENV_IMG" "$IDBLOCK_IMG" "$UBOOT_IMG" "$BOOT_IMG" "$SYSTEM_IMG"; do
    if [ ! -f "$img" ]; then
        echo "Error: Required image not found: $img" >&2
        echo "Please run 'make bootloader kernel apps' before creating SD image." >&2
        exit 1
    fi
done

# Sync fresh application binaries into system.img if compiled
if [ -d "$ROOT_DIR/output/bin" ] && command -v debugfs >/dev/null 2>&1; then
    echo "  Syncing compiled application binaries into system.img..."
    for bin in "$ROOT_DIR/output/bin"/kvm_*; do
        [ -f "$bin" ] || continue
        bname=$(basename "$bin")
        debugfs -w -R "rm /usr/bin/$bname" "$SYSTEM_IMG" >/dev/null 2>&1 || true
        debugfs -w -R "write $bin /usr/bin/$bname" "$SYSTEM_IMG" >/dev/null 2>&1
    done
fi

echo "==> Creating Rockchip RV1106 Dual-Slot A/B bootable SD image: $IMAGE_PATH"

# Check required host utilities
for cmd in dd python3 mke2fs debugfs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required utility '$cmd' is not installed." >&2
        exit 1
    fi
done

# Create 2200MB sparse disk image (fits comfortably on 4GB+ MicroSD cards)
rm -f "$IMAGE_PATH"
dd if=/dev/zero of="$IMAGE_PATH" bs=1M count=0 seek=2200 status=none

# 1. Write env.img @ sector 0 (Rockchip Fast ENV with partition layout)
echo "  Writing env.img @ sector 0..."
dd if="$ENV_IMG" of="$IMAGE_PATH" seek=0 bs=512 conv=notrunc status=none

# 2. Write idblock @ sector 64 (Rockchip RV1106 BootROM entry point)
echo "  Writing idblock.img @ sector 64..."
dd if="$IDBLOCK_IMG" of="$IMAGE_PATH" seek=64 bs=512 conv=notrunc status=none

# 3. Write uboot_a & uboot_b
echo "  Writing uboot.img to uboot_a (sector 1088) & uboot_b (sector 2112)..."
dd if="$UBOOT_IMG" of="$IMAGE_PATH" seek=1088 bs=512 conv=notrunc status=none
dd if="$UBOOT_IMG" of="$IMAGE_PATH" seek=2112 bs=512 conv=notrunc status=none

# 4. Initialize misc partition with AVB A/B boot metadata (Slot A active, Slot B bootable)
echo "  Initializing misc partition with AVB A/B boot metadata @ sector 3136..."
python3 -c "
import struct, zlib

magic = b'\x00AB0'
version_major = 1
version_minor = 0
reserved1 = b'\x00\x00'

# Slot A: priority 15, tries 7, successful 1
slot_a = struct.pack('BBBB', 15, 7, 1, 0)
# Slot B: priority 14, tries 7, successful 1
slot_b = struct.pack('BBBB', 14, 7, 1, 0)

last_boot = 0
reserved2 = b'\x00' * 11

payload = magic + struct.pack('BB', version_major, version_minor) + reserved1 + slot_a + slot_b + struct.pack('B', last_boot) + reserved2
crc = zlib.crc32(payload) & 0xffffffff
ab_data = payload + struct.pack('>I', crc)

# Write to misc partition at offset 2048 (sector 3136 + 4 sectors)
with open('$IMAGE_PATH', 'r+b') as f:
    f.seek((3136 * 512) + 2048)
    f.write(ab_data)
"

# 5. Write boot_a & boot_b (Dual-slot kernel 5.10 with CST816X fix)
echo "  Writing boot.img to boot_a (sector 4096) & boot_b (sector 69632)..."
dd if="$BOOT_IMG" of="$IMAGE_PATH" seek=4096 bs=512 conv=notrunc status=none
dd if="$BOOT_IMG" of="$IMAGE_PATH" seek=69632 bs=512 conv=notrunc status=none

# 6. Write system_a & system_b (Dual-slot rootfs with compiled kvm binaries)
echo "  Writing system.img to system_a (sector 135168) & system_b (sector 1183744)..."
dd if="$SYSTEM_IMG" of="$IMAGE_PATH" seek=135168 bs=512 conv=notrunc status=none
dd if="$SYSTEM_IMG" of="$IMAGE_PATH" seek=1183744 bs=512 conv=notrunc status=none

# 7. Initialize userdata partition with ext4 filesystem
echo "  Formatting initial ext4 filesystem on userdata (sector 2232320)..."
TMP_USERDATA="/tmp/picokvm_userdata_init.img"
rm -f "$TMP_USERDATA"
mke2fs -t ext4 -L userdata -F "$TMP_USERDATA" 64M >/dev/null 2>&1
if [ -d "$ROOT_DIR/output/bin" ] && command -v debugfs >/dev/null 2>&1; then
    echo "  Populating /userdata/picokvm/bin with compiled applications..."
    debugfs -w -R "mkdir /picokvm" "$TMP_USERDATA" >/dev/null 2>&1 || true
    debugfs -w -R "mkdir /picokvm/bin" "$TMP_USERDATA" >/dev/null 2>&1 || true
    for bin in "$ROOT_DIR/output/bin"/kvm_*; do
        [ -f "$bin" ] || continue
        bname=$(basename "$bin")
        debugfs -w -R "write $bin /picokvm/bin/$bname" "$TMP_USERDATA" >/dev/null 2>&1
    done
fi
dd if="$TMP_USERDATA" of="$IMAGE_PATH" seek=2232320 bs=512 conv=notrunc status=none
rm -f "$TMP_USERDATA"

echo "==> Bootable SD image created successfully:"
ls -lh "$IMAGE_PATH"
echo ""
echo "Partition Layout (Rockchip raw blkdevparts layout):"
echo "  Sector 0 (0B)          : env.img (32KB)"
echo "  Sector 64 (32KB)       : idblock.img (BootROM SPL, 512KB)"
echo "  Sector 1088 (544KB)    : uboot_a (512KB)"
echo "  Sector 2112 (1056KB)   : uboot_b (512KB)"
echo "  Sector 3136 (1568KB)   : misc (AVB Slot metadata, 256KB)"
echo "  Sector 3648 (1824KB)   : security (224KB)"
echo "  Sector 4096 (2MB)      : boot_a (Kernel FIT, 32MB)"
echo "  Sector 69632 (34MB)    : boot_b (Kernel FIT, 32MB)"
echo "  Sector 135168 (66MB)   : system_a (Rootfs, 512MB)"
echo "  Sector 1183744 (578MB) : system_b (Rootfs, 512MB)"
echo "  Sector 2232320 (1090MB): userdata (ext4)"
echo ""
echo "Flashing instructions:"
echo "  sudo dd if=$IMAGE_PATH of=/dev/sdX bs=4M status=progress conv=fsync"

