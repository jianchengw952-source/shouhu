TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard AuraSignPro aurasignd

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    ARCHS = arm64e
else
    THEOS_PACKAGE_SCHEME = rootless
    ARCHS = arm64
endif

include $(THEOS)/makefiles/common.mk

# 1. 桌面主程序 AuraSignPro.app
APPLICATION_NAME = AuraSignPro
AuraSignPro_FILES = src/App/main.m src/App/AuraLiquidGlassView.mm src/App/AuraMainViewController.mm src/Core/AuraSignEngine.mm src/Core/AuraAppleDeveloperAPI.mm
# 【关键修复】：指定 Info.plist 所在的资源目录，确保 Info.plist 被打包进 AuraSignPro.app！
AuraSignPro_RESOURCE_DIRS = src/App
AuraSignPro_INSTALL_PATH = /Applications
AuraSignPro_FRAMEWORKS = UIKit Foundation Security CoreGraphics QuartzCore SystemConfiguration UniformTypeIdentifiers AudioToolbox
AuraSignPro_LIBRARIES = z sqlite3
AuraSignPro_CODESIGN_FLAGS = -Sentitlements.xml
AuraSignPro_CFLAGS = -fobjc-arc -Isrc/Core -Isrc/App -Wno-deprecated-declarations -Wno-unused-result

# 2. 系统级后台守护进程 aurasignd
TOOL_NAME = aurasignd
aurasignd_FILES = src/Daemon/aurasignd.mm src/Core/AuraSignEngine.mm src/Core/AuraAppleDeveloperAPI.mm
aurasignd_FRAMEWORKS = Foundation UIKit CoreGraphics Security SystemConfiguration AudioToolbox
aurasignd_LIBRARIES = z sqlite3
aurasignd_CODESIGN_FLAGS = -Sentitlements.xml
aurasignd_CFLAGS = -fobjc-arc -Isrc/Core -Wno-deprecated-declarations -Wno-unused-result
aurasignd_INSTALL_PATH = /usr/bin

# 3. 关机掉签强拦截与越狱工具内嵌液态胶囊插件 AuraSignShield.dylib
TWEAK_NAME = AuraSignShield
AuraSignShield_FILES = src/Tweak/AuraSignShield.x src/App/AuraLiquidGlassView.mm src/Core/AuraSignEngine.mm src/Core/AuraAppleDeveloperAPI.mm
AuraSignShield_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics Security AudioToolbox
AuraSignShield_CFLAGS = -fobjc-arc -Isrc/Core -Isrc/App -Wno-deprecated-declarations -Wno-unused-result

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk
