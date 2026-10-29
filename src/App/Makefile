include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AuraSignPro
AuraSignPro_FILES = main.m AuraLiquidGlassView.mm AuraMainViewController.mm ../Core/AuraSignEngine.mm ../Core/AuraAppleDeveloperAPI.mm
AuraSignPro_FRAMEWORKS = UIKit Foundation Security CoreGraphics QuartzCore SystemConfiguration UniformTypeIdentifiers
AuraSignPro_LIBRARIES = z sqlite3
AuraSignPro_CODESIGN_FLAGS = -S../../entitlements.xml
AuraSignPro_CFLAGS = -fobjc-arc -I../Core -I. -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/application.mk
