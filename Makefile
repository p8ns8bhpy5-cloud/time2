DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include Time2_Build.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Time2
Time2_FILES = $(wildcard Hooks/*.xm Sources/*.m)
Time2_CFLAGS = -fobjc-arc -I./Headers -I./Sources
Time2_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics CoreText QuartzCore
Time2_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Time2Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
