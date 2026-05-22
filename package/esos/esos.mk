################################################################################
#
# ESOS
#
################################################################################

# ESOS firmware version and source
ESOS_SITE = $(BR2_EXTERNAL_Bianbu_PATH)/../package-src/esos
ESOS_SITE_METHOD = local

# Override rsync to include .git directory for version_id generation
define ESOS_EXTRACT_CMDS
	rsync -au --chmod=u=rwX,go=rX --exclude .svn --exclude .git --exclude .hg --exclude .bzr --exclude CVS $(ESOS_SITE)/ $(@D)
	if [ -d "$(ESOS_SITE)/.git" ]; then \
		mkdir -p $(@D)/.git; \
		cp -a $(ESOS_SITE)/.git/HEAD $(@D)/.git/ 2>/dev/null || true; \
		cp -a $(ESOS_SITE)/.git/refs $(@D)/.git/ 2>/dev/null || true; \
		cp -a $(ESOS_SITE)/.git/objects $(@D)/.git/ 2>/dev/null || true; \
	fi
endef

# Toolchain configuration
ESOS_TOOLCHAIN_NAME = spacemit-toolchain-elf-newlib-x86_64-v1.0.9
ESOS_TOOLCHAIN_DIR = $(@D)/tools/toolchain

# Configure step: equivalent to ./build_top.sh config with rt24 chip selection (non-interactive)
define ESOS_CONFIGURE_CMDS
	@echo "INFO: prepare to config esos sdk ..."
	rm -rf $(@D)/bsp/spacemit/.config
	rm -rf $(@D)/bsp/spacemit/.esos_top.config
	@echo "INFO: Selecting chip: rt24 (non-interactive)"
	echo "export TOP_TARGET_CHIP=rt24" >> $(@D)/bsp/spacemit/.esos_top.config
	@echo ""
	@echo "INFO: target configuration is as follows:"
	@echo "INFO: -------------------------------------------------------------------------"
	@cat $(@D)/bsp/spacemit/.esos_top.config
	@echo "INFO: -------------------------------------------------------------------------"
	@echo "INFO: prepare to toolchain ..."
	mkdir -p $(ESOS_TOOLCHAIN_DIR)
	if [ ! -d "$(ESOS_TOOLCHAIN_DIR)/$(ESOS_TOOLCHAIN_NAME)" ]; then \
		cd $(ESOS_TOOLCHAIN_DIR) && \
		if [ ! -f "$(ESOS_TOOLCHAIN_NAME).tar.xz" ]; then \
			echo "INFO: Downloading toolchain from http://archive.spacemit.com/toolchain/$(ESOS_TOOLCHAIN_NAME).tar.xz ..." && \
			(wget http://archive.spacemit.com/toolchain/$(ESOS_TOOLCHAIN_NAME).tar.xz || \
			curl -L -o $(ESOS_TOOLCHAIN_NAME).tar.xz http://archive.spacemit.com/toolchain/$(ESOS_TOOLCHAIN_NAME).tar.xz); \
		fi && \
		echo "INFO: Extracting toolchain ..." && \
		tar -xf $(ESOS_TOOLCHAIN_NAME).tar.xz && \
		cd -; \
	fi
	@echo "INFO: Creating .env/packages/Kconfig for menuconfig ..."
	mkdir -p $(@D)/.env/packages
	touch $(@D)/.env/packages/Kconfig
	@echo "INFO: Creating initial rtconfig.h ..."
	touch $(@D)/bsp/spacemit/rtconfig.h
	@echo "INFO: esos config completed"
endef

# Build step: equivalent to ./build_top.sh (builds all boards under rt24 chip)
define ESOS_BUILD_CMDS
	@echo "INFO: Starting esos build for all boards ..."
	cd $(@D) && ./build_top.sh
	@echo "INFO: esos build completed"
endef

# Install step: copy esos.itb to BINARIES_DIR
define ESOS_INSTALL_TARGET_CMDS
	if [ -f "$(@D)/../output/esos/rt24_os0_rcpu.elf" ]; then \
		cp -f $(@D)/../output/esos/rt24_os0_rcpu.elf $(BINARIES_DIR)/; \
	fi
	@echo "INFO: Copied rt24_os0_rcpu.elf to images/";
	if [ -f "$(@D)/../output/esos/rt24_os1_rcpu.elf" ]; then \
		cp -f $(@D)/../output/esos/rt24_os1_rcpu.elf $(BINARIES_DIR)/; \
	fi
	@echo "INFO: Copied rt24_os1_rcpu.elf to images/";
	if [ -f "$(@D)/bsp/spacemit/esos.itb" ]; then \
		cp -f $(@D)/bsp/spacemit/esos.itb $(BINARIES_DIR)/; \
	fi
	@echo "INFO: Copied esos.itb to images/";
	@echo "INFO: esos build completed"
endef

# Clean command
define ESOS_CLEAN_CMDS
    @echo "INFO: prepare to clean esos ..."
    if [ -f "$(@D)/build.sh" ]; then \
        cd $(@D) && ./build.sh clean 2>/dev/null || true; \
    fi

endef

# Distclean command
define ESOS_DISTCLEAN_CMDS
    $(ESOS_CLEAN_CMDS)
    rm -rf $(ESOS_TOOLCHAIN_DIR)
endef

$(eval $(generic-package))
