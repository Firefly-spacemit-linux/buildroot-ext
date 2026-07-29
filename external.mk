include $(sort $(wildcard $(BR2_EXTERNAL_Bianbu_PATH)/package/*/*.mk))

# K3 Linux 6.18 BSP development commonly rebuilds only the Linux package.
# Generate the boot filesystem image during image installation so
# linux-rebuild immediately produces an image that can be flashed for debugging.
ifneq ($(findstring /bsp-src/linux-6.18,$(call qstrip,$(BR2_LINUX_KERNEL_CUSTOM_DIR_LOCATION))),)
K3_BOOTFS_SCRIPT := $(BR2_EXTERNAL_Bianbu_PATH)/board/spacemit/k3/gen_bootfs.sh
K3_LINUX_BOOTFS_DEPENDENCIES := \
	host-jq \
	host-dosfstools \
	host-mtools \
	host-genimage \
	host-e2fsprogs

# external.mk is included after the Linux package infrastructure has expanded
# LINUX_DEPENDENCIES. Attach the tools to the source synchronization stamp so
# both linux and linux-rebuild finish them before starting any Linux stage.
$(LINUX_TARGET_RSYNC): | $(K3_LINUX_BOOTFS_DEPENDENCIES)

define K3_LINUX_GENERATE_BOOTFS
	$(Q)$(SHELL) $(K3_BOOTFS_SCRIPT) \
		$(BINARIES_DIR) \
		$(call qstrip,$(BR2_LINUX_KERNEL_CUSTOM_DIR_LOCATION)) \
		$(LINUX_IMAGE_NAME) \
		$(HOST_DIR)
endef
LINUX_POST_INSTALL_IMAGES_HOOKS += K3_LINUX_GENERATE_BOOTFS
endif

# An external K3 rootfs image is installed by prepare_img.sh. Build only the
# firmware components and host tools needed by the post-image script instead
# of finalizing and packaging the Buildroot userspace.
K3_EXTERNAL_ROOTFS := $(BR2_EXTERNAL_Bianbu_PATH)/../prebuilt_rootfs/rootfs.ext4
ifneq ($(findstring /board/spacemit/k3/prepare_img.sh,$(BR2_ROOTFS_POST_IMAGE_SCRIPT)),)
ifneq ($(wildcard $(K3_EXTERNAL_ROOTFS)),)
TARGETS_ROOTFS := $(filter-out rootfs-ext2,$(TARGETS_ROOTFS))

BR2_EXTERNAL_DEFAULT_TARGET := k3-external-image
K3_EXTERNAL_IMAGE_DEPENDENCIES := \
	opensbi uboot linux esos \
	host-genimage host-e2fsprogs

.PHONY: k3-external-image
k3-external-image: $(K3_EXTERNAL_IMAGE_DEPENDENCIES) staging-finalize
	@$(call MESSAGE,"Building K3 firmware with external rootfs")
	$(Q)mkdir -p $(BINARIES_DIR)
	@$(foreach s, $(call qstrip,$(BR2_ROOTFS_POST_IMAGE_SCRIPT)), \
		$(call MESSAGE,"Executing post-image script $(s)"); \
		$(EXTRA_ENV) $(s) \
			$(BINARIES_DIR) \
			$(call qstrip,$(BR2_ROOTFS_POST_SCRIPT_ARGS)) \
			$(call qstrip,$(BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS))$(sep))

$(info Using external rootfs $(K3_EXTERNAL_ROOTFS); skipping Buildroot userspace generation)
endif
endif
