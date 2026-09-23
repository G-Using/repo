//  TGSaveAnywhere — 悬浮下载按钮 + 操作菜单

#import "TGSAHeaders.h"

@implementation TGSAPickerProxy
+ (instancetype)shared {
    static TGSAPickerProxy *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TGSAPickerProxy alloc] init]; });
    return s;
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    TGSALog(@"已导出到：%@", urls.firstObject);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    TGSALog(@"用户取消导出");
}
@end

#pragma mark - 可拖拽按钮

@interface TGSADragButton : UIButton
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint originStart;
@end

@implementation TGSADragButton
@end

#pragma mark - 悬浮层

@interface TGSAOverlay ()
@property (nonatomic, strong) TGSADragButton *button;
@property (nonatomic, strong) NSTimer *hideTimer;
/// 独立悬浮窗口：按钮不能加在 TG 自己的 window 上，
/// 否则聊天界面的手势/转场层会拦走触摸事件 —— 按钮看得见却点不动。
@property (nonatomic, strong) UIWindow *overlayWindow;
- (void)tgsa_menuForURL:(NSURL *)url;
- (void)tgsa_menuForCachedFiles:(BOOL)fullScan;
- (void)tgsa_presentFileList:(NSArray<NSString *> *)files fullScan:(BOOL)fullScan;
- (void)tgsa_menuForFile:(NSString *)src;
@end

@implementation TGSAOverlay

+ (instancetype)shared {
    static TGSAOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TGSAOverlay alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(tgsa_didEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)tgsa_didEnterBackground:(NSNotification *)n {
    [self hide];
}

- (UIWindow *)tgsa_window {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) keyWindow = w;
            }
        }
    }
    if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) keyWindow = w;
        }
#pragma clang diagnostic pop
    }
    return keyWindow;
}

- (void)showForURL:(NSURL *)url {
    [self showWithURL:url];
}

- (UIWindow *)tgsa_overlayWindow {
    UIWindow *key = [self tgsa_window];
    if (!key.windowScene && !key) return nil;

    if (!self.overlayWindow) {
        UIWindow *w = nil;
        if (@available(iOS 13.0, *) && key.windowScene) {
            w = [[UIWindow alloc] initWithWindowScene:key.windowScene];
        } else {
            w = [[UIWindow alloc] initWithFrame:key.bounds];
        }
        w.windowLevel = 100000;              // 压过 TG 的一切界面
        w.backgroundColor = [UIColor clearColor];
        self.overlayWindow = w;
    }
    return self.overlayWindow;
}

- (void)showWithURL:(NSURL *)url {
    self.currentURL = url;

    UIWindow *window = [self tgsa_overlayWindow];
    if (!window) return;

    if (!self.button) {
        TGSADragButton *btn = [TGSADragButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 56, 56);
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
        btn.layer.cornerRadius = 28;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        btn.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
        [btn setTitle:@"↓" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.alpha = 0.0;

        [btn addTarget:self action:@selector(tgsa_tapped) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(tgsa_panned:)];
        [btn addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tgsa_longPressed:)];
        [btn addGestureRecognizer:lp];

        self.button = btn;
    }

    if (self.button.superview != window) {
        [self.button removeFromSuperview];
        CGFloat x = CGRectGetMaxX(window.bounds) - 56 - 12;
        CGFloat y = CGRectGetMidY(window.bounds) - 28;
        self.button.frame = CGRectMake(x, y, 56, 56);
        // 旋转/布局变化后仍大致停在右侧中部
        self.button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin
                                     | UIViewAutoresizingFlexibleRightMargin
                                     | UIViewAutoresizingFlexibleTopMargin
                                     | UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:self.button];
    }
    window.hidden = NO;

    [self.hideTimer invalidate];
    // 抓到明确源时 25 秒自动消失；常驻按钮（无源）给 120 秒，避免刚打开就没了
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:(url ? 25.0 : 120.0)
                                                      target:self
                                                    selector:@selector(hide)
                                                    userInfo:nil
                                                     repeats:NO];

    [UIView animateWithDuration:0.18 animations:^{ self.button.alpha = 1.0; }];
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hideTimer invalidate];
        self.hideTimer = nil;
        [UIView animateWithDuration:0.18 animations:^{ self.button.alpha = 0.0; } completion:^(BOOL f) {
            [self.button removeFromSuperview];
            self.overlayWindow.hidden = YES;   // 整个悬浮窗一起收起，避免空 window 拦触摸
        }];
    });
}

- (void)tgsa_panned:(UIPanGestureRecognizer *)pan {
    UIWindow *window = self.overlayWindow ?: [self tgsa_window];
    if (!window || !self.button) return;
    CGPoint p = [pan translationInView:window];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.button.dragStart = p;
        self.button.originStart = self.button.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat cx = self.button.originStart.x + (p.x - self.button.dragStart.x);
        CGFloat cy = self.button.originStart.y + (p.y - self.button.dragStart.y);
        CGFloat min = 34, maxX = CGRectGetWidth(window.bounds) - 34, maxY = CGRectGetHeight(window.bounds) - 34;
        self.button.center = CGPointMake(MIN(MAX(cx, min), maxX), MIN(MAX(cy, min), maxY));
    }
}

