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
    self.currentURL = url;

    UIWindow *window = [self tgsa_window];
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
        [window addSubview:self.button];
    }

    [self.hideTimer invalidate];
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:25.0
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
        }];
    });
}

- (void)tgsa_panned:(UIPanGestureRecognizer *)pan {
    UIWindow *window = [self tgsa_window];
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
    NSURL *url = self.currentURL;
    if (!url) { [self hide]; return; }

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

@end
