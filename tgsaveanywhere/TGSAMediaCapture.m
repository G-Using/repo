//  TGSaveAnywhere — 媒体源捕获
//
//  重要：这里**不使用 Logos（%hook）**，全部用 Objective-C runtime 直接替换实现。
//  原因：Logos 生成的 hook 依赖 CydiaSubstrate / libsubstrate.dylib，
//  而用巨魔注入器（TrollFools）注入时，dylib 是由 dyld 直接加载的，
//  并不在 Substrate 的注入链路里，dyld 找不到 libsubstrate.dylib 就会加载失败或 hook 静默失效。
//  纯 runtime 实现的 dylib 是自包含的，越狱注入和巨魔注入都能用。

#import "TGSAHeaders.h"

#pragma mark - 原始实现指针

// AVAsset
static id (*orig_AVAsset_assetWithURL)(Class, SEL, NSURL *) = NULL;

// AVURLAsset
static id (*orig_AVURLAsset_URLAssetWithURL)(Class, SEL, NSURL *, NSDictionary *) = NULL;
static id (*orig_AVURLAsset_initWithURL)(id, SEL, NSURL *, NSDictionary *) = NULL;

// AVPlayerItem
static id (*orig_AVPlayerItem_initWithURL)(id, SEL, NSURL *) = NULL;
static id (*orig_AVPlayerItem_initWithAsset)(id, SEL, AVAsset *) = NULL;
static id (*orig_AVPlayerItem_initWithAssetKeys)(id, SEL, AVAsset *, NSArray *) = NULL;

// AVPlayer
static id (*orig_AVPlayer_initWithURL)(id, SEL, NSURL *) = NULL;
static id (*orig_AVPlayer_initWithPlayerItem)(id, SEL, AVPlayerItem *) = NULL;
static void (*orig_AVPlayer_replaceCurrentItem)(id, SEL, AVPlayerItem *) = NULL;

// AVQueuePlayer
static void (*orig_AVQueuePlayer_insertItem)(id, SEL, AVPlayerItem *, AVPlayerItem *) = NULL;

// 图层 / 控制器
static void (*orig_AVPlayerLayer_setPlayer)(id, SEL, AVPlayer *) = NULL;
static void (*orig_AVPlayerVC_setPlayer)(id, SEL, AVPlayer *) = NULL;

// 资源加载器
static void (*orig_AVResourceLoader_setDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

#pragma mark - 替换实现

static id hook_AVAsset_assetWithURL(Class self, SEL _cmd, NSURL *URL) {
    id r = orig_AVAsset_assetWithURL ? orig_AVAsset_assetWithURL(self, _cmd, URL) : nil;
    TGSAReportMediaURL(URL, @"AVAsset+assetWithURL:");
    return r;
}

static id hook_AVURLAsset_URLAssetWithURL(Class self, SEL _cmd, NSURL *URL, NSDictionary *opts) {
    id r = orig_AVURLAsset_URLAssetWithURL ? orig_AVURLAsset_URLAssetWithURL(self, _cmd, URL, opts) : nil;
    TGSAReportMediaURL(URL, @"AVURLAsset+URLAssetWithURL:");
    return r;
}

static id hook_AVURLAsset_initWithURL(id self, SEL _cmd, NSURL *URL, NSDictionary *opts) {
    id r = orig_AVURLAsset_initWithURL ? orig_AVURLAsset_initWithURL(self, _cmd, URL, opts) : nil;
    TGSAReportMediaURL(URL, @"AVURLAsset-initWithURL:options:");
    return r;
}

static id hook_AVPlayerItem_initWithURL(id self, SEL _cmd, NSURL *URL) {
    id r = orig_AVPlayerItem_initWithURL ? orig_AVPlayerItem_initWithURL(self, _cmd, URL) : nil;
    TGSAReportMediaURL(URL, @"AVPlayerItem-initWithURL:");
    return r;
}

static id hook_AVPlayerItem_initWithAsset(id self, SEL _cmd, AVAsset *asset) {
    id r = orig_AVPlayerItem_initWithAsset ? orig_AVPlayerItem_initWithAsset(self, _cmd, asset) : nil;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerItem-initWithAsset:");
    }
    return r;
}

static id hook_AVPlayerItem_initWithAssetKeys(id self, SEL _cmd, AVAsset *asset, NSArray *keys) {
    id r = orig_AVPlayerItem_initWithAssetKeys ? orig_AVPlayerItem_initWithAssetKeys(self, _cmd, asset, keys) : nil;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerItem-initWithAsset:keys:");
    }
    return r;
}

static id hook_AVPlayer_initWithURL(id self, SEL _cmd, NSURL *URL) {
    id r = orig_AVPlayer_initWithURL ? orig_AVPlayer_initWithURL(self, _cmd, URL) : nil;
    TGSAReportMediaURL(URL, @"AVPlayer-initWithURL:");
    return r;
}

static id hook_AVPlayer_initWithPlayerItem(id self, SEL _cmd, AVPlayerItem *item) {
    id r = orig_AVPlayer_initWithPlayerItem ? orig_AVPlayer_initWithPlayerItem(self, _cmd, item) : nil;
    if ([item.asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)item.asset).URL, @"AVPlayer-initWithPlayerItem:");
    }
    return r;
}

static void hook_AVPlayer_replaceCurrentItem(id self, SEL _cmd, AVPlayerItem *item) {
    if (orig_AVPlayer_replaceCurrentItem) orig_AVPlayer_replaceCurrentItem(self, _cmd, item);
    if ([item.asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)item.asset).URL, @"AVPlayer-replaceCurrentItem:");
    }
}

