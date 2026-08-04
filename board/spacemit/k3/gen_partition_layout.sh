#!/bin/sh

# Generate a partition layout with the configured bootfs size.
set -eu

INPUT_FILE=$1
OUTPUT_FILE=$2
BOOTFS_SIZE_MIB=$3
HOST_DIR=$4
JQ="$HOST_DIR/bin/jq"

case "$BOOTFS_SIZE_MIB" in
	""|*[!0-9]*|0)
		echo "Invalid bootfs size in MiB: $BOOTFS_SIZE_MIB" >&2
		exit 1
		;;
esac

if [ ! -f "$INPUT_FILE" ]; then
	echo "Missing partition template: $INPUT_FILE" >&2
	exit 1
fi
if [ ! -x "$JQ" ]; then
	echo "Missing jq executable: $JQ" >&2
	exit 1
fi

BOOTFS_PARTITION_COUNT=$(
	"$JQ" -r '[.partitions[] | select(.name == "bootfs")] | length' \
		"$INPUT_FILE"
)
if [ "$BOOTFS_PARTITION_COUNT" -ne 1 ]; then
	echo "Expected exactly one bootfs partition in $INPUT_FILE" >&2
	exit 1
fi

BOOTFS_OFFSET=$(
	"$JQ" -r '.partitions[] | select(.name == "bootfs") | .offset // empty' \
		"$INPUT_FILE"
)
BOOTFS_TEMPLATE_SIZE=$(
	"$JQ" -r '.partitions[] | select(.name == "bootfs") | .size // empty' \
		"$INPUT_FILE"
)
case "$BOOTFS_OFFSET" in
	*M) BOOTFS_OFFSET_MIB=${BOOTFS_OFFSET%M} ;;
	*)
		echo "Bootfs offset must use MiB units: $BOOTFS_OFFSET" >&2
		exit 1
		;;
esac
case "$BOOTFS_TEMPLATE_SIZE" in
	*M) BOOTFS_TEMPLATE_SIZE_MIB=${BOOTFS_TEMPLATE_SIZE%M} ;;
	*)
		echo "Bootfs template size must use MiB units: $BOOTFS_TEMPLATE_SIZE" >&2
		exit 1
		;;
esac
case "$BOOTFS_OFFSET_MIB:$BOOTFS_TEMPLATE_SIZE_MIB" in
	*[!0-9:]*|:*|*:)
		echo "Invalid bootfs layout in $INPUT_FILE" >&2
		exit 1
		;;
esac

OLD_BOOTFS_END_MIB=$((BOOTFS_OFFSET_MIB + BOOTFS_TEMPLATE_SIZE_MIB))
OFFSET_DELTA_MIB=$((BOOTFS_SIZE_MIB - BOOTFS_TEMPLATE_SIZE_MIB))
OUTPUT_TMP="${OUTPUT_FILE}.tmp.$$"

cleanup() {
	status=$?
	rm -f "$OUTPUT_TMP"
	exit "$status"
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$OUTPUT_FILE")"
"$JQ" \
	--arg bootfs_size "${BOOTFS_SIZE_MIB}M" \
	--argjson old_bootfs_end "$OLD_BOOTFS_END_MIB" \
	--argjson offset_delta "$OFFSET_DELTA_MIB" \
	'.partitions |= map(
		if .name == "bootfs" then
			.size = $bootfs_size
		elif ((.offset? // "") | type == "string" and endswith("M")) and
			((.offset | rtrimstr("M") | tonumber) >= $old_bootfs_end) then
			.offset = (((.offset | rtrimstr("M") | tonumber) +
				$offset_delta | tostring) + "M")
		else
			.
		end
	)' "$INPUT_FILE" > "$OUTPUT_TMP"
mv -f "$OUTPUT_TMP" "$OUTPUT_FILE"

echo "Configured bootfs partition size: ${BOOTFS_SIZE_MIB}M"
