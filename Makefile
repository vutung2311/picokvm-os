# PicoKVM-OS: Unified Build System for Luckfox PicoKVM
# Target Hardware: Luckfox Pico (RV1106)

SHELL := /bin/bash
ROOT_DIR := $(shell pwd)
OUTPUT_DIR := $(ROOT_DIR)/output

# Target boot medium: sd_card (default) or emmc
TARGET_MEDIUM ?= sd_card

.NOTPARALLEL:
.PHONY: all submodules patch bootloader kernel apps display video app vpn sd-image ota clean help test

all: submodules patch bootloader kernel apps ota sd-image
	@echo ""
	@echo "=========================================================="
	@echo "  PicoKVM Build Complete ($(TARGET_MEDIUM))!"
	@echo "  Bootable SD Image : $(OUTPUT_DIR)/picokvm-sdcard.img"
	@echo "  Web OTA Package   : $(OUTPUT_DIR)/picokvm-ota.zip"
	@echo "  Kernel FIT Image  : $(OUTPUT_DIR)/boot.img"
	@echo "  Application Binaries in: $(OUTPUT_DIR)/bin/"
	@echo "=========================================================="

submodules:
	@echo "==> Updating git submodules..."
	git submodule sync
	git submodule update --init

patch: submodules
	@echo "==> Applying hardware and driver patches..."
	@$(ROOT_DIR)/scripts/apply-patches.sh

bootloader: patch
	@echo "==> Building Bootloader for $(TARGET_MEDIUM)..."
	@$(ROOT_DIR)/scripts/build-bootloader.sh $(TARGET_MEDIUM)

kernel: patch
	@echo "==> Building Linux Kernel for $(TARGET_MEDIUM)..."
	@$(ROOT_DIR)/scripts/build-kernel.sh $(TARGET_MEDIUM)

apps: patch
	@echo "==> Building all PicoKVM applications..."
	@$(ROOT_DIR)/scripts/build-apps.sh

display: patch
	@echo "==> Building kvm_display..."
	@export LUCKFOX_SDK_PATH="$(ROOT_DIR)/sdk" && cd $(ROOT_DIR)/kvm_display && make -j$$(nproc)
	@mkdir -p $(OUTPUT_DIR)/bin && cp -fv $(ROOT_DIR)/kvm_display/build/bin/kvm_display $(OUTPUT_DIR)/bin/

video: patch
	@echo "==> Building kvm_video..."
	@export LUCKFOX_SDK_PATH="$(ROOT_DIR)/sdk" && cd $(ROOT_DIR)/kvm_video && make -j$$(nproc)
	@mkdir -p $(OUTPUT_DIR)/bin && cp -fv $(ROOT_DIR)/kvm_video/build/bin/kvm_video $(OUTPUT_DIR)/bin/

app: patch
	@echo "==> Building kvm_app..."
	@cd $(ROOT_DIR)/kvm && GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o $(OUTPUT_DIR)/bin/kvm_app cmd/main.go
	@mkdir -p $(OUTPUT_DIR)/bin

vpn:
	@echo "==> Building kvm_vpn..."
	@cd $(ROOT_DIR)/kvm_vpn && GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o $(OUTPUT_DIR)/bin/kvm_vpn main.go
	@mkdir -p $(OUTPUT_DIR)/bin

sd-image: bootloader kernel apps
	@echo "==> Assembling full bootable SD card image for $(TARGET_MEDIUM)..."
	@$(ROOT_DIR)/scripts/create-sd-image.sh $(OUTPUT_DIR)/boot.img $(TARGET_MEDIUM)

ota: kernel apps
	@echo "==> Packaging web-flashable OTA update..."
	@$(ROOT_DIR)/scripts/package-ota.sh $(OUTPUT_DIR)/boot.img

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf $(OUTPUT_DIR)
	@cd $(ROOT_DIR)/kvm_display && make clean 2>/dev/null || true
	@cd $(ROOT_DIR)/kvm_video && make clean 2>/dev/null || true
	@cd $(ROOT_DIR)/kvm && rm -rf bin/ 2>/dev/null || true

test:
	@echo "==> Running PicoKVM test suite and regression invariant checks..."
	@$(MAKE) -C $(ROOT_DIR)/kvm test
	@echo "==> Validating shell scripts syntax..."
	@bash -n $(ROOT_DIR)/scripts/*.sh
	@echo "==> All PicoKVM tests and safety restrictions passed successfully!"

help:
	@echo "PicoKVM-OS Build System Targets:"
	@echo "  make all         - Complete build (bootloader, kernel, apps, ota, and sd-image)"
	@echo "                     Options: TARGET_MEDIUM=sd_card (default, Lite) or emmc"
	@echo "  make test        - Run automated tests, regression invariants, and linting"
	@echo "  make submodules  - Initialize and update all git submodules"
	@echo "  make patch       - Apply kernel and driver patches"
	@echo "  make bootloader  - Build U-Boot, IDBlock, and Env (TARGET_MEDIUM=sd_card|emmc)"
	@echo "  make kernel      - Build patched Linux kernel (boot.img)"
	@echo "                     Options: TARGET_MEDIUM=sd_card (default, Lite) or emmc"
	@echo "  make apps        - Build all userland applications (display, video, app)"
	@echo "  make display     - Build kvm_display (touchscreen LVGL UI)"
	@echo "  make video       - Build kvm_video (hardware H.264/H.265 encoder)"
	@echo "  make app         - Build kvm_app (Go backend & web server)"
	@echo "  make sd-image    - Generate bootable raw SD card image for dd/Etcher"
	@echo "                     Options: TARGET_MEDIUM=sd_card (default, Lite) or emmc"
	@echo "  make ota         - Package OTA update zip for Web UI flashing"
	@echo "  make clean       - Remove compiled artifacts"

