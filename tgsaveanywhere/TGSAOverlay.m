//  TGSaveAnywhere — 悬浮下载按钮 + 操作菜单

#import "TGSAHeaders.h"

#pragma mark - 菜单弹出的兜底通道
//
//  Telegram 的窗口层级很复杂，keyWindow 有时是辅助窗口（rootViewController 为 nil），
//  直接 present 会静默失败 —— 表现就是"点了按钮但什么都没弹出来"。
//  这里做两级：先正常 present，失败/取不到承载 VC 就用一个临时全屏窗口弹，
//  菜单关闭后自动把焦点还给 Telegram，避免抢走 key 导致界面点不动。

static UIWindow *gTGSAFallbackWindow = nil;
static UIWindow *gTGSAFallbackPrevKey = nil;

static UIWindow *TGSAFindKeyWindow(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) key = w;
            }
        }
    }
    if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) key = w;
        }
        if (!key) key = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    return key;
}

static void TGSAReleaseFallbackWindow(void) {
    if (gTGSAFallbackWindow) {
        gTGSAFallbackWindow.hidden = YES;
        gTGSAFallbackWindow = nil;
    }
    if (gTGSAFallbackPrevKey) {
        [gTGSAFallbackPrevKey makeKeyAndVisible];   // 焦点还给 Telegram
        gTGSAFallbackPrevKey = nil;
        TGSALog(@"菜单已关闭，焦点已交还 Telegram");
    }
}

static void TGSAPresentOnFallbackWindow(UIAlertController *alert) {
    UIWindow *prevKey = TGSAFindKeyWindow();

    UIWindow *tmp = nil;
    if (@available(iOS 13.0, *) && prevKey.windowScene) {
        tmp = [[UIWindow alloc] initWithWindowScene:prevKey.windowScene];
    } else {
        tmp = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    tmp.frame = prevKey ? prevKey.bounds : UIScreen.mainScreen.bounds;
    tmp.windowLevel = UIWindowLevelAlert + 10.0;
    tmp.backgroundColor = [UIColor clearColor];
    tmp.opaque = NO;

    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = [UIColor clearColor];
    host.view.opaque = NO;
    tmp.rootViewController = host;

    gTGSAFallbackWindow = tmp;
    gTGSAFallbackPrevKey = prevKey;

    [tmp makeKeyAndVisible];
    [host presentViewController:alert animated:YES completion:nil];
    TGSALog(@"菜单已在兜底窗口弹出");

    // 菜单被关闭后回收窗口 + 还焦点（alert dismiss 后 view.window 会变 nil）
    __block NSInteger ticks = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        ticks++;
        BOOL dismissed = (alert.view.window == nil) || (alert.presentingViewController == nil);
        if (!dismissed && ticks < 1500) return;
        [t invalidate];
        TGSAReleaseFallbackWindow();
    }];
}

/// 统一入口：所有菜单都走这里
static void TGSAPresentAlert(UIAlertController *alert) {
    if (!alert) return;

    UIViewController *presenter = TGSATopViewController();
    if (presenter && presenter.view.window) {
        @try {
            [presenter presentViewController:alert animated:YES completion:nil];
            TGSALog(@"菜单已弹出（承载 VC：%@）", NSStringFromClass(presenter.class));
            return;
        } @catch (NSException *e) {
            TGSALog(@"常规弹出失败：%@ —— 改用兜底窗口", e.reason);
        }
    } else {
        TGSALog(@"未取到可承载菜单的 VC（top=%@）—— 改用兜底窗口", presenter);
    }
    TGSAPresentOnFallbackWindow(alert);
}

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

#pragma mark - 穿透式悬浮窗口
//
//  关键：悬浮窗必须"只占按钮那么大一塊地"，并且按钮以外的触摸要原样还给 App。
//  之前用全屏 UIWindow 导致整个 Telegram 界面点不动 —— 空白区域的触摸全被这层吃掉了。

@interface TGSAFloatWindow : UIWindow
/// 只有这个视图（及其子视图）能接收触摸；其余一律返回 nil 穿透到下层 App
@property (nonatomic, weak) UIView *tgsa_touchTarget;
@end

