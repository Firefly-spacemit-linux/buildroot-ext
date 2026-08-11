#!/bin/bash

# called by dracut
check() {
    # do not add this module by default
    return 255
}

# called by dracut
depends() {
    return 0
}

# called by dracut
install() {
    inst_multiple -o ps grep more cat rm strace free showmount \
        ping netstat rpcinfo vi scp ping6 ssh \
        fsck fsck.ext2 fsck.ext4 fsck.ext3 fsck.ext4dev fsck.f2fs fsck.vfat \
        e2fsck resize2fs mount umount blkid dd head tr sync \
        mv mkdir sleep setsid run-init

    # Install the full Bash binary and its shared libraries for emergency
    # debugging. Keep common terminal descriptions for interactive editing.
    inst_binary /bin/bash /bin/bash
    inst_multiple -o /usr/share/terminfo/l/linux \
        /usr/share/terminfo/v/vt100 \
        /usr/share/terminfo/x/xterm \
        /usr/share/terminfo/x/xterm-256color

    inst /etc/k3-overlayroot.conf
    inst /etc/k3-bootfs.conf
    inst /etc/k3-sd-post-install.conf
    if grep -q '^K3_OVERLAYROOT=1$' \
        "$dracutsysrootdir/etc/k3-overlayroot.conf"; then
        # Keep the full e2fsprogs binary under a private name. The dracut
        # busybox module replaces the standard mke2fs path with an applet.
        inst_binary /sbin/mke2fs /sbin/k3-mke2fs
        inst_script /sbin/k3-overlayroot
    fi

    if grep -q '^K3_SD_CARD_UPGRADE_POST_INSTALL=1$' \
        "$dracutsysrootdir/etc/k3-sd-post-install.conf"; then
        inst_multiple awk grep gzip cp mv mkdir chmod chown \
            sed readlink mount umount blkid dd head tr sync sleep reboot
        inst_binary /bin/tar /sbin/k3-tar
        inst_script /sbin/k3-sd-post-install
    fi

    # Copy firmware files to initramfs
    local fw="$dracutsysrootdir/../../../output/esos"
    inst_dir /lib/firmware
    inst "$fw/rt24_os0_rcpu.elf" /lib/firmware/rt24_os0_rcpu.elf 2>/dev/null
    inst "$fw/rt24_os1_rcpu.elf" /lib/firmware/rt24_os1_rcpu.elf 2>/dev/null
}
