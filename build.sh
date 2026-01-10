#!/bin/bash

abort()
{
    cd -
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit -1
}

unset_flags()
{
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -s, --susfs [y/N]      Include SuSFS
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --susfs|-s)
            SUSFS_OPTION="$2"
            shift 2
            ;;
        *)
            unset_flags
            exit 1
            ;;
    esac
done

echo "Preparing the build environment..."

pushd $(dirname "$0") > /dev/null
CORES=`cat /proc/cpuinfo | grep -c processor`

# Define toolchain variables
CLANG_DIR=$PWD/toolchain/clang-r416183b
PATH=$CLANG_DIR/bin:$CLANG_DIR/lib:$PATH

MAKE_ARGS="
ARCH=arm64 \
LLVM=1 \
LLVM_IAS=1 \
CC=clang \
READELF=$CLANG_DIR/bin/llvm-readelf \
O=out
"

# --- Model Configuration ---
case $MODEL in
    beyond0lte)   BOARD=SRPRI28A016KU; SOC=exynos9820; TZDEV=new ;;
    beyond0lteks) BOARD=SRPRI28C007KU; SOC=exynos9820; TZDEV=new ;;
    beyond1lte)   BOARD=SRPRI28B016KU; SOC=exynos9820; TZDEV=new ;;
    beyond1lteks) BOARD=SRPRI28D007KU; SOC=exynos9820; TZDEV=new ;;
    beyond2lte)   BOARD=SRPRI17C016KU; SOC=exynos9820; TZDEV=new ;;
    beyond2lteks) BOARD=SRPRI28E007KU; SOC=exynos9820; TZDEV=new ;;
    beyondx)      BOARD=SRPSC04B014KU; SOC=exynos9820; TZDEV=new ;;
    beyondxks)    BOARD=SRPRK21D006KU; SOC=exynos9820; TZDEV=new ;;
    d1)           BOARD=SRPSD26B009KU; SOC=exynos9825; TZDEV=old ;;
    d1xks)        BOARD=SRPSD23A002KU; SOC=exynos9825; TZDEV=new ;;
    d2s)          BOARD=SRPSC14B009KU; SOC=exynos9825; TZDEV=old ;;
    d2x)          BOARD=SRPSC14C009KU; SOC=exynos9825; TZDEV=old ;;
    d2xks)        BOARD=SRPSD23C002KU; SOC=exynos9825; TZDEV=new ;;
    *) unset_flags; exit ;;
esac

KERNEL_DEFCONFIG=extreme_"$MODEL"_defconfig
DEFCONFIG_PATH="arch/arm64/configs/$KERNEL_DEFCONFIG"

