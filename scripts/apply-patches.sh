#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Applying Kernel Patches..."
cd "$ROOT_DIR/sdk/sysdrv/source/kernel"
if git apply --check "$ROOT_DIR/patches/kernel/0001-cst816x-unconditional-touch-release.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/kernel/0001-cst816x-unconditional-touch-release.patch"
    echo "  [OK] CST816X touch driver patch applied."
else
    echo "  [SKIP] CST816X touch driver patch already applied or clean."
fi

if git apply --check "$ROOT_DIR/patches/kernel/0002-fix-dts-bootargs-root.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/kernel/0002-fix-dts-bootargs-root.patch"
    echo "  [OK] Kernel DTS bootargs patch applied."
else
    echo "  [SKIP] Kernel DTS bootargs patch already applied or clean."
fi

echo "==> Applying kvm_display Patches..."
cd "$ROOT_DIR/kvm_display"
if git apply --check "$ROOT_DIR/patches/kvm_display/0001-optimize-loop-sleep-tick.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/kvm_display/0001-optimize-loop-sleep-tick.patch"
    echo "  [OK] kvm_display loop tick patch applied."
else
    echo "  [SKIP] kvm_display loop tick patch already applied or clean."
fi

if git apply --check "$ROOT_DIR/patches/kvm_display/0002-touchscreen-auto-detect-and-gesture-fix.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/kvm_display/0002-touchscreen-auto-detect-and-gesture-fix.patch"
    echo "  [OK] kvm_display touchscreen auto-detect patch applied."
else
    echo "  [SKIP] kvm_display touchscreen auto-detect patch already applied or clean."
fi

echo "==> Applying U-Boot Patches..."
cd "$ROOT_DIR/sdk/sysdrv/source/uboot/u-boot"
if git apply --check "$ROOT_DIR/patches/uboot/0001-fix-ab-root-part-devnum.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/uboot/0001-fix-ab-root-part-devnum.patch"
    echo "  [OK] U-Boot android_ab root devnum patch applied."
else
    echo "  [SKIP] U-Boot android_ab root devnum patch already applied or clean."
fi

echo "==> Linking Board Configurations..."
cp -fv "$ROOT_DIR/configs/"BoardConfig-*.mk "$ROOT_DIR/sdk/project/cfg/BoardConfig_IPC/"
echo "==> All patches and configs verified."
