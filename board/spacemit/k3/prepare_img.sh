#!/bin/bash

######################## Prepare sub-iamges and pack ####################
#$0 is this file path
#$1 is buildroot output images dir
set -e
IMGS_DIR=$1
BR2_LINUX_KERNEL_IMAGE_TARGET_NAME=$2
DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)

PARTITIONS_FILE="$DEVICE_DIR/partition_universal.json"
UENV_TXT_FILE="$DEVICE_DIR/env_k3.txt"
UBOOT_LOGO_FILE="$DEVICE_DIR/firefly.bmp"

find_manifest_file() {
    local sdk_dir manifest_file

    # BR2_EXTERNAL_Bianbu_PATH is /build/buildroot-ext in Docker and the
    # corresponding source directory in a direct/local build.
    if [ -n "${BR2_EXTERNAL_Bianbu_PATH:-}" ]; then
        sdk_dir=$(cd "$BR2_EXTERNAL_Bianbu_PATH/.." && pwd)
        manifest_file="$sdk_dir/.repo/manifest.xml"
        if [ -f "$manifest_file" ]; then
            printf '%s' "$manifest_file"
            return 0
        fi
    fi

    # The post-image script remains under buildroot-ext/board/spacemit/k3.
    sdk_dir=$(cd "$DEVICE_DIR/../../../.." && pwd)
    manifest_file="$sdk_dir/.repo/manifest.xml"
    if [ -f "$manifest_file" ]; then
        printf '%s' "$manifest_file"
        return 0
    fi

    # Explicit fallback for the standard Docker source mount.
    if [ -f "/build/.repo/manifest.xml" ]; then
        printf '%s' "/build/.repo/manifest.xml"
        return 0
    fi

    echo "Cannot find .repo/manifest.xml (checked Buildroot external tree and /build)" >&2
    return 1
}

MANIFEST_FILE=$(find_manifest_file)
SDK_DIR=$(cd "$(dirname "$MANIFEST_FILE")/.." && pwd)
MANIFESTS_DIR="$SDK_DIR/.repo/manifests"

extract_manifest_tag() {
    local manifest_file=$1 tag

    # Support a tag attribute, a <tag> element and repo's refs/tags/<tag>
    # revision form. Release manifests may use any of these forms.
    tag=$(sed -n 's/.*[[:space:]]tag="\([^"]*\)".*/\1/p' "$manifest_file" | head -n 1)
    if [ -z "$tag" ]; then
        tag=$(sed -n 's|.*<tag[^>]*>\([^<]*\)</tag>.*|\1|p' "$manifest_file" | head -n 1)
    fi
    if [ -z "$tag" ]; then
        tag=$(sed -n 's|.*revision="refs/tags/\([^"]*\)".*|\1|p' "$manifest_file" | head -n 1)
    fi
    if [ -z "$tag" ]; then
        tag=$(sed -n 's|.*revision="\(v[0-9][^"]*\)".*|\1|p' "$manifest_file" | head -n 1)
    fi

    printf '%s' "$tag"
}

get_manifest_tag_from_file() {
    local manifest_file=$1 depth=${2:-0}
    local tag include_name included_file

    [ -f "$manifest_file" ] || return 0
    [ "$depth" -lt 8 ] || {
        echo "Manifest include nesting is too deep: $manifest_file" >&2
        return 1
    }

    tag=$(extract_manifest_tag "$manifest_file")
    if [ -n "$tag" ]; then
        printf '%s' "$tag"
        return 0
    fi

    while IFS= read -r include_name; do
        included_file="$MANIFESTS_DIR/$include_name"
        tag=$(get_manifest_tag_from_file "$included_file" $((depth + 1)))
        if [ -n "$tag" ]; then
            printf '%s' "$tag"
            return 0
        fi
    done < <(sed -n 's/.*<include[^>]*name="\([^"]*\)".*/\1/p' "$manifest_file")
}