# --- Feature Selection ---
if [ -z "$KSU_OPTION" ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

if [ -z "$SUSFS_OPTION" ]; then
    read -p "Include SuSFS (y/N): " SUSFS_OPTION
fi

# --- Inject SuSFS into Defconfig ---
if [[ "$SUSFS_OPTION" == "y" ]]; then
    echo "Injecting SuSFS configs into $KERNEL_DEFCONFIG..."
    
    # Remove existing SuSFS configs to avoid duplicates
    sed -i '/CONFIG_KSU_SUSFS/d' "$DEFCONFIG_PATH"
    
    # Append the new SuSFS configs
    cat << EOF >> "$DEFCONFIG_PATH"
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=n
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=n
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=n
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=y
EOF
    
    SUSFS_HEADER="include/linux/susfs.h"
    if [ -f "$SUSFS_HEADER" ]; then
        SUSFS_VERSION=$(grep -E '^#define[[:space:]]+SUSFS_VERSION' "$SUSFS_HEADER" | awk '{print $3}' | tr -d '"')
    fi
fi

# Cleanup previous builds
rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

# --- Build Kernel Image ---
echo "-----------------------------------------------"
echo "Defconfig: $KERNEL_DEFCONFIG"
echo "KSU: ${KSU_OPTION:-n}"
echo "SuSFS: ${SUSFS_OPTION:-n} ${SUSFS_VERSION}"
echo "-----------------------------------------------"

# TZDEV Switching logic
if [ "$TZDEV" == "new" ] && [ ! -e "drivers/misc/tzdev/umem.c" ]; then
    echo "Switching to new TZDEV..."
    rm -rf drivers/misc/tzdev out/drivers/misc/tzdev
    mkdir -p drivers/misc/tzdev
    cp -a build/tzdev/new/* drivers/misc/tzdev
elif [ "$TZDEV" == "old" ] && [ -e "drivers/misc/tzdev/umem.c" ]; then
    echo "Switching to old TZDEV..."
    rm -rf drivers/misc/tzdev out/drivers/misc/tzdev
    mkdir -p drivers/misc/tzdev
    cp -a build/tzdev/old/* drivers/misc/tzdev
fi

if [[ "$SOC" == "exynos9825" ]]; then
    N10=9825.config
fi

echo "Building kernel using $KERNEL_DEFCONFIG"
echo "Generating configuration file..."
echo "-----------------------------------------------"
make ${MAKE_ARGS} -j$CORES $KERNEL_DEFCONFIG extreme.config $KSU $N10 || abort

echo "Building kernel binary..."
echo "-----------------------------------------------"
make ${MAKE_ARGS} -j$CORES || abort

# --- Image Creation (dtb, dtbo, ramdisk, mkbootimg) ---
KERNEL_PATH=build/out/$MODEL/Image
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0xF0000000
SECOND_OFFSET=0xF0000000
TAGS_OFFSET=0x00000100
BASE=0x10000000
CMDLINE='loop.max_part=7'
HASHTYPE=sha1
HEADER_VERSION=1
OS_PATCH_LEVEL=2024-08
OS_VERSION=14.0.0
PAGESIZE=2048
RAMDISK=build/out/$MODEL/ramdisk.cpio.gz
OUTPUT_FILE=build/out/$MODEL/boot.img

cp out/arch/arm64/boot/Image build/out/$MODEL

if [[ "$SOC" == "exynos9820" ]]; then
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9820.cfg -d out/arch/arm64/boot/dts/exynos
elif [[ "$SOC" == "exynos9825" ]]; then
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9825.cfg -d out/arch/arm64/boot/dts/exynos
fi

./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

pushd build/ramdisk > /dev/null
find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
popd > /dev/null

./toolchain/mkbootimg --base $BASE --board $BOARD --cmdline "$CMDLINE" --hashtype $HASHTYPE \
--header_version $HEADER_VERSION --kernel $KERNEL_PATH --kernel_offset $KERNEL_OFFSET \
--os_patch_level $OS_PATCH_LEVEL --os_version $OS_VERSION --pagesize $PAGESIZE \
--ramdisk $RAMDISK --ramdisk_offset $RAMDISK_OFFSET --second_offset $SECOND_OFFSET \
--tags_offset $TAGS_OFFSET -o $OUTPUT_FILE || abort

# --- Packaging ---
cp build/out/$MODEL/boot.img build/out/$MODEL/zip/files/boot.img
cp build/out/$MODEL/dtb.img build/out/$MODEL/zip/files/dtb.img
cp build/out/$MODEL/dtbo.img build/out/$MODEL/zip/files/dtbo.img
cp build/update-binary build/out/$MODEL/zip/META-INF/com/google/android/update-binary
cp build/updater-script build/out/$MODEL/zip/META-INF/com/google/android/updater-script

if [ "$SOC" == "exynos9825" ]; then
    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/9825.config | cut -d '"' -f 2)
else
    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/extreme.config | cut -d '"' -f 2)
fi
version=${version:1}

pushd build/out/$MODEL/zip > /dev/null
DATE=`date +"%d-%m-%Y_%H-%M-%S"`    

NAME="${version}_${MODEL}_UNOFFICIAL"
[[ "$KSU_OPTION" == "y" ]] && NAME="${NAME}_KSU"
[[ "$SUSFS_OPTION" == "y" ]] && NAME="${NAME}_SuSFS"
NAME="${NAME}_${DATE}.zip"

zip -r -qq ../"$NAME" .
popd > /dev/null
popd > /dev/null

echo "Build finished successfully: $NAME"
