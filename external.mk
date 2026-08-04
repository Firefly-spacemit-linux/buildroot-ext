include $(sort $(wildcard $(BR2_EXTERNAL_Bianbu_PATH)/package/*/*.mk))

# K3 Linux 6.18 BSP development commonly rebuilds only the Linux package.
# Generate the boot filesystem image during image installation so
# linux-rebuild immediately produces an image that can be flashed for debugging.
ifneq ($(findstring /bsp-src/linux-6.18,$(call qstrip,$(BR2_LINUX_KERNEL_CUSTOM_DIR_LOCATION))),)
K3_BOOTFS_SCRIPT := $(BR2_EXTERNAL_Bianbu_PATH)/board/spacemit/k3/gen_bootfs.sh
K3_PARTITION_LAYOUT_SCRIPT := $(BR2_EXTERNAL_Bianbu_PATH)/board/spacemit/k3/gen_partition_layout.sh
K3_BOOTFS_MODULES_ROOT := $(BINARIES_DIR)/bootfs-modules
K3_BOOTFS_PARTITIONS_FILE := $(BINARIES_DIR)/partition_universal.json
K3_BOOTFS_PARTITIONS_TEMPLATE := $(BR2_EXTERNAL_Bianbu_PATH)/board/spacemit/k3/partition_universal.json
K3_BOOTFS_SIZE_MIB := $(if $(BR2_TARGET_K3_BOOTFS_SIZE),$(BR2_TARGET_K3_BOOTFS_SIZE),256)
K3_BOOTFS_MODULES_ENABLED := $(if $(BR2_TARGET_K3_BOOTFS_MODULES),1,0)
ifeq ($(BR2_TARGET_K3_ROOTFS_OVERLAY),y)
K3_BOOTFS_PARTITIONS_TEMPLATE := $(BR2_EXTERNAL_Bianbu_PATH)/board/spacemit/k3/partition_firefly_universal.json
endif
K3_LINUX_BOOTFS_DEPENDENCIES := \
	host-jq \
	host-genimage \
	host-e2fsprogs

# external.mk is included after the Linux package infrastructure has expanded
# LINUX_DEPENDENCIES. Attach the tools to the source synchronization stamp so
# both linux and linux-rebuild finish them before starting any Linux stage.
$(LINUX_TARGET_RSYNC): | $(K3_LINUX_BOOTFS_DEPENDENCIES)

# The image hook consumes the modules installed by the target hook.
$(LINUX_TARGET_INSTALL_IMAGES): $(LINUX_TARGET_INSTALL_TARGET)

ifeq ($(BR2_TARGET_K3_BOOTFS_MODULES),y)
# Keep in-tree and package-provided modules out of TARGET_DIR. Appending the
# assignment makes it override Buildroot's default INSTALL_MOD_PATH.
LINUX_MAKE_FLAGS += INSTALL_MOD_PATH=$(K3_BOOTFS_MODULES_ROOT)

define K3_LINUX_PREPARE_BOOTFS_MODULES
	$(Q)rm -rf $(TARGET_DIR)/lib/modules
	$(Q)if test -d $(K3_BOOTFS_MODULES_ROOT)/lib/modules; then \
		find $(K3_BOOTFS_MODULES_ROOT)/lib/modules -mindepth 1 -maxdepth 1 \
			! -name $(LINUX_VERSION_PROBED) -exec rm -rf {} +; \
	fi
	$(Q)rm -rf $(K3_BOOTFS_MODULES_ROOT)/lib/modules/$(LINUX_VERSION_PROBED)/kernel
	$(Q)rm -f $(K3_BOOTFS_MODULES_ROOT)/lib/modules/$(LINUX_VERSION_PROBED)/modules.*
endef
LINUX_PRE_INSTALL_TARGET_HOOKS += K3_LINUX_PREPARE_BOOTFS_MODULES

define K3_BOOTFS_RUN_DEPMOD
	$(Q)if test -d $(K3_BOOTFS_MODULES_ROOT)/lib/modules/$(LINUX_VERSION_PROBED); then \
		rm -f $(K3_BOOTFS_MODULES_ROOT)/lib/modules/$(LINUX_VERSION_PROBED)/build \
			$(K3_BOOTFS_MODULES_ROOT)/lib/modules/$(LINUX_VERSION_PROBED)/source; \
		$(HOST_DIR)/sbin/depmod -a -b $(K3_BOOTFS_MODULES_ROOT) \
			$(LINUX_VERSION_PROBED); \
	fi
endef
LINUX_POST_INSTALL_TARGET_HOOKS += K3_BOOTFS_RUN_DEPMOD

define K3_BOOTFS_FINALIZE_MODULES
	$(Q)rm -rf $(TARGET_DIR)/lib/modules
	$(Q)mkdir -p $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)
	$(K3_BOOTFS_RUN_DEPMOD)
endef
TARGET_FINALIZE_HOOKS += K3_BOOTFS_FINALIZE_MODULES
endif

define K3_LINUX_GENERATE_BOOTFS
	$(Q)$(SHELL) $(K3_PARTITION_LAYOUT_SCRIPT) \
		$(K3_BOOTFS_PARTITIONS_TEMPLATE) \
		$(K3_BOOTFS_PARTITIONS_FILE) \
		$(K3_BOOTFS_SIZE_MIB) \
		$(HOST_DIR)
	$(Q)$(SHELL) $(K3_BOOTFS_SCRIPT) \
		$(BINARIES_DIR) \
		$(call qstrip,$(BR2_LINUX_KERNEL_CUSTOM_DIR_LOCATION)) \
		$(LINUX_IMAGE_NAME) \
		$(HOST_DIR) \
		$(K3_BOOTFS_PARTITIONS_FILE) \
		$(K3_BOOTFS_MODULES_ROOT) \
		$(K3_BOOTFS_MODULES_ENABLED)
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
