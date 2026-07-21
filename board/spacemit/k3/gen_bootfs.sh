#!/bin/sh

# Generate bootfs.img after Buildroot installs the Linux image and DTBs.
set -eu

IMAGES_DIR=$1
LINUX_SOURCE_DIR=$2
KERNEL_IMAGE_NAME=$3
HOST_DIR=$4
DEVICE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PARTITIONS_FILE="$DEVICE_DIR/partition_universal.json"
UENV_FILE="$DEVICE_DIR/env_k3.txt"
LOGO_FILE="$DEVICE_DIR/firefly.bmp"
BOOTFS_DIR="$IMAGES_DIR/bootfs"
BOOTFS_IMAGE="$IMAGES_DIR/bootfs.img"
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
		ramdisk_name=initramfs-generic.img
	fi

	printf '%s' "${ramdisk_name##*/}"
}

for file in "$PARTITIONS_FILE" "$UENV_FILE" "$LOGO_FILE" "$KERNEL_IMAGE"; do
	if [ ! -f "$file" ]; then
		echo "Missing bootfs input file: $file" >&2
		exit 1
	fi
done

FIRST_DTB=$(find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.dtb' -print -quit)
if [ -z "$FIRST_DTB" ]; then
	echo "Missing bootfs input: no DTB found in $IMAGES_DIR" >&2
	exit 1
fi

BOOTFS_SIZE=$("$HOST_DIR/bin/jq" -r \
	'.partitions[] | select(.name == "bootfs") | .size' \
	"$PARTITIONS_FILE")
if [ -z "$BOOTFS_SIZE" ] || [ "$BOOTFS_SIZE" = null ]; then
	echo "Bootfs partition size is not defined in $PARTITIONS_FILE" >&2
	exit 1
fi

RAMDISK_NAME=$(get_ramdisk_name)
RAMDISK_FILE=
if [ -d "$LINUX_SOURCE_DIR" ]; then
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

echo "Generating bootfs.img after Linux image installation"
rm -rf "$BOOTFS_DIR"
mkdir -p "$BOOTFS_DIR"
rm -f "$BOOTFS_IMAGE"
dd if=/dev/zero of="$BOOTFS_IMAGE" count=1 bs="$BOOTFS_SIZE"
"$HOST_DIR/sbin/mkfs.vfat" -S 4096 "$BOOTFS_IMAGE"

cp -f "$UENV_FILE" "$LOGO_FILE" "$KERNEL_IMAGE" "$BOOTFS_DIR/"
find "$IMAGES_DIR" -maxdepth 1 -type f -name '*.dtb' \
	-exec cp -f {} "$BOOTFS_DIR/" \;

if [ -n "$RAMDISK_FILE" ]; then
	echo "Using ramdisk: $RAMDISK_FILE"
	cp -f "$RAMDISK_FILE" "$BOOTFS_DIR/$RAMDISK_NAME"
else
	echo "Ramdisk '$RAMDISK_NAME' not found under $LINUX_SOURCE_DIR; skipping it"
fi

"$HOST_DIR/bin/mcopy" -i "$BOOTFS_IMAGE" "$BOOTFS_DIR"/* ::
"$HOST_DIR/sbin/fsck.vfat" -v -n "$BOOTFS_IMAGE"
echo "Generated $BOOTFS_IMAGE"
