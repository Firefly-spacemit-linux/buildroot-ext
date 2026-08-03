#!/bin/bash -e
DATE=$(date +%Y%m%d%H%M%S)
echo "$DATE" | tee "${TARGET_DIR}/etc/bianbu_version"

K3_OVERLAYROOT=0
if grep -q '^BR2_TARGET_K3_ROOTFS_OVERLAY=y$' "${BR2_CONFIG}"; then
    K3_OVERLAYROOT=1
fi
printf 'K3_OVERLAYROOT=%s\n' "$K3_OVERLAYROOT" \
    > "${TARGET_DIR}/etc/k3-overlayroot.conf"

if [ "$K3_OVERLAYROOT" -eq 0 ]; then
    rm -f "${TARGET_DIR}/usr/bin/recovery"
fi

chmod 1777 "${TARGET_DIR}/tmp"
sed -i \
    -e '\|[[:space:]]/tmp[[:space:]].*tmpfs|d' \
    -e '\|[[:space:]]/run[[:space:]].*tmpfs|d' \
    "${TARGET_DIR}/etc/fstab"
