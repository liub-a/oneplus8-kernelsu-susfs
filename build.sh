#!/bin/bash
set -e

# Configuration - can be overridden via environment variables
# Using official LineageOS kernel source
KERNEL_SOURCE="${KERNEL_SOURCE:-https://github.com/LineageOS/android_kernel_oneplus_sm8250.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.0}"
DEFCONFIG="${DEFCONFIG:-vendor/kona-perf_defconfig}"
DEVICE_NAME="${DEVICE_NAME:-OnePlus8_Series}"
KERNELSU_VARIANT="${KERNELSU_VARIANT:-ksu}"
KERNELSU_REF="${KERNELSU_REF:-v0.9.5}"
SUSFS_ENABLED="${SUSFS_ENABLED:-true}"
PATCHES_REPO="${PATCHES_REPO:-JackA1ltman/NonGKI_Kernel_Patches}"
PATCHES_BRANCH="${PATCHES_BRANCH:-op_kernel}"
SUSFS_BRANCH="${SUSFS_BRANCH:-kernel-4.19}"
SUSFS_USE_LOCAL="${SUSFS_USE_LOCAL:-true}"
ALLOW_EXPERIMENTAL_SUSFS_VARIANT="${ALLOW_EXPERIMENTAL_SUSFS_VARIANT:-false}"

# Paths are evaluated from inside kernel_source when applying SUSFS.
SUSFS_LOCAL_PATCH_DIR="${SUSFS_LOCAL_PATCH_DIR:-../susfs-patches}"
SUSFS_LOCAL_SOURCE_DIR="${SUSFS_LOCAL_SOURCE_DIR:-../susfs-v2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Clone kernel source
clone_kernel() {
    log "Cloning kernel source..."
    if [ -d "kernel_source" ]; then
        log "Kernel source already exists, pulling latest..."
        cd kernel_source && git pull || true
        cd ..
    else
        git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE" kernel_source
    fi
}

# Clone auxiliary patches repo only when local patches are absent.
clone_patches() {
    if [ -d "patches" ]; then
        log "Local patches directory exists, skipping external patch clone"
        return
    fi

    log "Cloning patches repo..."
    git clone --depth=1 -b "$PATCHES_BRANCH" "https://github.com/$PATCHES_REPO.git" patches
}

# Fix vDSO compilation for Clang + GNU assembler
fix_vdso() {
    log "Fixing vDSO compilation for Clang compatibility..."
    cd kernel_source

    VDSO_MAKEFILE="arch/arm64/kernel/vdso/Makefile"
    if [ -f "$VDSO_MAKEFILE" ]; then
        log "Patching vDSO Makefile..."
        if ! grep -q -- "-g0" "$VDSO_MAKEFILE"; then
            echo 'ccflags-y += -g0' >> "$VDSO_MAKEFILE"
        fi
        log "vDSO Makefile patched"
    fi

    VDSO32_MAKEFILE="arch/arm64/kernel/vdso32/Makefile"
    if [ -f "$VDSO32_MAKEFILE" ]; then
        log "Patching vDSO32 Makefile..."
        if ! grep -q -- "-g0" "$VDSO32_MAKEFILE"; then
            echo 'ccflags-y += -g0' >> "$VDSO32_MAKEFILE"
        fi
    fi

    cd ..
}

# Setup KernelSU based on variant
setup_kernelsu() {
    log "Setting up KernelSU (variant: $KERNELSU_VARIANT)..."
    cd kernel_source

    case "$KERNELSU_VARIANT" in
        ksu)
            log "Setting up original KernelSU (tiann, ref: $KERNELSU_REF)..."
            curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KERNELSU_REF"
            ;;
        sukisu)
            log "Setting up SukiSU-Ultra..."
            curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s main
            ;;
        next)
            log "Setting up KernelSU-Next (legacy)..."
            curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy/kernel/setup.sh" | bash -s legacy
            ;;
        rsuntk)
            log "Setting up rsuntk KernelSU..."
            curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s main
            ;;
        *)
            error "Unknown KernelSU variant: $KERNELSU_VARIANT"
            ;;
    esac

    cd ..
}

ensure_susfs4ksu_repo() {
    if [ -d "susfs4ksu" ]; then
        return
    fi

    log "Cloning susfs4ksu ($SUSFS_BRANCH branch) for KernelSU integration patch..."
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git -b "$SUSFS_BRANCH" susfs4ksu || \
    git clone --depth=1 https://github.com/sidex15/susfs4ksu.git -b "$SUSFS_BRANCH" susfs4ksu
}

