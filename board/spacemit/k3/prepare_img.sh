#!/bin/bash

######################## Prepare sub-iamges and pack ####################
#$0 is this file path
#$1 is buildroot output images dir
set -e
IMGS_DIR=$1
DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)

K3_OVERLAYROOT=0
if [ -r "${BR2_CONFIG:-}" ] && \
    grep -q '^BR2_TARGET_K3_ROOTFS_OVERLAY=y$' "$BR2_CONFIG"; then
    K3_OVERLAYROOT=1
fi

BASE_PARTITIONS_TEMPLATE="$DEVICE_DIR/partition_universal.json"
OVERLAY_PARTITIONS_TEMPLATE="$DEVICE_DIR/partition_firefly_universal.json"
if [ "$K3_OVERLAYROOT" -eq 1 ]; then
    PARTITIONS_TEMPLATE="$OVERLAY_PARTITIONS_TEMPLATE"
else
    PARTITIONS_TEMPLATE="$BASE_PARTITIONS_TEMPLATE"
fi
PARTITIONS_FILE="$PARTITIONS_TEMPLATE"

echo "Using partition template: $(basename "$PARTITIONS_TEMPLATE")"

get_partition_image_name() {
    local partition_name=$1 partition_count image_name

    partition_count=$($IMGS_DIR/../host/bin/jq -r --arg name "$partition_name" \
        '[.partitions[] | select(.name == $name)] | length' \
        "$PARTITIONS_FILE")
    if [ "$partition_count" -ne 1 ]; then
        echo "Expected exactly one '$partition_name' partition in $PARTITIONS_FILE" >&2
        return 1
    fi

    image_name=$($IMGS_DIR/../host/bin/jq -r --arg name "$partition_name" \
        '.partitions[] | select(.name == $name) | .image // empty' \
        "$PARTITIONS_FILE")
    case "$image_name" in
        ""|.|..|*/*)
            echo "Invalid image name for '$partition_name' in $PARTITIONS_FILE: $image_name" >&2
            return 1
            ;;
    esac

    printf '%s' "$image_name"
}

BOOTFS_IMAGE_NAME=$(get_partition_image_name bootfs)
BOOTFS_IMAGE_FILE="$IMGS_DIR/$BOOTFS_IMAGE_NAME"

MISC_IMAGE_NAME=
MISC_IMAGE_FILE=
MISC_IMAGE_SIZE=
if [ "$K3_OVERLAYROOT" -eq 1 ]; then
    MISC_IMAGE_NAME=$(get_partition_image_name misc)
    MISC_IMAGE_FILE="$IMGS_DIR/$MISC_IMAGE_NAME"
    MISC_IMAGE_SIZE=$($IMGS_DIR/../host/bin/jq -r \
        '.partitions[] | select(.name == "misc") | .size // empty' \
        "$PARTITIONS_TEMPLATE")
    if [ -z "$MISC_IMAGE_SIZE" ]; then
        echo "Misc partition size is not defined in $PARTITIONS_TEMPLATE" >&2
        exit 1
    fi
fi

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

FIRMWARE_NAME=$(get_firmware_name)
TARGET_IMAGE_ZIP="$IMGS_DIR/${FIRMWARE_NAME}.zip"
SDCARD_IMAGE="${FIRMWARE_NAME}-sdcard.img"

override_rootfs_img() {
    # Use the external rootfs directly without making another large copy.
    if [ -f "$SRC_ROOTFS_FILE" ]; then
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

    if [ "$K3_OVERLAYROOT" -eq 1 ]; then
        rm -f "$MISC_IMAGE_FILE"
        truncate -s "$MISC_IMAGE_SIZE" "$MISC_IMAGE_FILE"
    else
        rm -f "$IMGS_DIR/misc.img"
    fi

}

generate_partitions_file() {
    local rootfs_file="$IMGS_DIR/rootfs.ext4"
    local rootfs_bytes alignment_bytes rootfs_size_bytes rootfs_size_mib
    local rootfs_offset rootfs_offset_mib userdata_offset_mib output_file
    local last_partition

    if [ ! -f "$rootfs_file" ]; then
        echo "Missing rootfs image: $rootfs_file" >&2
        return 1
    fi

    rootfs_bytes=$(stat -Lc %s "$rootfs_file")
    alignment_bytes=$((4 * 1024 * 1024))
    rootfs_size_bytes=$((
        (rootfs_bytes + alignment_bytes - 1) / alignment_bytes * alignment_bytes
    ))
    rootfs_size_mib=$((rootfs_size_bytes / 1024 / 1024))

    rootfs_offset=$($IMGS_DIR/../host/bin/jq -r \
        '.partitions[] | select(.name == "rootfs") | .offset // empty' \
        "$PARTITIONS_TEMPLATE")
    case "$rootfs_offset" in
        *M) rootfs_offset_mib=${rootfs_offset%M} ;;
        *)
            echo "Rootfs offset must use MiB units: $rootfs_offset" >&2
            return 1
            ;;
    esac
    case "$rootfs_offset_mib" in
        ""|*[!0-9]*)
            echo "Invalid rootfs offset: $rootfs_offset" >&2
            return 1
            ;;
    esac

    output_file="$IMGS_DIR/partition_universal.json"
    if [ "$K3_OVERLAYROOT" -eq 1 ]; then
        userdata_offset_mib=$((rootfs_offset_mib + rootfs_size_mib))
        $IMGS_DIR/../host/bin/jq \
            --arg rootfs_size "${rootfs_size_mib}M" \
            --arg userdata_offset "${userdata_offset_mib}M" \
            '(.partitions[] | select(.name == "rootfs") | .size) = $rootfs_size |
             (.partitions[] | select(.name == "userdata") | .offset) = $userdata_offset' \
            "$PARTITIONS_TEMPLATE" > "$output_file"
        echo "Rootfs partition size: ${rootfs_size_mib}M"
        echo "Userdata partition offset: ${userdata_offset_mib}M"
    else
        last_partition=$($IMGS_DIR/../host/bin/jq -r \
            '.partitions[-1].name // empty' "$PARTITIONS_TEMPLATE")
        if [ "$last_partition" != "rootfs" ]; then
            echo "Rootfs must be the last partition in $PARTITIONS_TEMPLATE" >&2
            return 1
        fi
        $IMGS_DIR/../host/bin/jq \
            --arg rootfs_sdcard_size "${rootfs_size_mib}M" \
            '(.partitions[] | select(.name == "rootfs") | .size) = "-" |
             (.partitions[] | select(.name == "rootfs") | .sdcard_size) = $rootfs_sdcard_size' \
            "$PARTITIONS_TEMPLATE" > "$output_file"
        echo "Rootfs partition uses the remaining device space"
        echo "Rootfs SD card image size: ${rootfs_size_mib}M"
    fi

    PARTITIONS_FILE="$output_file"
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
    local partition_file partition_name
    local -a image_files

    echo "Starting to pack images................................."
    rm -f ${TARGET_IMAGE_ZIP}
    rm -rf ${IMGS_DIR}/factory

    mkdir -p ${IMGS_DIR}/factory
    cp -f ${IMGS_DIR}/FSBL.bin ${IMGS_DIR}/factory/
    cp -f ${IMGS_DIR}/bootinfo_*.bin ${IMGS_DIR}/factory/
    cp -f ${DEVICE_DIR}/fastboot.yaml ${IMGS_DIR}/
    cp -f ${DEVICE_DIR}/ec.bin ${IMGS_DIR}/
    rm -f "$IMGS_DIR/partition_firefly_universal.json"
    for partition_file in "$DEVICE_DIR"/partition_*.json; do
        partition_name=$(basename "$partition_file")
        case "$partition_name" in
            partition_universal.json|partition_firefly_universal.json)
                continue
                ;;
        esac
        cp -f "$partition_file" "$IMGS_DIR/"
    done

    image_files=(
        fw_dynamic.itb
        u-boot.itb
        esos.itb
        env.bin
        "$BOOTFS_IMAGE_NAME"
        ec.bin
        rootfs.ext4
    )
    if [ "$K3_OVERLAYROOT" -eq 1 ]; then
        image_files+=("$MISC_IMAGE_NAME")
    fi

    cd ${IMGS_DIR}
    echo "Firmware archive: ${TARGET_IMAGE_ZIP##*/}"
    zip ${TARGET_IMAGE_ZIP} \
        "${image_files[@]}" \
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

# Regenerate bootfs after rootfs-cpio so it contains the current initramfs.
"$DEVICE_DIR/gen_bootfs.sh" \
    "$IMGS_DIR" \
    "$SDK_DIR/bsp-src/linux-6.18" \
    "$2" \
    "$IMGS_DIR/../host"

if [ ! -f "$BOOTFS_IMAGE_FILE" ]; then
    echo "Missing $BOOTFS_IMAGE_FILE; rebuild the Linux package first" >&2
    exit 1
fi

#For Debian or Ubuntu rootfs override
override_rootfs_img

# Generate the final partition table from the actual rootfs image size.
generate_partitions_file

#Update genimage cfg because pack_image_zip dependis on it
update_genimage_cfg

#Pack images in zip
pack_image_zip

#Gen sdcard.img if need
gen_sdcard_img
