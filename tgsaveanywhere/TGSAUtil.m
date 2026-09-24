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

/// 前向声明（定义在"顶层 VC"一节）
static NSArray<UIWindow *> *TGSAAllWindows(void);
static UIWindow *TGSAKeyWindow(void);

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

#pragma mark - 当前聊天标题 / 文件稳定性

BOOL TGSAFileStillGrowing(NSString *path) {
    if (!path.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sizes[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) {
        if (i > 0) [NSThread sleepForTimeInterval:0.7];   // 后台线程调用，sleep 无妨
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        sizes[i] = [attr[NSFileSize] unsignedLongLongValue];
        if (i > 0 && sizes[i] != sizes[i - 1]) return YES;
    }
    return NO;
}

#pragma mark - MP4 结构 / 时长检测

static uint32_t TGSABE32(const unsigned char *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

BOOL TGSAMp4Inspect(NSString *path, NSTimeInterval *_Nullable outDuration) {
    if (outDuration) *outDuration = -1;
    if (!path.length) return NO;

    // 只处理 ftyp 开头的文件（mkv/avi 等不适用）
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    @try {
        NSData *head = [fh readDataOfLength:12];
        if (head.length < 12) return NO;
        const unsigned char *h = head.bytes;
        if (!(h[4] == 'f' && h[5] == 't' && h[6] == 'y' && h[7] == 'p')) return NO;

        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        unsigned long long fsize = [attr[NSFileSize] unsignedLongLongValue];

        unsigned long long off = 0;
        while (off + 8 <= fsize) {
            [fh seekToFileOffset:off];
            NSData *hdr = [fh readDataOfLength:16];
            const unsigned char *b = hdr.bytes;
            if (hdr.length < 8) return NO;
            uint64_t boxSize = TGSABE32(b);
            uint32_t boxType = TGSABE32(b + 4);
            unsigned long long headerLen = 8;
            if (boxSize == 1) {                 // 64 位 largesize
                if (hdr.length < 16) return NO;
                boxSize = 0;
                for (int i = 8; i < 16; i++) boxSize = (boxSize << 8) | b[i];
                headerLen = 16;
            } else if (boxSize == 0) {          // 0 = 延伸到文件尾
                boxSize = fsize - off;
            }
            if (boxSize < headerLen || off + boxSize > fsize) return NO;   // box 越界 → 结构不完整

            // 在 moov 里找 mvhd 读元数据时长
            if (boxType == 0x6D6F6F76 /* moov */ && outDuration && *outDuration < 0) {
                unsigned long long bodyLen = boxSize - headerLen;
                if (bodyLen > 4 * 1024 * 1024) bodyLen = 4 * 1024 * 1024;
                [fh seekToFileOffset:off + headerLen];
                NSData *body = [fh readDataOfLength:(NSUInteger)bodyLen];
                const unsigned char *p = body.bytes;
                for (NSUInteger i = 0; body.length >= 12 && i + 12 <= body.length; i++) {
                    if (p[i] == 'm' && p[i+1] == 'v' && p[i+2] == 'h' && p[i+3] == 'd') {
                        const unsigned char *m = p + i;      // mvhd box 起始
                        uint8_t ver = m[8];
                        if (ver == 0) {
                            uint32_t ts = TGSABE32(m + 20);
                            uint32_t du = TGSABE32(m + 24);
                            if (ts && du && du != 0xFFFFFFFF) *outDuration = (NSTimeInterval)du / ts;
                        } else {                              // version 1：64 位时间
                            uint32_t ts = TGSABE32(m + 28);
                            uint64_t du = 0;
                            for (int k = 32; k < 40; k++) du = (du << 8) | m[k];
                            if (ts && du && du != 0xFFFFFFFFFFFFFFFFULL) *outDuration = (NSTimeInterval)du / ts;
                        }
                        break;
                    }
                }
            }
            off += boxSize;
        }
        return (off == fsize);   // box 链恰好铺满整个文件才算完整
    } @catch (NSException *e) {
        TGSALog(@"mp4 检测异常：%@", e.reason);
        return NO;
    } @finally {
        [fh closeFile];
    }
}

NSString *TGSADurationString(NSTimeInterval seconds) {
    if (seconds < 0) return @"未知";
    NSInteger s = (NSInteger)llround(seconds);
    NSInteger h = s / 3600, m = (s % 3600) / 60;
    s %= 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

#pragma mark - 缓存文件 → 聊天归属（学习式映射）

// Telegram 的缓存文件名是随机 id，无法直接反查属于哪个聊天。
// 做法：每次用户打开文件列表时，把"这次新出现的缓存文件"记录到当前聊天名下
// （用户通常刚在某个聊天里看完视频就点保存）。记录持久化到 filemap.plist。

static NSString *TGSAMapPath(void) {
    return [TGSADocDir() stringByAppendingPathComponent:@"filemap.plist"];
}

NSString *TGSAChatForFile(NSString *path) {
    if (!path.length) return nil;
    NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:TGSAMapPath()];
    NSString *chat = m[path][@"chat"];
    return chat.length ? chat : nil;
}

void TGSARecordChatForFiles(NSArray<NSString *> *paths, NSString *chat) {
    if (!paths.count || !chat.length) return;
    NSMutableDictionary *m = [[NSMutableDictionary dictionaryWithContentsOfFile:TGSAMapPath()] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    BOOL changed = NO;
    for (NSString *p in paths) {
        if (p.length && !m[p]) {
            m[p] = @{ @"chat": chat, @"t": [NSDate date] };
            changed = YES;
        }
    }
    if (!changed) return;
    // 超过 400 条就按时间淘汰最旧的，防止无限膨胀
    if (m.count > 400) {
        NSArray *keys = [m keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"t"] compare:b[@"t"]];
        }];
        for (NSUInteger i = 0; i < m.count - 400 && i < keys.count; i++) [m removeObjectForKey:keys[i]];
    }
    [m writeToFile:TGSAMapPath() atomically:YES];
    TGSALog(@"已记录 %lu 个缓存文件的聊天归属（%@）", (unsigned long)paths.count, chat);
}

