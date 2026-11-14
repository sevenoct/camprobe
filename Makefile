export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CamProbe

CamProbe_FILES = Tweak.x
CamProbe_CFLAGS = -fobjc-arc
CamProbe_FRAMEWORKS = UIKit AVFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
