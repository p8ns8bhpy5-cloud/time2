include ../Time2_Build.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Time2Prefs
Time2Prefs_FILES = $(wildcard *.m)
Time2Prefs_CFLAGS = -fobjc-arc
Time2Prefs_FRAMEWORKS = UIKit Foundation
Time2Prefs_PRIVATE_FRAMEWORKS = Preferences
Time2Prefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
