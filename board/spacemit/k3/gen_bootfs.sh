#!/bin/sh

# Generate the boot filesystem image after Buildroot installs Linux and DTBs.
set -eu

IMAGES_DIR=$1
LINUX_SOURCE_DIR=$2
KERNEL_IMAGE_NAME=$3
HOST_DIR=$4
DEVICE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PARTITIONS_FILE=${5:-"$DEVICE_DIR/partition_universal.json"}
BOOTFS_MODULES_ROOT=${6:-}
INSTALL_BOOTFS_MODULES=${7:-0}
UENV_FILE="$DEVICE_DIR/env_k3.txt"
LOGO_FILE="$DEVICE_DIR/firefly.bmp"
BOOTFS_DIR="$IMAGES_DIR/bootfs"
KERNEL_IMAGE="$IMAGES_DIR/$KERNEL_IMAGE_NAME"

get_ramdisk_name() {
	ramdisk_name=$(sed -n \
		's/^[[:space:]]*ramdisk_name[[:space:]]*=[[:space:]]*//p' \
		"$UENV_FILE" | head -n 1)
	ramdisk_name=${ramdisk_name%%#*}
	ramdisk_name=$(printf '%s' "$ramdisk_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	ramdisk_name=${ramdisk_name#\"}
	ramdisk_name=${ramdisk_name%\"}

	if [ -z "$ramdisk_name" ]; then
		ramdisk_name=initrd.img
	fi

	printf '%s' "${ramdisk_name##*/}"
}

for file in "$PARTITIONS_FILE" "$UENV_FILE" "$LOGO_FILE" "$KERNEL_IMAGE"; do
	if [ ! -f "$file" ]; then
		echo "Missing bootfs input file: $file" >&2
		exit 1
	fi
done

case "$INSTALL_BOOTFS_MODULES" in
	0|1)
		;;
	*)
		echo "Invalid bootfs modules setting: $INSTALL_BOOTFS_MODULES" >&2
		exit 1
		;;
esac
if [ "$INSTALL_BOOTFS_MODULES" -eq 1 ] && \
	[ ! -d "$BOOTFS_MODULES_ROOT/lib/modules" ]; then
	echo "Missing bootfs kernel modules: $BOOTFS_MODULES_ROOT/lib/modules" >&2
fi

FIRST_DTB=$(find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.dtb' -print -quit)
if [ -z "$FIRST_DTB" ]; then
	echo "Missing bootfs input: no DTB found in $IMAGES_DIR" >&2
	exit 1
fi

BOOTFS_PARTITION_COUNT=$("$HOST_DIR/bin/jq" -r \
	'[.partitions[] | select(.name == "bootfs")] | length' \
	"$PARTITIONS_FILE")
if [ "$BOOTFS_PARTITION_COUNT" -ne 1 ]; then
	echo "Expected exactly one bootfs partition in $PARTITIONS_FILE" >&2
	exit 1
fi

BOOTFS_SIZE=$("$HOST_DIR/bin/jq" -r \
	'.partitions[] | select(.name == "bootfs") | .size // empty' \
	"$PARTITIONS_FILE")
BOOTFS_IMAGE_NAME=$("$HOST_DIR/bin/jq" -r \
	'.partitions[] | select(.name == "bootfs") | .image // empty' \
	"$PARTITIONS_FILE")

if [ -z "$BOOTFS_SIZE" ]; then
	echo "Bootfs partition size is not defined in $PARTITIONS_FILE" >&2
	exit 1
fi
case "$BOOTFS_IMAGE_NAME" in
	""|.|..|*/*)
		echo "Invalid bootfs image name in $PARTITIONS_FILE: $BOOTFS_IMAGE_NAME" >&2
		exit 1
		;;
esac
BOOTFS_IMAGE="$IMAGES_DIR/$BOOTFS_IMAGE_NAME"

RAMDISK_NAME=$(get_ramdisk_name)
RAMDISK_FILE=
if [ -f "$IMAGES_DIR/rootfs.cpio.gz" ]; then
	RAMDISK_FILE="$IMAGES_DIR/rootfs.cpio.gz"
elif [ -f "$IMAGES_DIR/rootfs.cpio" ]; then
	RAMDISK_FILE="$IMAGES_DIR/rootfs.cpio"
elif [ -d "$LINUX_SOURCE_DIR" ]; then
	RAMDISK_FILE=$(find "$LINUX_SOURCE_DIR" -type f \
		-name "$RAMDISK_NAME" -print -quit)
fi

cleanup() {
	status=$?
	if [ "$status" -ne 0 ]; then
		rm -f "$BOOTFS_IMAGE"
	fi
	exit "$status"
}
trap cleanup EXIT INT TERM

echo "Generating $BOOTFS_IMAGE_NAME after Linux image installation"
rm -rf "$BOOTFS_DIR"
mkdir -p "$BOOTFS_DIR"
rm -f "$BOOTFS_IMAGE"

cp -f "$UENV_FILE" "$LOGO_FILE" "$KERNEL_IMAGE" "$BOOTFS_DIR/"
find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.dtb' \
	-exec cp -f {} "$BOOTFS_DIR/" \;

if [ -n "$RAMDISK_FILE" ]; then
	echo "Using ramdisk: $RAMDISK_FILE"
	cp -f "$RAMDISK_FILE" "$BOOTFS_DIR/$RAMDISK_NAME"
else
	echo "Ramdisk '$RAMDISK_NAME' not found under $LINUX_SOURCE_DIR; skipping it"
fi

if [ "$INSTALL_BOOTFS_MODULES" -eq 1 ]; then
	echo "Installing kernel modules from $BOOTFS_MODULES_ROOT"
	mkdir -p "$BOOTFS_DIR/lib/modules"
	modules_count=0
	for modules_dir in "$BOOTFS_MODULES_ROOT"/lib/modules/*; do
		if [ ! -d "$modules_dir" ]; then
			continue
		fi
		cp -a "$modules_dir" "$BOOTFS_DIR/lib/modules/"
		modules_count=$((modules_count + 1))
	done
	if [ "$modules_count" -ne 1 ]; then
		echo "Expected exactly one kernel module version directory in $BOOTFS_MODULES_ROOT" >&2
		exit 1
	fi
fi

truncate -s "$BOOTFS_SIZE" "$BOOTFS_IMAGE"
"$HOST_DIR/sbin/mkfs.ext4" -F -b 4096 -L bootfs \
	-d "$BOOTFS_DIR" "$BOOTFS_IMAGE"
"$HOST_DIR/sbin/e2fsck" -f -n "$BOOTFS_IMAGE"
echo "Generated $BOOTFS_IMAGE"
