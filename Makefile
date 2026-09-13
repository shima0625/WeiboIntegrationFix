ARCHS = armv7
TARGET = iphone:clang:9.3:6.0
FINALPACKAGE = 1

PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeiboIntegrationFix
WeiboIntegrationFix_FILES = Tweak.xm
WeiboIntegrationFix_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
