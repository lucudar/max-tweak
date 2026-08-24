TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = MAX
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MAXMods
MAXMods_FILES = Tweak.xm
MAXMods_CFLAGS = -fobjc-arc -Wno-unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk
