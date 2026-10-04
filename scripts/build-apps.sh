#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_PATH="$ROOT_DIR/sdk"
OUT_BIN="$ROOT_DIR/output/bin"

mkdir -p "$OUT_BIN"
export LUCKFOX_SDK_PATH="$SDK_PATH"

echo "==> Building kvm_display..."
cd "$ROOT_DIR/kvm_display"
make -j"$(nproc)"
cp -fv build/bin/kvm_display "$OUT_BIN/kvm_display"

echo "==> Building kvm_video..."
cd "$ROOT_DIR/kvm_video"
make -j"$(nproc)"
cp -fv build/bin/kvm_video "$OUT_BIN/kvm_video"

echo "==> Building kvm_app (Go backend)..."
cd "$ROOT_DIR/kvm"
GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o "$OUT_BIN/kvm_app" cmd/main.go

echo "==> All PicoKVM application binaries built successfully:"
ls -lh "$OUT_BIN"
