FACTORYTEST_VERSION = 1.0
FACTORYTEST_SITE = $(BR2_EXTERNAL_Bianbu_PATH)/../package-src/factorytest
FACTORYTEST_SITE_METHOD = local

FACTORYTEST_BOARD = $(call qstrip,$(BR2_PACKAGE_FACTORYTEST_BOARD))

define FACTORYTEST_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/opt/factorytest
	mkdir -p $(TARGET_DIR)/opt/factorytest
	# Board-specific files
	cp -r $(@D)/boards/$(FACTORYTEST_BOARD)/cricket  $(TARGET_DIR)/opt/factorytest/
	cp -r $(@D)/boards/$(FACTORYTEST_BOARD)/tests    $(TARGET_DIR)/opt/factorytest/
	cp -r $(@D)/boards/$(FACTORYTEST_BOARD)/utils    $(TARGET_DIR)/opt/factorytest/
	cp    $(@D)/boards/$(FACTORYTEST_BOARD)/stability $(TARGET_DIR)/opt/factorytest/
	cp    $(@D)/boards/$(FACTORYTEST_BOARD)/board.py  $(TARGET_DIR)/opt/factorytest/
	# Common files
	mkdir -p $(TARGET_DIR)/opt/factorytest/common/factorytest
	cp -r $(@D)/common/factorytest/. $(TARGET_DIR)/opt/factorytest/common/factorytest/
	mkdir -p $(TARGET_DIR)/opt/factorytest/res
	cp -r $(@D)/common/res/. $(TARGET_DIR)/opt/factorytest/res/
	cp $(@D)/common/gpu.sh $(@D)/common/vpu.sh $(@D)/common/memtester.sh $(@D)/common/stress-ng.sh \
		$(TARGET_DIR)/opt/factorytest/
	cp $(@D)/gui-main $(TARGET_DIR)/opt/factorytest/

endef

$(eval $(generic-package))
