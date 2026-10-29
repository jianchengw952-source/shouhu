TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard AuraSignPro aurasignd

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    ARCHS = arm64e
else
    THEOS_PACKAGE_SCHEME = rootless
    ARCHS = arm64
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += src/App src/Daemon src/Tweak
include $(THEOS_MAKE_PATH)/aggregate.mk
