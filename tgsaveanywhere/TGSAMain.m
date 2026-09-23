//  TGSaveAnywhere — 注入入口
//
//  不使用 Logos 的 %ctor，改用 __attribute__((constructor))：
//  巨魔注入器（TrollFools）走的是 dyld 的 LC_LOAD_DYLIB，不经过 Substrate，
//  constructor 一样会被执行，而且不引入任何外部依赖。

#import "TGSAHeaders.h"

#pragma mark - 环境诊断

static void TGSADumpEnvironment(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *docs   = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSArray *libs   = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);

    TGSALog(@"----- 路径 -----");
    TGSALog(@"Bundle:    %@", NSBundle.mainBundle.bundlePath);
    TGSALog(@"Documents: %@", docs.firstObject);
    TGSALog(@"Library:   %@", libs.firstObject);
    TGSALog(@"Caches:    %@", caches.firstObject);

    // App Group（Telegram 的 telegram-data / postbox media 在这里）
    for (NSString *gid in @[@"group.ph.telegra.Telegraph",
                            @"group.ph.telegra.Telegraph.1",
                            @"group.ph.telegra.Telegraph.2"]) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        TGSALog(@"AppGroup %@ -> %@", gid, u ? u.path : @"(不可用)");
    }

    // 越狱环境探测（判断当前是 roothide / rootless / 巨魔哪种注入方式）
    TGSALog(@"----- 环境 -----");
    for (NSString *p in @[@"/var/jb", @"/var/jb/usr/lib", @"/.jbroot",
                          @"/var/mobile/Containers/Shared/AppGroup",
                          @"/usr/lib/libsubstrate.dylib",
                          @"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                          @"/var/jb/usr/lib/libsubstrate.dylib"]) {
        BOOL e = [fm fileExistsAtPath:p];
        TGSALog(@"%@ %@", e ? @"[存在]" : @"[缺失]", p);
    }

    // 本 dylib 自身是从哪里加载的 —— 用来确认是 TweakInject 注入还是巨魔注入
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *n = [NSString stringWithUTF8String:name];
        if ([n.lastPathComponent isEqualToString:@"TGSaveAnywhere.dylib"]) {
            TGSALog(@"本 dylib 加载自：%@", n);
        }
    }

    // AppGroup 容器一览（越狱后可读，用来定位 telegram-data 到底在哪）
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *items = [fm contentsOfDirectoryAtPath:shared error:nil];
    if (items.count) {
        TGSALog(@"AppGroup 容器 %lu 个：", (unsigned long)items.count);
        for (NSString *it in items) {
            NSString *data = [shared stringByAppendingPathComponent:
                              [it stringByAppendingPathComponent:@"telegram-data"]];
            if ([fm fileExistsAtPath:data]) {
                TGSALog(@"  * %@  <-- 含 telegram-data", it);
            }
        }
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void TGSAInit(void) {
    @autoreleasepool {
        NSString *bid   = [[NSBundle mainBundle] bundleIdentifier];
        NSString *ver   = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];

        TGSALog(@"=========================================");
        TGSALog(@"TGSaveAnywhere 已注入");
        TGSALog(@"目标 App: %@ (%@ / build %@)", bid, ver, build);
        TGSALog(@"日志文件: %@", TGSALogPath());
        TGSALog(@"开关: Enabled=%d Overlay=%d 常驻按钮=%d 探测=%d 扫描窗口=%.0fs",
                 TGSAEnabled(), TGSAShowOverlay(), TGSAAlwaysShowButton(),
                 TGSADiscoveryMode(), TGSAScanWindow());
        TGSALog(@"=========================================");

        // 等 App 起来之后再写路径诊断 + 显示常驻按钮，避免 UIKit 还没 ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TGSADumpEnvironment();

            dispatch_async(dispatch_get_main_queue(), ^{
                if (TGSAEnabled() && TGSAAlwaysShowButton()) {
                    [[TGSAOverlay shared] showWithURL:nil];
                    TGSALog(@"已显示常驻按钮（未捕获到 AV 源时，点击会扫描本地缓存）");
                }
            });
        });
    }
}
