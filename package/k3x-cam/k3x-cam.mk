K3X_CAM_VERSION := 0.0.5
K3X_CAM_SITE = $(BR2_EXTERNAL_Bianbu_PATH)/../package-src/k3x-cam
K3X_CAM_SITE_METHOD = local

K3X_CAM_CONF_OPTS = -DRUN_PLATFORM="RISCV" \
			-DCI_LOG_LEVEL=4 \
			-DARCH_RISCV="Y" \
			-DCMAKE_INSTALL_PREFIX="/usr" \

define K3X_CAM_INSTALL_STAGING_CMDS
	cp -rdpf $(@D)/csi-test $(STAGING_DIR)/usr/bin/csi-test
endef


$(eval $(cmake-package))
