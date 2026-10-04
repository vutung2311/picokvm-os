#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIUM="${1:-sd_card}"

echo "==> Configuring Kernel for target medium: $MEDIUM..."
"$ROOT_DIR/scripts/apply-patches.sh"

cd "$ROOT_DIR/sdk"
if [ "$MEDIUM" = "emmc" ]; then
    ln -sf project/cfg/BoardConfig_IPC/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_KVM-IPC.mk .BoardConfig.mk
else
    ln -sf project/cfg/BoardConfig_IPC/BoardConfig-SD_CARD-Buildroot-RV1106_Luckfox_Pico_KVM-IPC.mk .BoardConfig.mk
fi

echo "==> Building Kernel..."
./build.sh kernel

mkdir -p "$ROOT_DIR/output"
cp -fv "$ROOT_DIR/sdk/output/image/boot.img" "$ROOT_DIR/output/boot.img"
echo "==> Kernel built successfully: $ROOT_DIR/output/boot.img"