@implementation TGSAFloatWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    UIView *target = self.tgsa_touchTarget;
    if (target && (hit == target || [hit isDescendantOfView:target])) return hit;
    return nil;   // 命中空白 / 背景 → 穿透，交给下面的 App 处理
}

@end

#pragma mark - 悬浮层

static const CGFloat TGSAButtonSize = 56.0;
static const CGFloat TGSAWindowSize = 62.0;   // 比按钮略大，留出描边和阴影

@interface TGSAOverlay ()
@property (nonatomic, strong) TGSADragButton *button;
@property (nonatomic, strong) NSTimer *hideTimer;
@property (nonatomic, strong) TGSAFloatWindow *overlayWindow;
@property (nonatomic, assign) BOOL observersInstalled;
@property (nonatomic, assign) BOOL userMoved;      // 用户是否手动拖过（拖过就不再自动归位）
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
        // 生命周期监听放在第一次 show 时才注册（constructor 阶段 UIKit 未必 ready）
    }
    return self;
}

#pragma mark - 生命周期：解决"回桌面再进箭头没了"

- (void)tgsa_installObservers {
    if (self.observersInstalled) return;
    self.observersInstalled = YES;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // 回到前台 / 重新激活 → 把按钮重新挂出来
    [nc addObserver:self selector:@selector(tgsa_willEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(tgsa_didBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(tgsa_didEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(tgsa_orientationChanged:)
               name:UIDeviceOrientationDidChangeNotification object:nil];
    if (!UIDevice.currentDevice.isGeneratingDeviceOrientationNotifications) {
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    }
    TGSALog(@"生命周期监听已注册（前台恢复会自动重新显示按钮）");
}

- (void)tgsa_didEnterBackground:(NSNotification *)n {
    [self hide];
}

- (void)tgsa_willEnterForeground:(NSNotification *)n {
    [self tgsa_restoreAfterDelay:0.6];
}

- (void)tgsa_didBecomeActive:(NSNotification *)n {
    [self tgsa_restoreAfterDelay:0.35];
}

- (void)tgsa_restoreAfterDelay:(NSTimeInterval)delay {
    if (!TGSAEnabled() || !TGSAShowOverlay()) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!TGSAEnabled() || !TGSAShowOverlay()) return;
        // 保留已捕获到的源；没有就显示常驻按钮（点击后扫本地缓存）
        [self showWithURL:self.currentURL];
        TGSALog(@"回到前台，按钮已恢复显示（源=%@）", self.currentURL ?: @"nil，走缓存扫描");
    });
}

- (void)tgsa_orientationChanged:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlayWindow || self.overlayWindow.hidden) return;
        [self tgsa_clampIntoScreen];
    });
}

#pragma mark - 窗口

- (UIWindow *)tgsa_keyWindow {
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

/// 悬浮窗只有按钮那么大，绝不做成全屏 —— 否则会吃掉整个 App 的触摸
- (TGSAFloatWindow *)tgsa_overlayWindow {
    if (self.overlayWindow) return self.overlayWindow;

    UIWindow *key = [self tgsa_keyWindow];
    CGRect screen = key ? key.bounds : UIScreen.mainScreen.bounds;

    TGSAFloatWindow *w = nil;
    if (@available(iOS 13.0, *) && key.windowScene) {
        w = [[TGSAFloatWindow alloc] initWithWindowScene:key.windowScene];
    } else {
        w = [[TGSAFloatWindow alloc] initWithFrame:screen];
    }
    w.backgroundColor = [UIColor clearColor];
    w.opaque = NO;
    // 高于状态栏即可；不要压过 UIWindowLevelAlert，否则自己的菜单弹窗会被盖住
    w.windowLevel = UIWindowLevelStatusBar + 10.0;

    CGFloat x = CGRectGetMaxX(screen) - TGSAWindowSize - 8;
    CGFloat y = CGRectGetMidY(screen) - TGSAWindowSize / 2.0;
    w.frame = CGRectMake(x, y, TGSAWindowSize, TGSAWindowSize);

    self.overlayWindow = w;
    TGSALog(@"悬浮窗已创建（%.0fx%.0f，level=%.0f）", TGSAWindowSize, TGSAWindowSize, w.windowLevel);
    return w;
}

- (void)showForURL:(NSURL *)url {
    [self showWithURL:url];
}

- (void)showWithURL:(NSURL *)url {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showWithURL:url]; });
        return;
    }
    if (url) self.currentURL = url;
    if (!TGSAEnabled() || !TGSAShowOverlay()) return;

    [self tgsa_installObservers];

    TGSAFloatWindow *window = [self tgsa_overlayWindow];
    if (!window) return;

    if (!self.button) {
        TGSADragButton *btn = [TGSADragButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake((TGSAWindowSize - TGSAButtonSize) / 2.0,
                               (TGSAWindowSize - TGSAButtonSize) / 2.0,
                               TGSAButtonSize, TGSAButtonSize);
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
        btn.layer.cornerRadius = TGSAButtonSize / 2.0;
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
        [window addSubview:self.button];
    }
    window.tgsa_touchTarget = self.button;
    if (window.hidden) {
        if (!self.userMoved) {
            UIWindow *key = [self tgsa_keyWindow];
            CGRect screen = key ? key.bounds : UIScreen.mainScreen.bounds;
            window.frame = CGRectMake(CGRectGetMaxX(screen) - TGSAWindowSize - 8,
                                      CGRectGetMidY(screen) - TGSAWindowSize / 2.0,
                                      TGSAWindowSize, TGSAWindowSize);
        }
        window.hidden = NO;
    }
    [self tgsa_clampIntoScreen];

    [self tgsa_scheduleHideForURL:url];

    [UIView animateWithDuration:0.18 animations:^{ self.button.alpha = 1.0; }];

    [self tgsa_ensureAppKeepsFocus];
}

