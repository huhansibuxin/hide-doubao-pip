ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HideDoubaoPiP
HideDoubaoPiP_FILES = Tweak.xm
HideDoubaoPiP_FRAMEWORKS = UIKit Foundation
HideDoubaoPiP_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