get_manifest_tag() {
    local tag

    [ -f "$MANIFEST_FILE" ] || {
        echo "Manifest file not found: $MANIFEST_FILE" >&2
        return 1
    }

    tag=$(get_manifest_tag_from_file "$MANIFEST_FILE")

    # A repo release revision may include a namespace, for example:
    # refs/tags/k3/linux6.18_release_v1.0.0a. Only the version component is
    # suitable for use in the firmware filename.
    if [[ "$tag" =~ (v[0-9][[:alnum:]._-]*)$ ]]; then
        tag=${BASH_REMATCH[1]}
    else
        tag=${tag##*/}
    fi

    printf '%s' "$tag"
}

normalize_rootfs_name() {
    local rootfs_name=${1//_/-}
    local lower_name=${rootfs_name,,}
    local distro_name remainder first_field
    local version_name="" version_suffix="" desktop_name=""

    # Keep only the known distribution prefix. Everything following it is
    # considered metadata unless the first field is a known desktop name.
    case "$lower_name" in
        buildroot*)
            distro_name="Buildroot"; remainder=${lower_name#buildroot} ;;
        bianbu*)
            distro_name="Bianbu"; remainder=${lower_name#bianbu} ;;
        ubuntu*)
            distro_name="Ubuntu"; remainder=${lower_name#ubuntu} ;;
        open-harmony*)
            distro_name="OpenHarmony"; remainder=${lower_name#open-harmony} ;;
        openharmony*)
            distro_name="OpenHarmony"; remainder=${lower_name#openharmony} ;;
        debian*)
            distro_name="Debian"; remainder=${lower_name#debian} ;;
        open-kylin*)
            distro_name="openKylin"; remainder=${lower_name#open-kylin} ;;
        openkylin*)
            distro_name="openKylin"; remainder=${lower_name#openkylin} ;;
        fedora*)
            distro_name="Fedora"; remainder=${lower_name#fedora} ;;
        open-euler*)
            distro_name="openEuler"; remainder=${lower_name#open-euler} ;;
        openeuler*)
            distro_name="openEuler"; remainder=${lower_name#openeuler} ;;
        deepin*)
            distro_name="Deepin"; remainder=${lower_name#deepin} ;;
        armbian*)
            distro_name="Armbian"; remainder=${lower_name#armbian} ;;
        arch-linux*)
            distro_name="ArchLinux"; remainder=${lower_name#arch-linux} ;;
        archlinux*)
            distro_name="ArchLinux"; remainder=${lower_name#archlinux} ;;
        *)
            echo "Unknown rootfs name '$rootfs_name'; keeping it unchanged" >&2
            printf '%s' "$rootfs_name"
            return
            ;;
    esac

    remainder=${remainder#-}

    # A version is significant only when it immediately follows the
    # distribution name. Numbers after the desktop name are build metadata.
    first_field=${remainder%%-*}
    case "$first_field" in
        [0-9]*|v[0-9]*)
            version_name="$first_field"
            if [ "$remainder" = "$first_field" ]; then
                remainder=""
            else
                remainder=${remainder#*-}
            fi
            ;;
    esac

    # Preserve a common release qualifier when it directly follows a version.
    if [ -n "$version_name" ]; then
        first_field=${remainder%%-*}
        case "$first_field" in
            lts)
                version_name="${version_name}-LTS"
                if [ "$remainder" = "$first_field" ]; then
                    remainder=""
                else
                    remainder=${remainder#*-}
                fi
                ;;
        esac
    fi

    case "$remainder" in
        lxqt|lxqt-*)   desktop_name="LXQt" ;;
        gnome|gnome-*) desktop_name="GNOME" ;;
        xfce|xfce-*)   desktop_name="Xfce" ;;
        kde|kde-*)     desktop_name="KDE" ;;
    esac

    if [ -n "$version_name" ]; then
        case "$version_name" in
            v*) version_suffix="-${version_name}" ;;
            *)  version_suffix="$version_name" ;;
        esac
    fi

    if [ -n "$desktop_name" ]; then
        printf '%s%s-%s' "$distro_name" "$version_suffix" "$desktop_name"
    else
        printf '%s%s' "$distro_name" "$version_suffix"
    fi
}

