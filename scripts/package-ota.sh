#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/output"
OTA_STAGING="$OUTPUT_DIR/ota_staging"
OTA_ZIP="$OUTPUT_DIR/picokvm-ota.zip"

mkdir -p "$OTA_STAGING" "$OUTPUT_DIR"

BOOT_IMG="${1:-$OUTPUT_DIR/boot.img}"
if [ ! -f "$BOOT_IMG" ]; then
    BOOT_IMG="$ROOT_DIR/sdk/output/image/boot.img"
fi

if [ ! -f "$BOOT_IMG" ]; then
    echo "Error: boot.img not found. Run 'make kernel' first." >&2
    exit 1
fi

echo "==> Packaging OTA update..."
cd "$OTA_STAGING"
rm -rf ./*
cp -fv "$BOOT_IMG" boot.img

# If full system.img exists, include it in the OTA tarball
if [ -f "$OUTPUT_DIR/system.img" ]; then
    cp -fv "$OUTPUT_DIR/system.img" system.img
elif [ -f "$ROOT_DIR/kvm_system/system.img" ]; then
    cp -fv "$ROOT_DIR/kvm_system/system.img" system.img
fi

# If uboot.img exists, include it
if [ -f "$OUTPUT_DIR/uboot.img" ]; then
    cp -fv "$OUTPUT_DIR/uboot.img" uboot.img
elif [ -f "$ROOT_DIR/kvm_system/uboot.img" ]; then
    cp -fv "$ROOT_DIR/kvm_system/uboot.img" uboot.img
fi

tar -cf update_system.tar *.img
zip -q update_system.zip update_system.tar
sha256sum update_system.zip > update_system.zip.sha256

cat << 'VERSION_EOF' > version.txt
AppVersion: 0.1.4
SystemVersion: 0.1.4-custom
VERSION_EOF

zip -q "$OTA_ZIP" version.txt update_system.zip update_system.zip.sha256
rm -rf "$OTA_STAGING"

echo "==> OTA package created successfully: $OTA_ZIP"
ls -lh "$OTA_ZIP"
