#!/bin/bash

######################## Prepare sub-iamges and pack ####################
#$0 is this file path
#$1 is buildroot output images dir
set -e
IMGS_DIR=$1
BR2_LINUX_KERNEL_IMAGE_TARGET_NAME=$2
DEVICE_DIR=$(dirname $0)

SRC_ROOTFS_FILE="$DEVICE_DIR/rootfs.ext4"
PARTITIONS_FILE="$DEVICE_DIR/partition_universal.json"
UENV_TXT_FILE="$DEVICE_DIR/env_k3.txt"
UBOOT_LOGO_FILE="$DEVICE_DIR/firefly.bmp"


solution_name=$(echo "$IMGS_DIR" | awk -F'/' '{print $(NF-1)}')
#Give a chance to CI
if [ -z "$BIANBU_LINUX_ARCHIVE" ]; then
    TARGET_IMAGE_ZIP="$IMGS_DIR/Buildroot-${solution_name}-$(date +%Y%m%d%H%M%S).zip"
    SDCARD_IMAGE="Buildroot-${solution_name}-$(date +%Y%m%d%H%M%S)-sdcard.img"
else
    TARGET_IMAGE_ZIP="$BIANBU_LINUX_ARCHIVE.zip"
    SDCARD_IMAGE="$BIANBU_LINUX_ARCHIVE-sdcard.img"
fi

TARGET_ROOTFS_FILE="$IMGS_DIR/rootfs.ext2"
TARGET_BOOTFS_FILE="$IMGS_DIR/bootfs.img"
TARGET_INITRAMFS_FILE=("$IMGS_DIR/rootfs.cpio.gz")
#TARGET_INITRAMFS_FILE=("$IMGS_DIR/rootfs.cpio.uboot")

BOOTFS_SIZE=$($IMGS_DIR/../host/bin/jq '.partitions[] | select(.name == "bootfs") | .size' "$PARTITIONS_FILE")
BOOTFS_DIR="$IMGS_DIR/bootfs"
BOOTFS_IMG_FILE="$IMGS_DIR/bootfs.img"

UBOOT_ITB_FILE="$IMGS_DIR/u-boot.itb"
OPENSBI_ITB_FILE="$IMGS_DIR/fw_dynamic.itb"
ESOS_ITB_FILE="$IMGS_DIR/esos.itb"

KERNEL_DTB_NAME="*.dtb"
KERNEL_DTB_FILE="$IMGS_DIR/$KERNEL_DTB_NAME"
KERNEL_IMAGE_FILE="$IMGS_DIR/$BR2_LINUX_KERNEL_IMAGE_TARGET_NAME"

FAKE_ROOT_FILE=/tmp/$(whoami)-fakeroot

#Pack kernel image and initramfs
gen_bootfs_vfat() {
    echo -e "\n"
    echo "Starting to build bootfs ..............................."

    echo "#!/bin/sh" > "$FAKE_ROOT_FILE"
    echo "set -e" >> "$FAKE_ROOT_FILE"
    echo "rm -rf $BOOTFS_DIR" >> "$FAKE_ROOT_FILE"
    echo "mkdir -p $BOOTFS_DIR" >> "$FAKE_ROOT_FILE"

    echo "rm -f $BOOTFS_IMG_FILE" >> "$FAKE_ROOT_FILE"
    echo "dd if=/dev/zero of=$BOOTFS_IMG_FILE count=1 bs=$BOOTFS_SIZE" >> "$FAKE_ROOT_FILE"
    echo "mkfs.vfat -S 4096 $BOOTFS_IMG_FILE" >> "$FAKE_ROOT_FILE"

    echo "cp -f $UENV_TXT_FILE $BOOTFS_DIR/" >> "$FAKE_ROOT_FILE"
    echo "cp -f $UBOOT_LOGO_FILE $BOOTFS_DIR/" >> "$FAKE_ROOT_FILE"
    echo "cp -f $KERNEL_IMAGE_FILE $BOOTFS_DIR/" >> "$FAKE_ROOT_FILE"
    echo "cp -f $KERNEL_DTB_FILE $BOOTFS_DIR/" >> "$FAKE_ROOT_FILE"
    echo "cp -f $TARGET_INITRAMFS_FILE $BOOTFS_DIR/initramfs-generic.img" >> "$FAKE_ROOT_FILE"
    echo "mcopy -i $BOOTFS_IMG_FILE $BOOTFS_DIR/* ::" >> "$FAKE_ROOT_FILE"
    echo "fsck.vfat -v -n $BOOTFS_IMG_FILE" >> "$FAKE_ROOT_FILE"

    chmod 777 "$FAKE_ROOT_FILE"
    FAKEROOTDONTTRYCHOWN=1 "$IMGS_DIR/../host/bin/fakeroot" -- "$FAKE_ROOT_FILE"

    if [ $? -ne 0 ]; then
        echo "Building bootfs failed. Please check for errors..............."
        exit 1
    fi
    echo "Bootfs build successful................................."
    echo -e "\n"
}

