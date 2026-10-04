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
if [ ! -d "$SDK_PATH/media/out/lib" ]; then
    echo "  Building SDK media libraries first..."
    export PATH="$SDK_PATH/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin:$PATH"
    export RK_CHIP=rv1106
    export RK_TOOLCHAIN_CROSS=arm-rockchip830-linux-uclibcgnueabihf
    export CMAKE_POLICY_VERSION_MINIMUM=3.5
    make -C "$SDK_PATH/media" media_libs
fi

mkdir -p "$ROOT_DIR/kvm_video/librga"
ln -sf "$SDK_PATH/media/out/include/rga" "$ROOT_DIR/kvm_video/librga/include"
ln -sf "$SDK_PATH/media/out/rga_samples" "$ROOT_DIR/kvm_video/librga/samples"

cd "$ROOT_DIR/kvm_video"
RK_APP_CROSS="$SDK_PATH/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf"
RK_MEDIA_OUTPUT="$SDK_PATH/media/out"
INCLUDES="-I. -I./npu/include -I./osd -I./include/rknn -I./include/opencv4 -I$RK_MEDIA_OUTPUT/include -I$RK_MEDIA_OUTPUT/include/libdrm -I$RK_MEDIA_OUTPUT/rga_samples/utils/allocator/include"
CFLAGS="$INCLUDES -Wno-int-conversion -Wno-implicit-function-declaration -Wno-discarded-qualifiers -O2"
CXXFLAGS="$INCLUDES -DRV1106_1103 -O2"
LDFLAGS="-L$RK_MEDIA_OUTPUT/lib -lpthread -lrockit -lrockchip_mpp -lrga -lm -L./lib -lrknnmrt -s"

mkdir -p build/bin build/obj build/obj/npu/src build/obj/osd

$RK_APP_CROSS-gcc $CFLAGS -c main.c -o build/obj/main.o
$RK_APP_CROSS-gcc $CFLAGS -c video.c -o build/obj/video.o
$RK_APP_CROSS-gcc $CFLAGS -c edid.c -o build/obj/edid.o
$RK_APP_CROSS-gcc $CFLAGS -c ctrl.c -o build/obj/ctrl.o
$RK_APP_CROSS-gcc $CFLAGS -c frozen.c -o build/obj/frozen.o
$RK_APP_CROSS-gcc $CFLAGS -c osd/overlay.c -o build/obj/osd/overlay.o
$RK_APP_CROSS-gcc $CFLAGS -c npu/src/preprocess.c -o build/obj/npu/src/preprocess.o
$RK_APP_CROSS-gcc $CFLAGS -x c -c "$RK_MEDIA_OUTPUT/rga_samples/utils/allocator/dma_alloc.cpp" -o build/obj/dma_alloc.o

$RK_APP_CROSS-g++ $CXXFLAGS -c npu/src/yolov5.cc -o build/obj/npu/src/yolov5.o
$RK_APP_CROSS-g++ $CXXFLAGS -c npu/src/postprocess.cc -o build/obj/npu/src/postprocess.o
$RK_APP_CROSS-g++ $CXXFLAGS -c npu/src/yolo_c_api.cc -o build/obj/npu/src/yolo_c_api.o

$RK_APP_CROSS-g++ -o build/bin/kvm_video \
  build/obj/main.o build/obj/video.o build/obj/edid.o build/obj/ctrl.o build/obj/frozen.o \
  build/obj/osd/overlay.o build/obj/npu/src/preprocess.o build/obj/dma_alloc.o \
  build/obj/npu/src/yolov5.o build/obj/npu/src/postprocess.o build/obj/npu/src/yolo_c_api.o \
  $LDFLAGS

cp -fv build/bin/kvm_video "$OUT_BIN/kvm_video"

echo "==> Building kvm_app (Go backend & Web UI)..."
if [ ! -f "$ROOT_DIR/kvm/static/index.html" ]; then
    echo "  Building frontend device assets..."
    cd "$ROOT_DIR/kvm/ui"
    npm ci
    npm run build:device
fi

cd "$ROOT_DIR/kvm"
GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o "$OUT_BIN/kvm_app" cmd/main.go

echo "==> All PicoKVM application binaries built successfully:"
ls -lh "$OUT_BIN"

# Sync compiled binaries into system.img if available
SYSTEM_IMG="$ROOT_DIR/output/system.img"
if [ ! -f "$SYSTEM_IMG" ] && [ -f "$ROOT_DIR/kvm_system/split_and_check_md5.sh" ]; then
    echo "==> Extracting reference system.img from kvm_system for binary sync..."
    cat "$ROOT_DIR/kvm_system"/update_system.tar.split.* | tar -xC "$ROOT_DIR/output" system.img 2>/dev/null || true
fi

if [ -f "$SYSTEM_IMG" ] && command -v debugfs >/dev/null 2>&1; then
    echo "==> Injecting compiled applications into system.img..."
    for bin in "$OUT_BIN"/kvm_*; do
        [ -f "$bin" ] || continue
        bname=$(basename "$bin")
        debugfs -w -R "rm /usr/bin/$bname" "$SYSTEM_IMG" >/dev/null 2>&1 || true
        debugfs -w -R "write $bin /usr/bin/$bname" "$SYSTEM_IMG" >/dev/null 2>&1
        echo "  [OK] Injected $bname into /usr/bin/"
    done
fi

