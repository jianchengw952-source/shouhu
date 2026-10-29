include $(THEOS)/makefiles/common.mk

TOOL_NAME = aurasignd
aurasignd_FILES = aurasignd.mm ../Core/AuraSignEngine.mm ../Core/AuraAppleDeveloperAPI.mm
aurasignd_FRAMEWORKS = Foundation UIKit CoreGraphics Security SystemConfiguration
aurasignd_LIBRARIES = z sqlite3
aurasignd_CODESIGN_FLAGS = -S../../entitlements.xml
aurasignd_CFLAGS = -fobjc-arc -I../Core -Wno-deprecated-declarations
aurasignd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