override_rootfs_img() {
    #override rootfs.ext4 if needed
    if [ -f "$SRC_ROOTFS_FILE" ]; then
        cp -rf ${SRC_ROOTFS_FILE} ${TARGET_ROOTFS_FILE}
        echo "Successfully overridden ${TARGET_ROOTFS_FILE} with ${SRC_ROOTFS_FILE}"
	e2fsck -f ${TARGET_ROOTFS_FILE}
	resize2fs ${TARGET_ROOTFS_FILE}
    fi
}

gen_sub_images() {

    #env.bin
    cp -f ${IMGS_DIR}/u-boot-env-default.bin ${IMGS_DIR}/env.bin

}

update_genimage_cfg() {
    #Update sd-geimage.cfg
    $PWD/../scripts/gen_imgcfg.py -i ${PARTITIONS_FILE} -n ${SDCARD_IMAGE} -o ${IMGS_DIR}/genimage.cfg
}

gen_sdcard_img() {
    echo "Generating sdcard image..................................."
    $PWD/support/scripts/genimage.sh -c ${IMGS_DIR}/genimage.cfg
    if [ $? -ne 0 ]; then
        echo "Generating failed. Please check for errors..............."
        exit 1
    fi
    echo "Successfully generated at ${IMGS_DIR}/${SDCARD_IMAGE}"
}

pack_image_zip() {
    echo "Starting to pack images................................."
    rm -f ${TARGET_IMAGE_ZIP}
    rm -rf ${IMGS_DIR}/factory

    mkdir -p ${IMGS_DIR}/factory
    cp -f ${IMGS_DIR}/FSBL.bin ${IMGS_DIR}/factory/
    cp -f ${IMGS_DIR}/bootinfo_*.bin ${IMGS_DIR}/factory/
    cp -f ${DEVICE_DIR}/fastboot.yaml ${IMGS_DIR}/
    cp -f ${DEVICE_DIR}/partition_*.json ${IMGS_DIR}/
    #cp -f ${DEVICE_DIR}/partition_universal.json ${IMGS_DIR}/
    cd ${IMGS_DIR}
    zip ${TARGET_IMAGE_ZIP} \
        fw_dynamic.itb \
        u-boot.itb \
        esos.itb \
        env.bin \
        bootfs.img \
        rootfs.ext4 \
        partition_*.json \
        fastboot.yaml \
        genimage.cfg \
        -r factory

    #Give a chance to CI
    if [ -n "$BIANBU_LINUX_ARCHIVE_LATEST" ]; then
        ln -sf ${TARGET_IMAGE_ZIP} $BIANBU_LINUX_ARCHIVE_LATEST
    fi

    #rm -f fastboot.yaml \
    #    partition_2M.json
    #    partition_universal.json \
    cd - >/dev/null
 
    echo "Images successfully packed into ${TARGET_IMAGE_ZIP}"
    echo -e "\n"
}


#include env and Image
gen_sub_images

#Gen bootfs
gen_bootfs_vfat

#For Debian or Ubuntu rootfs override
override_rootfs_img

#Update genimage cfg because pack_image_zip dependis on it
update_genimage_cfg

#Pack images in zip
pack_image_zip

#Gen sdcard.img if need
gen_sdcard_img