- (void)tgsa_longPressed:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    [self hide];
}

#pragma mark - 菜单

- (void)tgsa_tapped {
    TGSALog(@"按钮被点击（currentURL=%@）", self.currentURL ?: @"nil，走缓存扫描");
    NSURL *url = self.currentURL;
    if (url) {
        [self tgsa_menuForURL:url];
    } else {
        // 没抓到 AV 源（Telegram 自己软解时就是这样）→ 直接扫本地缓存
        [self tgsa_menuForCachedFiles:NO];
    }
}

- (void)tgsa_menuForURL:(NSURL *)url {
    UIViewController *top = TGSATopViewController();
    if (!top) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"保存媒体"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    // 本地缓存已命中：直接复制出来再存
    if (url.isFileURL) {
        NSString *src = url.path;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:src];
        [sheet addAction:[UIAlertAction actionWithTitle:exists ? @"保存到相册" : @"本地文件已失效"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            if (!exists) return;
            NSString *dst = TGSATempPathForExtension(src.pathExtension.length ? src.pathExtension : @"mp4");
            NSError *e = nil;
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e];
            if (e) { TGSALog(@"复制缓存失败：%@", e.localizedDescription); return; }
            TGSASaveVideoAtPathToAlbum(dst);
            [weakSelf hide];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"存储到文件…"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            if (!exists) { TGSAExportFileAtPath(src); return; }
            NSString *dst = TGSATempPathForExtension(src.pathExtension.length ? src.pathExtension : @"mp4");
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
            TGSAExportFileAtPath(dst);
            [weakSelf hide];
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"下载到相册"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            TGSAFetchRemoteURL(url, TGSATopViewController(), ^(NSString *path, NSError *err) {
                if (path) TGSASaveVideoAtPathToAlbum(path);
                [weakSelf hide];
            });
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"下载到文件…"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            TGSAFetchRemoteURL(url, TGSATopViewController(), ^(NSString *path, NSError *err) {
                if (path) TGSAExportFileAtPath(path);
                [weakSelf hide];
            });
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"复制直链"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = url.absoluteString;
        TGSALog(@"已复制直链");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf hide];
    }]];

    // iPad 需要 popover 锚点
    sheet.popoverPresentationController.sourceView = self.button;
    sheet.popoverPresentationController.sourceRect = self.button.bounds;

    [top presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 本地缓存文件菜单

- (void)tgsa_menuForCachedFiles:(BOOL)fullScan {
    UIViewController *top = TGSATopViewController();
    if (!top) return;

    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"正在扫描缓存…"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [top presentViewController:wait animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTimeInterval win = fullScan ? 86400.0 : TGSAScanWindow();
        NSArray<NSString *> *files = TGSAScanRecentVideos(win, 12);
        TGSALog(@"缓存扫描（窗口 %.0fs）命中 %lu 个", win, (unsigned long)files.count);
        for (NSString *f in files) TGSALog(@"  候选：%@", f);

        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                [weakSelf tgsa_presentFileList:files fullScan:fullScan];
            }];
        });
    });
}

- (void)tgsa_presentFileList:(NSArray<NSString *> *)files fullScan:(BOOL)fullScan {
    UIViewController *top = TGSATopViewController();
    if (!top) return;

    __weak typeof(self) weakSelf = self;

    if (files.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没找到视频缓存"
                                                                  message:@"请先在 Telegram 里完整播放一次目标视频，再点这个按钮。\n如果仍找不到，可试试全盘扫描。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"全盘扫描（较慢）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf tgsa_menuForCachedFiles:YES];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"选择要保存的视频"
                                                                message:@"按最近修改时间排序，第一个通常就是刚播放的"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";

    for (NSString *path in files) {
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        double mb = [attr[NSFileSize] unsignedLongLongValue] / 1024.0 / 1024.0;
        NSDate *mt = attr[NSFileModificationDate];
        NSString *title = [NSString stringWithFormat:@"%.1f MB  ·  %@", mb, mt ? [df stringFromDate:mt] : @"?"];
        [list addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf tgsa_menuForFile:path];
        }]];
    }

    if (!fullScan) {
        [list addAction:[UIAlertAction actionWithTitle:@"没找到？全盘扫描（较慢）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf tgsa_menuForCachedFiles:YES];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    list.popoverPresentationController.sourceView = self.button;
    list.popoverPresentationController.sourceRect = self.button.bounds;
    [top presentViewController:list animated:YES completion:nil];
}

- (void)tgsa_menuForFile:(NSString *)src {
    UIViewController *top = TGSATopViewController();
    if (!top) return;

    NSString *ext = TGSAExtensionForVideoFile(src) ?: @"mp4";

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"保存媒体"
                                                                  message:src.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"保存到相册" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *dst = TGSATempPathForExtension(ext);
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        NSError *e = nil;
        [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e];
        if (e) { TGSALog(@"复制失败：%@", e.localizedDescription); return; }
        TGSASaveVideoAtPathToAlbum(dst);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"存储到文件…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *dst = TGSATempPathForExtension(ext);
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
        TGSAExportFileAtPath(dst);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = src;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.button;
    sheet.popoverPresentationController.sourceRect = self.button.bounds;
    [top presentViewController:sheet animated:YES completion:nil];
}

@end
