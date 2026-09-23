//  TGSaveAnywhere — 日志 / 配置 / runtime 工具
//  纯 Objective-C，不依赖 Logos

#import "TGSAHeaders.h"

#pragma mark - 目录与日志

NSString *TGSADocDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        dir = [[paths.firstObject stringByAppendingPathComponent:@"TGSaveAnywhere"] copy];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    });
    return dir;
}

NSString *TGSALogPath(void) {
    return [TGSADocDir() stringByAppendingPathComponent:@"tgsaveanywhere.log"];
}

void TGSALog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSLog(@"[TGSaveAnywhere] %@", msg);

    static dispatch_queue_t q = NULL;
    static dispatch_once_t qonce;
    dispatch_once(&qonce, ^{ q = dispatch_queue_create("tgsa.log", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        NSString *p = TGSALogPath();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        // 超过 2MB 就截断，避免日志无限增长
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
            [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
}

#pragma mark - 配置

static NSDictionary *TGSAConfig(void) {
    static NSDictionary *cfg = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *candidates = @[
            [TGSADocDir() stringByAppendingPathComponent:@"config.plist"],
            @"/var/mobile/Library/Preferences/com.gusing.tgsaveanywhere.plist"
        ];
        for (NSString *p in candidates) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (d.count) {
                cfg = [d copy];
                TGSALog(@"已加载配置：%@", p);
                break;
            }
        }
        if (!cfg) {
            // 首次运行写一份模板到 App 的 Documents（Filza 可直接编辑）
            cfg = @{ @"Enabled": @YES,
                     @"ShowOverlay": @YES,
                     @"AlwaysShowButton": @YES,
                     @"DiscoveryMode": @NO,
                     @"ScanWindowSeconds": @900,
                     @"ForceTrueHooks": @[] };
            NSString *tpl = [TGSADocDir() stringByAppendingPathComponent:@"config.plist"];
            [cfg writeToFile:tpl atomically:YES];
            TGSALog(@"未找到配置，已生成模板：%@", tpl);
        }
    });
    return cfg;
}

id TGSASetting(NSString *key, id defaultValue) {
    id v = TGSAConfig()[key];
    return v ?: defaultValue;
}

BOOL TGSAEnabled(void)       { return [TGSASetting(@"Enabled", @YES) boolValue]; }
BOOL TGSAShowOverlay(void)   { return [TGSASetting(@"ShowOverlay", @YES) boolValue]; }
BOOL TGSAAlwaysShowButton(void) { return [TGSASetting(@"AlwaysShowButton", @YES) boolValue]; }
BOOL TGSADiscoveryMode(void) { return [TGSASetting(@"DiscoveryMode", @NO) boolValue]; }
NSTimeInterval TGSAScanWindow(void) {
    id v = TGSASetting(@"ScanWindowSeconds", @900);
    NSTimeInterval t = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 900.0;
    if (t < 30) t = 30;
    if (t > 86400) t = 86400;
    return t;
}

#pragma mark - Runtime 工具

void TGSACopyReturnType(Method m, char *dst, size_t dstLen) {
    if (!dst || dstLen == 0) return;
    dst[0] = '\0';
    if (!m) return;
    // iOS 17+ SDK: void method_getReturnType(Method m, char *dst, size_t dst_len)
    method_getReturnType(m, dst, dstLen);
}

/// 只接受返回值安全的方法：void / BOOL / char / bool
BOOL TGSAReturnTypeIsSafe(Method m) {
    char rt[64] = {0};
    TGSACopyReturnType(m, rt, sizeof(rt));
    return strcmp(rt, "v") == 0 || strcmp(rt, "B") == 0 || strcmp(rt, "c") == 0 || strcmp(rt, "b") == 0;
}

BOOL TGSASwizzleInstance(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;                       // 只 hook 真实存在的方法，不凭空注入
    if (!TGSAReturnTypeIsSafe(m)) return NO; // 避免返回一个伪造的对象指针导致崩溃
    IMP orig = method_getImplementation(m);
    IMP prev = class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
    if (!orig) orig = prev;
    if (outOriginal) *outOriginal = orig;
    return YES;
}

BOOL TGSASwizzleClass(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    Class meta = object_getClass((id)cls);
    Method m = class_getClassMethod(meta, sel);
    if (!m) m = class_getInstanceMethod(meta, sel);
    if (!m) return NO;
    if (!TGSAReturnTypeIsSafe(m)) return NO;
    IMP orig = method_getImplementation(m);
    IMP prev = class_replaceMethod(meta, sel, replacement, method_getTypeEncoding(m));
    if (!orig) orig = prev;
    if (outOriginal) *outOriginal = orig;
    return YES;
}

#pragma mark - Raw swizzle（不做返回值类型检查，调用方自己保证签名正确）

BOOL TGSASwizzleInstanceRaw(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    IMP prev = class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
    if (!orig) orig = prev;
    if (outOriginal) *outOriginal = orig;
    return YES;
}

BOOL TGSASwizzleClassRaw(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    Class meta = object_getClass((id)cls);
    Method m = class_getClassMethod(meta, sel);
    if (!m) m = class_getInstanceMethod(meta, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    IMP prev = class_replaceMethod(meta, sel, replacement, method_getTypeEncoding(m));
    if (!orig) orig = prev;
    if (outOriginal) *outOriginal = orig;
    return YES;
}

#pragma mark - 顶层 VC

/// 收集当前所有可用窗口（iOS 13+ 走 scene，旧版回退到 UIApplication.windows）
static NSArray<UIWindow *> *TGSAAllWindows(void) {
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w) [all addObject:w];
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w && ![all containsObject:w]) [all addObject:w];
    }
#pragma clang diagnostic pop
    return all;
}

/// keyWindow（可能被我们自己或其他辅助窗口占着，所以单独取一次）
static UIWindow *TGSAKeyWindow(void) {
    for (UIWindow *w in TGSAAllWindows()) {
        if (w.isKeyWindow) return w;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

UIViewController *TGSATopViewController(void) {
    // 不要只认 keyWindow：Telegram 有多个窗口，keyWindow 有时是辅助窗口，
    // rootViewController 为 nil —— 那样取出来就是 nil，菜单会静默弹不出来。
    NSArray<UIWindow *> *windows = TGSAAllWindows();
    NSArray *sorted = [windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];

    // 优先 keyWindow
    UIWindow *key = TGSAKeyWindow();
    if (key && key.rootViewController && !key.hidden) {
        [candidates addObject:key.rootViewController];
    }
    // 其次所有可见、有 rootVC 的窗口（跳过我们自己的小浮窗：它没有 rootVC，自然被过滤）
    for (UIWindow *w in sorted) {
        if (w.hidden || w.alpha < 0.01) continue;
        if (CGRectGetWidth(w.bounds) < 100 || CGRectGetHeight(w.bounds) < 100) continue;  // 排除小浮窗
        if (w.rootViewController && ![candidates containsObject:w.rootViewController]) {
            [candidates addObject:w.rootViewController];
        }
    }

    for (UIViewController *root in candidates) {
        UIViewController *vc = root;
        NSInteger guard = 0;
        while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed && guard++ < 16) {
            vc = vc.presentedViewController;
        }
        if (vc.view.window || vc == root) return vc;
    }
    return candidates.firstObject;
}
