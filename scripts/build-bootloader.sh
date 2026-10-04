#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIUM="${1:-sd_card}"

echo "==> Configuring Bootloader for target medium: $MEDIUM..."
"$ROOT_DIR/scripts/apply-patches.sh"

cd "$ROOT_DIR/sdk"
if [ "$MEDIUM" = "emmc" ]; then
    ln -sf project/cfg/BoardConfig_IPC/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_KVM-IPC.mk .BoardConfig.mk
else
    ln -sf project/cfg/BoardConfig_IPC/BoardConfig-SD_CARD-Buildroot-RV1106_Luckfox_Pico_KVM-IPC.mk .BoardConfig.mk
fi

echo "==> Building U-Boot and IDBlock..."
./build.sh uboot

echo "==> Building Environment Image (env.img)..."
./build.sh env

mkdir -p "$ROOT_DIR/output"
cp -fv "$ROOT_DIR/sdk/output/image/idblock.img" "$ROOT_DIR/output/idblock.img"
cp -fv "$ROOT_DIR/sdk/output/image/uboot.img" "$ROOT_DIR/output/uboot.img"
cp -fv "$ROOT_DIR/sdk/output/image/env.img" "$ROOT_DIR/output/env.img"

echo "==> Bootloader built successfully for $MEDIUM:"
echo "    - $ROOT_DIR/output/idblock.img"
echo "    - $ROOT_DIR/output/uboot.img"
echo "    - $ROOT_DIR/output/env.img"
