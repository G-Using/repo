//  TGSaveAnywhere — 媒体源捕获
//  关键点：Telegram 无论哪个版本，播放视频必然经过 AVFoundation。
//  这一层是 Apple 的 API，稳定且与 Telegram 版本无关，
//  因此「禁止保存内容」只是禁掉了 UI 按钮，播放链路仍然会给出真实源。

#import "TGSAHeaders.h"

%hook AVAsset

+ (instancetype)assetWithURL:(NSURL *)URL {
    AVAsset *a = %orig;
    TGSAReportMediaURL(URL, @"AVAsset+assetWithURL:");
    return a;
}

%end

%hook AVURLAsset

+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    AVURLAsset *a = %orig;
    TGSAReportMediaURL(URL, @"AVURLAsset+URLAssetWithURL:");
    return a;
}

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    AVURLAsset *a = %orig;
    TGSAReportMediaURL(URL, @"AVURLAsset-initWithURL:options:");
    return a;
}

%end

%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
    AVPlayerItem *i = %orig;
    TGSAReportMediaURL(URL, @"AVPlayerItem-initWithURL:");
    return i;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
    AVPlayerItem *i = %orig;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerItem-initWithAsset:keys:");
    }
    return i;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    AVPlayerItem *i = %orig;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerItem-initWithAsset:");
    }
    return i;
}

%end

%hook AVQueuePlayer

- (void)insertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem {
    %orig;
    if ([item.asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)item.asset).URL, @"AVQueuePlayer-insertItem:");
    }
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    if ([item.asset isKindOfClass:AVURLAsset.class]) {
        TGSAReportMediaURL(((AVURLAsset *)item.asset).URL, @"AVPlayer-replaceCurrentItem:");
    }
}

%end

%hook AVAssetResourceLoader

// 若 Telegram 用了自定义 resourceLoader（自定义 scheme），这里会留下线索
- (void)setDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (TGSADiscoveryMode()) {
        TGSALog(@"AVAssetResourceLoader.delegate = %@", delegate ? NSStringFromClass([delegate class]) : @"nil");
    }
}

%end

%hook AVPlayerViewController

- (void)setPlayer:(AVPlayer *)player {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAsset *asset = player.currentItem.asset;
        if ([asset isKindOfClass:AVURLAsset.class]) {
            TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerViewController-setPlayer:");
        }
    });
}

%end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAsset *asset = player.currentItem.asset;
        if ([asset isKindOfClass:AVURLAsset.class]) {
            TGSAReportMediaURL(((AVURLAsset *)asset).URL, @"AVPlayerLayer-setPlayer:");
        }
    });
}

%end
