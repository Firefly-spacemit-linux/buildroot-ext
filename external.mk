include $(sort $(wildcard $(BR2_EXTERNAL_Bianbu_PATH)/package/*/*.mk))

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
	host-jq host-fakeroot host-genimage \
	host-dosfstools host-mtools host-e2fsprogs

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
