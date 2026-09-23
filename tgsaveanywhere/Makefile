ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TGSaveAnywhere

TGSaveAnywhere_FILES = \
	TGSAUtil.m \
	TGSAStore.m \
	TGSAOverlay.m \
	TGSAMediaCapture.xm \
	TGSARestriction.xm \
	TGSAMain.xm

TGSaveAnywhere_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations
TGSaveAnywhere_FRAMEWORKS = UIKit Foundation AVFoundation AVKit Photos

include $(THEOS_MAKE_PATH)/tweak.mk

# 常用命令：
#   make clean package                      # rootful（checkra1n / unc0ver）
#   make clean package THEOS_PACKAGE_SCHEME=rootless   # rootless（Dopamine / palera1n / Serotonin）
#   make clean package DEBUG=1              # 带符号，方便排查崩溃