get_rootfs_name() {
    local rootfs_target rootfs_name

    if [ -L "$SRC_ROOTFS_FILE" ]; then
        rootfs_target=$(readlink "$SRC_ROOTFS_FILE")
    else
        rootfs_target=$(basename "$SRC_ROOTFS_FILE")
    fi
    rootfs_name=$(basename "$rootfs_target")
    rootfs_name=${rootfs_name%.img}
    rootfs_name=${rootfs_name%.ext4}
    rootfs_name=${rootfs_name%-rootfs}
    rootfs_name=${rootfs_name%_rootfs}

    # A regular rootfs.ext4, or a link without a distribution prefix, is the
    # root filesystem generated by Buildroot itself.
    if [ -z "$rootfs_name" ] || [ "$rootfs_name" = "rootfs" ]; then
        rootfs_name="Buildroot"
    fi

    normalize_rootfs_name "$rootfs_name"
}

get_firmware_name() {
    local rootfs_name manifest_tag version build_date

    rootfs_name=$(get_rootfs_name)
    manifest_tag=$(get_manifest_tag)
    if [ -n "$manifest_tag" ]; then
        version="$manifest_tag"
    else
        version="debug"
    fi
    build_date=${FIRMWARE_DATE:-$(date +%y%m%d)}

    printf 'Firefly-K3_%s_%s_%s' "$rootfs_name" "$version" "$build_date"
}

SRC_ROOTFS_FILE="$SDK_DIR/prebuilt_rootfs/rootfs.ext4"
LINUX_SOURCE_DIR="$SDK_DIR/bsp-src/linux-6.18"

FIRMWARE_NAME=$(get_firmware_name)
TARGET_IMAGE_ZIP="$IMGS_DIR/${FIRMWARE_NAME}.zip"
SDCARD_IMAGE="${FIRMWARE_NAME}-sdcard.img"

TARGET_BOOTFS_FILE="$IMGS_DIR/bootfs.img"

get_ramdisk_name() {
    local ramdisk_name

    ramdisk_name=$(sed -n \
        's/^[[:space:]]*ramdisk_name[[:space:]]*=[[:space:]]*//p' \
        "$UENV_TXT_FILE" | head -n 1)
    ramdisk_name=${ramdisk_name%%#*}
    ramdisk_name=$(printf '%s' "$ramdisk_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ramdisk_name=${ramdisk_name#\"}
    ramdisk_name=${ramdisk_name%\"}

    if [ -z "$ramdisk_name" ]; then
        ramdisk_name="initramfs-generic.img"
    fi

    # ramdisk_name is a bootfs filename, not a path.
    printf '%s' "${ramdisk_name##*/}"
}

RAMDISK_NAME=$(get_ramdisk_name)
TARGET_INITRAMFS_FILE=""
if [ -d "$LINUX_SOURCE_DIR" ]; then
    TARGET_INITRAMFS_FILE=$(find "$LINUX_SOURCE_DIR" -type f \
        -name "$RAMDISK_NAME" -print -quit)
fi

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
    if [ -n "$TARGET_INITRAMFS_FILE" ]; then
        echo "Using ramdisk: $TARGET_INITRAMFS_FILE"
        echo "cp -f $TARGET_INITRAMFS_FILE $BOOTFS_DIR/$RAMDISK_NAME" >> "$FAKE_ROOT_FILE"
    else
        echo "Ramdisk '$RAMDISK_NAME' not found under $LINUX_SOURCE_DIR; skipping it"
    fi
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
    # Use the external rootfs directly without making another large copy.
    if [ -f "$SRC_ROOTFS_FILE" ]; then
        e2fsck -fy "$SRC_ROOTFS_FILE"
        resize2fs "$SRC_ROOTFS_FILE"
        rm -f "$IMGS_DIR/rootfs.ext2" "$IMGS_DIR/rootfs.ext4"
        ln -s "$SRC_ROOTFS_FILE" "$IMGS_DIR/rootfs.ext4"
        EXTERNAL_ROOTFS_LINK="$IMGS_DIR/rootfs.ext4"
        echo "Using external rootfs directly: ${SRC_ROOTFS_FILE}"
    fi
}

cleanup_external_rootfs_link() {
    if [ -n "${EXTERNAL_ROOTFS_LINK:-}" ]; then
        rm -f "$EXTERNAL_ROOTFS_LINK"
    fi
}

trap cleanup_external_rootfs_link EXIT

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
    echo "Firmware archive: ${TARGET_IMAGE_ZIP##*/}"
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
