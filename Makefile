TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = MAXMods
MAXMods_FILES = Tweak.m MAXModsDim.m
MAXMods_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-objc-protocol-method-implementation
MAXMods_FRAMEWORKS = UIKit Foundation Security
MAXMods_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
MAXMods_LIBRARIES =

include $(THEOS_MAKE_PATH)/library.mk
