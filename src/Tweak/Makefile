include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AuraSignShield
AuraSignShield_FILES = AuraSignShield.x ../App/AuraLiquidGlassView.mm ../Core/AuraSignEngine.mm ../Core/AuraAppleDeveloperAPI.mm
AuraSignShield_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics Security
AuraSignShield_CFLAGS = -fobjc-arc -I../Core -I../App -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