/// 兜底保护：万一系统把 keyWindow 判给了我们的小浮窗，Telegram 会整体失去焦点
/// （表现就是"整个页面点不动"）。这里检测到就立刻把焦点还给 App 主窗口。
- (void)tgsa_ensureAppKeepsFocus {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *key = TGSAFindKeyWindow();
        if (key != self.overlayWindow) return;

        UIWindow *main = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w == self.overlayWindow || w.hidden || !w.rootViewController) continue;
                    main = w;
                }
            }
        }
        if (!main) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w == self.overlayWindow || w.hidden || !w.rootViewController) continue;
                main = w;
            }
#pragma clang diagnostic pop
        }
        if (main) {
            [main makeKeyAndVisible];
            TGSALog(@"检测到焦点被浮窗抢走，已还给 App 主窗口");
        }
    });
}

/// 自动隐藏：默认常驻不消失；只有抓到明确 AV 源时才用 25 秒倒计时。
/// 想统一改成 N 秒后消失，在 config.plist 里设 AutoHideSeconds 即可（0 = 常驻）。
- (void)tgsa_scheduleHideForURL:(NSURL *)url {
    [self.hideTimer invalidate];
    self.hideTimer = nil;

    NSTimeInterval configured = [TGSASetting(@"AutoHideSeconds", @0) doubleValue];
    NSTimeInterval seconds = configured > 0 ? configured : (url ? 25.0 : 0);
    if (seconds <= 0) return;

    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:seconds
                                                      target:self
                                                    selector:@selector(hide)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)tgsa_clampIntoScreen {
    TGSAFloatWindow *window = self.overlayWindow;
    if (!window) return;
    UIWindow *key = [self tgsa_keyWindow];
    CGRect b = key ? key.bounds : UIScreen.mainScreen.bounds;
    CGFloat w = CGRectGetWidth(window.frame), h = CGRectGetHeight(window.frame);
    CGFloat x = MIN(MAX(CGRectGetMinX(window.frame), 4), CGRectGetWidth(b) - w - 4);
    CGFloat y = MIN(MAX(CGRectGetMinY(window.frame), 4), CGRectGetHeight(b) - h - 4);
    window.frame = CGRectMake(x, y, w, h);
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hideTimer invalidate];
        self.hideTimer = nil;
        TGSAFloatWindow *window = self.overlayWindow;
        [UIView animateWithDuration:0.18 animations:^{ self.button.alpha = 0.0; } completion:^(BOOL f) {
            window.hidden = YES;      // 整窗收起，确保屏幕上不留任何可拦截触摸的层
            self.button.alpha = 1.0;  // 复位，下次显示时动画正常
        }];
    });
}

#pragma mark - 手势（拖动作用在整个小窗口上，而不是按钮内部坐标）

