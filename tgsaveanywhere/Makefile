ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TGSaveAnywhere_FILES = \
	TGSAUtil.m \
	TGSAStore.m \
	TGSAOverlay.m \
	TGSACacheScan.m \
	TGSAMediaCapture.m \
	TGSARestriction.m \
	TGSAMain.m

TGSaveAnywhere_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-error
TGSaveAnywhere_FRAMEWORKS = UIKit Foundation AVFoundation AVKit Photos

# 说明：本项目**不使用 Logos（%hook）**，全部 hook 都是 Objective-C runtime 直接替换，
# 因此不依赖 CydiaSubstrate。好处是同一个 dylib 既能被越狱注入，也能被
# 巨魔注入器（TrollFools）直接插进 App 二进制里使用。

ifeq ($(TROLLSTORE),1)
# 巨魔注入器专用：只产出独立 dylib，不链接 Substrate，也不生成 deb
LIBRARY_NAME = TGSaveAnywhere
include $(THEOS_MAKE_PATH)/library.mk
else
TWEAK_NAME = TGSaveAnywhere
include $(THEOS_MAKE_PATH)/tweak.mk
endif

# 常用命令：
#   make clean package                                        # rootful（checkra1n / unc0ver）
#   make clean package THEOS_PACKAGE_SCHEME=rootless          # rootless（Dopamine / palera1n / roothide）
#   make clean TROLLSTORE=1                                   # 产出裸 dylib，给 TrollFools 注入
#   make clean package DEBUG=1                                # 带符号，方便排查崩溃