static void hook_AVQueuePlayer_insertItem(id self, SEL _cmd, AVPlayerItem *item, AVPlayerItem *after) {
    if (orig_AVQueuePlayer_insertItem) orig_AVQueuePlayer_insertItem(self, _cmd, item, after);
    if ([item.asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)item.asset).URL, @"AVQueuePlayer-insertItem:");
    }
}

static void hook_AVPlayerLayer_setPlayer(id self, SEL _cmd, AVPlayer *player) {
    if (orig_AVPlayerLayer_setPlayer) orig_AVPlayerLayer_setPlayer(self, _cmd, player);
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAsset *asset = player.currentItem.asset;
        if ([asset isKindOfClass:AVURLAsset.class]) {
            TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerLayer-setPlayer:");
        }
    });
}

static void hook_AVPlayerVC_setPlayer(id self, SEL _cmd, AVPlayer *player) {
    if (orig_AVPlayerVC_setPlayer) orig_AVPlayerVC_setPlayer(self, _cmd, player);
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAsset *asset = player.currentItem.asset;
        if ([asset isKindOfClass:AVURLAsset.class]) {
            TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerViewController-setPlayer:");
        }
    });
}

static void hook_AVResourceLoader_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (orig_AVResourceLoader_setDelegate) orig_AVResourceLoader_setDelegate(self, _cmd, delegate, queue);
    if (TGSADiscoveryMode()) {
        TGSALog(@"AVAssetResourceLoader.delegate = %@", delegate ? NSStringFromClass([delegate class]) : @"nil");
    }
}

#pragma mark - 安装

__attribute__((constructor))
static void TGSAMediaCaptureInit(void) {
    // 这里只做 runtime 替换，不触碰 UIKit / 不依赖 App 生命周期，dyld 阶段执行是安全的
    @autoreleasepool {
        int ok = 0, total = 0;

#define TGSASWIZZLE_CLASS(cls, sel, imp, store)                              \
        do {                                                                 \
            total++;                                                         \
            IMP o = NULL;                                                    \
            if (TGSASwizzleClassRaw(cls, sel, (IMP)imp, &o)) { ok++;         \
                store = (__typeof__(store))o; }                              \
            else { TGSALog(@"hook 失败：+[%@ %@]", cls, NSStringFromSelector(sel)); } \
        } while (0)

#define TGSASWIZZLE_INST(cls, sel, imp, store)                               \
        do {                                                                 \
            total++;                                                         \
            IMP o = NULL;                                                    \
            if (TGSASwizzleInstanceRaw(cls, sel, (IMP)imp, &o)) { ok++;      \
                store = (__typeof__(store))o; }                              \
            else { TGSALog(@"hook 失败：-[%@ %@]", cls, NSStringFromSelector(sel)); } \
        } while (0)

        TGSASWIZZLE_CLASS(AVAsset.class, @selector(assetWithURL:),
                          hook_AVAsset_assetWithURL, orig_AVAsset_assetWithURL);

        TGSASWIZZLE_CLASS(AVURLAsset.class, @selector(URLAssetWithURL:options:),
                          hook_AVURLAsset_URLAssetWithURL, orig_AVURLAsset_URLAssetWithURL);
        TGSASWIZZLE_INST(AVURLAsset.class, @selector(initWithURL:options:),
                         hook_AVURLAsset_initWithURL, orig_AVURLAsset_initWithURL);

        TGSASWIZZLE_INST(AVPlayerItem.class, @selector(initWithURL:),
                         hook_AVPlayerItem_initWithURL, orig_AVPlayerItem_initWithURL);
        TGSASWIZZLE_INST(AVPlayerItem.class, @selector(initWithAsset:),
                         hook_AVPlayerItem_initWithAsset, orig_AVPlayerItem_initWithAsset);
        TGSASWIZZLE_INST(AVPlayerItem.class, @selector(initWithAsset:automaticallyLoadedAssetKeys:),
                         hook_AVPlayerItem_initWithAssetKeys, orig_AVPlayerItem_initWithAssetKeys);

        TGSASWIZZLE_INST(AVPlayer.class, @selector(initWithURL:),
                         hook_AVPlayer_initWithURL, orig_AVPlayer_initWithURL);
        TGSASWIZZLE_INST(AVPlayer.class, @selector(initWithPlayerItem:),
                         hook_AVPlayer_initWithPlayerItem, orig_AVPlayer_initWithPlayerItem);
        TGSASWIZZLE_INST(AVPlayer.class, @selector(replaceCurrentItemWithPlayerItem:),
                         hook_AVPlayer_replaceCurrentItem, orig_AVPlayer_replaceCurrentItem);

        TGSASWIZZLE_INST(AVQueuePlayer.class, @selector(insertItem:afterItem:),
                         hook_AVQueuePlayer_insertItem, orig_AVQueuePlayer_insertItem);

        TGSASWIZZLE_INST(AVPlayerLayer.class, @selector(setPlayer:),
                         hook_AVPlayerLayer_setPlayer, orig_AVPlayerLayer_setPlayer);
        TGSASWIZZLE_INST(AVPlayerViewController.class, @selector(setPlayer:),
                         hook_AVPlayerVC_setPlayer, orig_AVPlayerVC_setPlayer);

        TGSASWIZZLE_INST(AVAssetResourceLoader.class, @selector(setDelegate:queue:),
                         hook_AVResourceLoader_setDelegate, orig_AVResourceLoader_setDelegate);

        TGSALog(@"AV 层 hook 安装完成：%d/%d", ok, total);
    }
}