- (void)tgsa_panned:(UIPanGestureRecognizer *)pan {
    TGSAFloatWindow *window = self.overlayWindow;
    if (!window) return;
    CGPoint p = [pan translationInView:window.superview ?: window];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.button.dragStart = p;
        self.button.originStart = window.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.button.originStart.x + (p.x - self.button.dragStart.x),
                                self.button.originStart.y + (p.y - self.button.dragStart.y));
        UIWindow *key = [self tgsa_keyWindow];
        CGRect b = key ? key.bounds : UIScreen.mainScreen.bounds;
        CGFloat half = TGSAWindowSize / 2.0;
        window.center = CGPointMake(MIN(MAX(c.x, half + 2), CGRectGetWidth(b) - half - 2),
                                    MIN(MAX(c.y, half + 2), CGRectGetHeight(b) - half - 2));
        self.userMoved = YES;
    }
}

- (void)tgsa_longPressed:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    TGSALog(@"长按隐藏按钮");
    [self hide];
}

#pragma mark - 菜单

- (void)tgsa_tapped {
    TGSALog(@"按钮被点击（currentURL=%@）", self.currentURL ?: @"nil，走缓存扫描");

    // 点击反馈：先给个缩放动画，确认触摸确实到了按钮
    [UIView animateWithDuration:0.08 animations:^{ self.button.transform = CGAffineTransformMakeScale(0.86, 0.86); }
                     completion:^(BOOL f) {
        [UIView animateWithDuration:0.12 animations:^{ self.button.transform = CGAffineTransformIdentity; }];
    }];

    NSURL *url = self.currentURL;
    if (url) {
        [self tgsa_menuForURL:url];
    } else {
        // 没抓到 AV 源（Telegram 自己软解时就是这样）→ 直接扫本地缓存
        [self tgsa_menuForCachedFiles:NO];
    }
}

- (void)tgsa_menuForURL:(NSURL *)url {
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
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"存储到文件…"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            if (!exists) { TGSAExportFileAtPath(src); return; }
            NSString *dst = TGSATempPathForExtension(src.pathExtension.length ? src.pathExtension : @"mp4");
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
            TGSAExportFileAtPath(dst);
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"下载到相册"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            TGSAFetchRemoteURL(url, TGSATopViewController(), ^(NSString *path, NSError *err) {
                if (path) TGSASaveVideoAtPathToAlbum(path);
            });
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"下载到文件…"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            TGSAFetchRemoteURL(url, TGSATopViewController(), ^(NSString *path, NSError *err) {
                if (path) TGSAExportFileAtPath(path);
            });
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"复制直链"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = url.absoluteString;
        TGSALog(@"已复制直链");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏按钮" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf hide];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要 popover 锚点（iPhone 上无效，sourceView 不在窗口里就跳过）
    if (self.button && self.button.window) {
        sheet.popoverPresentationController.sourceView = self.button;
        sheet.popoverPresentationController.sourceRect = self.button.bounds;
    }

    TGSAPresentAlert(sheet);
}

#pragma mark - 本地缓存文件菜单

- (void)tgsa_menuForCachedFiles:(BOOL)fullScan {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"正在扫描缓存…"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    TGSAPresentAlert(wait);

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
    __weak typeof(self) weakSelf = self;

    if (files.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没找到视频缓存"
                                                                  message:@"请先在 Telegram 里完整播放一次目标视频，再点这个按钮。\n如果仍找不到，可试试全盘扫描。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"全盘扫描（较慢）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf tgsa_menuForCachedFiles:YES];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        TGSAPresentAlert(a);
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
    [list addAction:[UIAlertAction actionWithTitle:@"隐藏按钮" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [weakSelf hide];
    }]];
    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (self.button && self.button.window) {
        list.popoverPresentationController.sourceView = self.button;
        list.popoverPresentationController.sourceRect = self.button.bounds;
    }
    TGSAPresentAlert(list);
}

- (void)tgsa_menuForFile:(NSString *)src {
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

    if (self.button && self.button.window) {
        sheet.popoverPresentationController.sourceView = self.button;
        sheet.popoverPresentationController.sourceRect = self.button.bounds;
    }
    TGSAPresentAlert(sheet);
}

@end