apply_ksu_susfs_patch() {
    local ksu_dir="$1"
    local ksu_patch=""

    if [ -f "../susfs-patches/10_enable_susfs_for_ksu.patch" ]; then
        ksu_patch="../susfs-patches/10_enable_susfs_for_ksu.patch"
    elif [ -f "../patches/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
        ksu_patch="../patches/KernelSU/10_enable_susfs_for_ksu.patch"
    else
        ensure_susfs4ksu_repo
        ksu_patch="susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
    fi

    [ -f "$ksu_patch" ] || error "Missing KernelSU SUSFS patch: $ksu_patch"

    log "Step 3: Applying KernelSU SUSFS patch: $ksu_patch"
    cp "$ksu_patch" "$ksu_dir/10_enable_susfs_for_ksu.patch"

    cd "$ksu_dir"
    find . -name "*.rej" -delete

    if patch -p1 < 10_enable_susfs_for_ksu.patch; then
        cd ..
        return
    fi

    # KernelSU v0.9.5 usually only conflicts on the final selinux.c hunk.
    # The local helper intentionally patches that exact missing SUSFS SELinux function block.
    local reject_count
    reject_count=$(find . -name "*.rej" | wc -l | tr -d ' ')
    if [ "$reject_count" = "1" ] && [ -f "kernel/selinux/selinux.c.rej" ] && [ -f "../../add_susfs_functions.sh" ]; then
        warn "KernelSU SUSFS patch left only kernel/selinux/selinux.c.rej; applying local fallback"
        bash ../../add_susfs_functions.sh kernel/selinux/selinux.c || error "Failed to apply selinux.c SUSFS fallback"
        rm -f kernel/selinux/selinux.c.rej
        cd ..
        return
    fi

    warn "KernelSU SUSFS patch failed with rejects:"
    find . -name "*.rej" -print -exec cat {} \;
    error "Failed to apply KernelSU SUSFS patch"
}

apply_patch_file() {
    local patch_file="$1"
    local label
    label=$(basename "$patch_file")

    [ -f "$patch_file" ] || error "Missing patch: $patch_file"
    log "Applying local SUSFS kernel patch: $label"

    find . -name "*.rej" -delete

    if patch --forward --dry-run -p1 < "$patch_file" >/tmp/susfs_patch_check.log 2>&1; then
        patch --forward -p1 < "$patch_file" || error "Failed to apply $label"
        return
    fi

    if patch --reverse --dry-run -p1 < "$patch_file" >/tmp/susfs_patch_reverse_check.log 2>&1; then
        warn "$label appears to be already applied, skipping"
        return
    fi

    warn "Dry-run failed for $label:"
    cat /tmp/susfs_patch_check.log || true
    error "Failed to apply local SUSFS kernel patch: $label"
}

apply_local_susfs_kernel_files() {
    [ -d "$SUSFS_LOCAL_SOURCE_DIR" ] || error "Local SUSFS source directory not found: $SUSFS_LOCAL_SOURCE_DIR"
    [ -d "$SUSFS_LOCAL_PATCH_DIR" ] || error "Local SUSFS patch directory not found: $SUSFS_LOCAL_PATCH_DIR"

    log "Using local SUSFS source: $SUSFS_LOCAL_SOURCE_DIR"
    log "Using local SUSFS patches: $SUSFS_LOCAL_PATCH_DIR"

    cp -v "$SUSFS_LOCAL_SOURCE_DIR/susfs.c" fs/susfs.c || error "Failed to copy susfs.c"
    cp -v "$SUSFS_LOCAL_SOURCE_DIR/susfs.h" include/linux/susfs.h || error "Failed to copy susfs.h"
    cp -v "$SUSFS_LOCAL_SOURCE_DIR/susfs_def.h" include/linux/susfs_def.h || error "Failed to copy susfs_def.h"

    # 00_add_susfs_source.patch creates fs/susfs.c; source is copied above, so skip it.
    for patch_file in \
        "$SUSFS_LOCAL_PATCH_DIR/01_add_susfs_hooks.patch" \
        "$SUSFS_LOCAL_PATCH_DIR/02_add_susfs_misc.patch" \
        "$SUSFS_LOCAL_PATCH_DIR/03_fix_exec.patch" \
        "$SUSFS_LOCAL_PATCH_DIR/04_fix_namespace_clone_mnt.patch" \
        "$SUSFS_LOCAL_PATCH_DIR/05_fix_task_mmu.patch"; do
        if [ -f "$patch_file" ]; then
            apply_patch_file "$patch_file"
        else
            warn "Optional local SUSFS patch missing: $patch_file"
        fi
    done
}

apply_upstream_susfs_kernel_files() {
    ensure_susfs4ksu_repo

    log "Copying upstream SUSFS source files..."
    cp -v susfs4ksu/kernel_patches/fs/* fs/ || error "Failed to copy SUSFS fs source files"
    cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/ || error "Failed to copy SUSFS include files"

    log "Applying upstream kernel SUSFS patch..."
    cp susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch ./ || error "Missing 50_add_susfs_in_kernel-4.19.patch"
    patch -p1 < 50_add_susfs_in_kernel-4.19.patch || error "Failed to apply kernel SUSFS patch"
}

# Apply SUSFS patches
apply_susfs() {
    if [ "$SUSFS_ENABLED" != "true" ]; then
        log "SUSFS disabled, skipping..."
        return
    fi

    if [ "$KERNELSU_VARIANT" != "ksu" ] && [ "$ALLOW_EXPERIMENTAL_SUSFS_VARIANT" != "true" ]; then
        error "SUSFS_BRANCH=$SUSFS_BRANCH uses the old 4.19 KernelSU patch set. Use KERNELSU_VARIANT=ksu, or port matching SuSFS v2 kernel-side patches for $KERNELSU_VARIANT. Set ALLOW_EXPERIMENTAL_SUSFS_VARIANT=true only if you know this patch set matches."
    fi

    log "Applying SUSFS patches..."
    cd kernel_source

    KSU_DIR=$(find . -maxdepth 1 -type d -name "KernelSU*" | head -1)
    [ -n "$KSU_DIR" ] && [ -d "$KSU_DIR" ] || error "KernelSU directory not found after setup_kernelsu"
    log "KernelSU directory: $KSU_DIR"

    log "Step 1: Reverting kprobe commit in KernelSU..."
    cd "$KSU_DIR"
    git revert --no-commit 898e9d4f8ca9b2f46b0c6b36b80a872b5b88d899 2>/dev/null || log "Revert may not be needed for this version"
    cd ..

    log "Step 2: Disabling kprobes in KernelSU..."
    find "$KSU_DIR" \( -name "*.c" -o -name "*.h" \) -print0 | \
        xargs -0 sed -i 's/#ifdef CONFIG_KPROBES/#if defined(CONFIG_KPROBES) \&\& 0/g'
    find "$KSU_DIR" \( -name "*.c" -o -name "*.h" \) -print0 | \
        xargs -0 sed -i 's/#if defined(CONFIG_KPROBES)/#if defined(CONFIG_KPROBES) \&\& 0/g'

    apply_ksu_susfs_patch "$KSU_DIR"

    if [ "$SUSFS_USE_LOCAL" = "true" ] && [ -d "$SUSFS_LOCAL_SOURCE_DIR" ] && [ -d "$SUSFS_LOCAL_PATCH_DIR" ]; then
        apply_local_susfs_kernel_files
    else
        warn "Local SUSFS files unavailable or disabled; falling back to upstream susfs4ksu"
        apply_upstream_susfs_kernel_files
    fi

    if [ -f "../patches/kona_cos15_a15/susfs_fixed.patch" ]; then
        log "Applying device-specific SUSFS fixes..."
        patch -p1 < ../patches/kona_cos15_a15/susfs_fixed.patch || warn "Device patch may already be applied"
    fi

    cd ..
}

# Apply VFS hook patches
apply_vfs_patches() {
    log "Applying VFS hook patches..."
    cd kernel_source
    if [ -f "../patches/vfs_hook_patches.sh" ]; then
        bash ../patches/vfs_hook_patches.sh || warn "VFS patches may already be applied"
    fi
    cd ..
}

# Configure kernel
configure_kernel() {
    log "Configuring kernel..."
    cd kernel_source

    make O=out ARCH=arm64 CC=clang \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE=aarch64-linux-android- \
        CROSS_COMPILE_ARM32=arm-linux-androideabi- \
        "$DEFCONFIG"

    ./scripts/config --file out/.config -e KSU

    if [ "$SUSFS_ENABLED" = "true" ]; then
        ./scripts/config --file out/.config -e KSU_SUSFS || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SUS_PATH || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SUS_MOUNT || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SUS_KSTAT || true
        ./scripts/config --file out/.config -e KSU_SUSFS_TRY_UMOUNT || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SPOOF_UNAME || true
        ./scripts/config --file out/.config -e KSU_SUSFS_ENABLE_LOG || true
        ./scripts/config --file out/.config -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG || true
        ./scripts/config --file out/.config -e KSU_SUSFS_OPEN_REDIRECT || true
        ./scripts/config --file out/.config -e KSU_SUSFS_SUS_MAP || true
    fi

    make O=out ARCH=arm64 olddefconfig

    cd ..
}

# Build kernel
build_kernel() {
    log "Building kernel..."
    cd kernel_source

    CPUS=$(nproc --all)

    yes "" | make -j"$CPUS" O=out ARCH=arm64 CC=clang \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE=aarch64-linux-android- \
        CROSS_COMPILE_ARM32=arm-linux-androideabi- \
        LLVM_IAS=1 \
        LD=ld.lld \
        AR=llvm-ar \
        NM=llvm-nm \
        OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump \
        STRIP=llvm-strip \
        2>&1 | tee build.log

    cd ..
}

# Check build result
check_build() {
    cd kernel_source
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        error "Kernel image not found! Build failed."
    fi
    log "Kernel built successfully!"
    ls -la out/arch/arm64/boot/
    cd ..
}

# Package kernel with AnyKernel3
package_kernel() {
    log "Packaging kernel..."
    cd kernel_source

    if [ ! -d "AnyKernel3" ]; then
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    fi

    cd AnyKernel3
    rm -rf .git modules patch ramdisk

    cp ../out/arch/arm64/boot/Image .
    [ -f "../out/arch/arm64/boot/dtb" ] && cp ../out/arch/arm64/boot/dtb .
    [ -f "../out/arch/arm64/boot/dtbo.img" ] && cp ../out/arch/arm64/boot/dtbo.img .

    sed -i "s/do.devicecheck=.*/do.devicecheck=1/g" anykernel.sh
    sed -i "s/do.modules=.*/do.modules=0/g" anykernel.sh
    sed -i "s/device.name1=.*/device.name1=instantnoodle/g" anykernel.sh
    sed -i "s/device.name2=.*/device.name2=instantnoodlep/g" anykernel.sh
    grep -q "^device.name3=" anykernel.sh && sed -i "s/device.name3=.*/device.name3=kebab/g" anykernel.sh || echo "device.name3=kebab" >> anykernel.sh
    grep -q "^device.name4=" anykernel.sh && sed -i "s/device.name4=.*/device.name4=lemonades/g" anykernel.sh || echo "device.name4=lemonades" >> anykernel.sh
    sed -i "s|block=.*|block=/dev/block/bootdevice/by-name/boot;|g" anykernel.sh
    sed -i "s/is_slot_device=.*/is_slot_device=1;/g" anykernel.sh

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    SUSFS_TAG=""
    [ "$SUSFS_ENABLED" = "true" ] && SUSFS_TAG="_SUSFS"
    ZIP_NAME="KernelSU-${KERNELSU_VARIANT}${SUSFS_TAG}_${DEVICE_NAME}_${TIMESTAMP}.zip"
    zip -r9 "/output/$ZIP_NAME" * -x .git README.md '*placeholder*'

    log "Created: /output/$ZIP_NAME"
    cd ../..

    cp kernel_source/out/arch/arm64/boot/Image /output/ 2>/dev/null || true
}

main() {
    log "=== OnePlus SM8250 Kernel Build with KernelSU + SUSFS ==="
    log "Kernel Source: $KERNEL_SOURCE"
    log "Branch: $KERNEL_BRANCH"
    log "Defconfig: $DEFCONFIG"
    log "KernelSU Variant: $KERNELSU_VARIANT"
    log "KernelSU Ref: $KERNELSU_REF"
    log "SUSFS Enabled: $SUSFS_ENABLED"
    log "SUSFS Use Local: $SUSFS_USE_LOCAL"
    log ""

    clone_kernel
    clone_patches
    fix_vdso
    setup_kernelsu
    apply_susfs
    apply_vfs_patches
    configure_kernel
    build_kernel
    check_build
    package_kernel

    log "=== Build Complete! ==="
    log "Output files are in /output directory"
}

main "$@"