/// 递归找一个"像标题"的 UILabel（短文本、非空）
static NSString *TGSAFirstLabelLikeTitle(UIView *v, int depth) {
    if (!v || depth > 6) return nil;
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        NSString *t = [l.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 排除我们自己悬浮按钮上的 "↓" 等符号
        if (t.length > 0 && t.length <= 64 && ![t containsString:@"\n"] && ![t isEqualToString:@"↓"]) return t;
    }
    for (UIView *s in v.subviews) {
        NSString *t = TGSAFirstLabelLikeTitle(s, depth + 1);
        if (t.length) return t;
    }
    return nil;
}

NSString *TGSAActiveChatTitle(void) {
    @try {
        UIViewController *top = TGSATopViewController();

        // 1) 顶层 VC 链上的 navigationItem.title（含 presented / parent 两个方向）
        NSMutableArray<UIViewController *> *chain = [NSMutableArray array];
        UIViewController *vc = top;
        for (int i = 0; vc && i < 12; i++) { if (![chain containsObject:vc]) [chain addObject:vc]; vc = vc.parentViewController; }
        vc = top;
        for (int i = 0; vc.presentedViewController && i < 12; i++) {
            vc = vc.presentedViewController;
            if (![chain containsObject:vc]) [chain addObject:vc];
        }
        for (UIViewController *c in chain) {
            if (c.navigationItem.title.length) return c.navigationItem.title;
        }
        // 2) Telegram 的聊天标题是自绘 titleView，里面有 UILabel
        for (UIViewController *c in chain) {
            UIView *tv = c.navigationItem.titleView;
            if (tv) {
                NSString *t = TGSAFirstLabelLikeTitle(tv, 0);
                if (t.length) return t;
            }
        }
        // 3) 兜底：窗口里找 UIKit 导航栏（跳过我们的小浮窗和没有 rootVC 的辅助窗口）
        NSArray<UIWindow *> *wins = TGSAAllWindows();
        for (UIWindow *w in wins) {
            if (!w.rootViewController) continue;                                   // 我们的浮窗没有 rootVC
            if (CGRectGetWidth(w.bounds) < 100 || CGRectGetHeight(w.bounds) < 100) continue;
            NSString *t = TGSAFirstLabelLikeTitle(w, 0);
            if (t.length) return t;
        }
    } @catch (NSException *e) {
        TGSALog(@"取聊天标题失败：%@", e.reason);
    }
    return nil;
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
