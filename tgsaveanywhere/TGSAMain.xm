//  TGSaveAnywhere — 注入入口

#import "TGSAHeaders.h"

static void TGSADumpPaths(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSArray *libs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);

    TGSALog(@"Documents: %@", docs.firstObject);
    TGSALog(@"Library:   %@", libs.firstObject);
    TGSALog(@"Caches:    %@", caches.firstObject);

    if (!TGSADiscoveryMode()) return;

    // 列出缓存目录，方便定位 Telegram 的媒体缓存落盘位置
    for (NSString *base in @[libs.firstObject ?: @"", caches.firstObject ?: @""]) {
        if (base.length == 0) continue;
        NSError *e = nil;
        NSArray *items = [fm contentsOfDirectoryAtPath:base error:&e];
        if (e) { TGSALog(@"列目录失败 %@：%@", base, e.localizedDescription); continue; }
        TGSALog(@"目录 %@ 下 %lu 项：", base, (unsigned long)items.count);
        NSUInteger n = 0;
        for (NSString *it in items) {
            TGSALog(@"  - %@", it);
            if (++n > 80) break;
        }
    }
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];

        TGSALog(@"=========================================");
        TGSALog(@"TGSaveAnywhere 已注入");
        TGSALog(@"目标 App: %@ (%@ / build %@)", bid, ver, build);
        TGSALog(@"日志文件: %@", TGSALogPath());
        TGSALog(@"开关状态: Enabled=%d Overlay=%d Discovery=%d",
                 TGSAEnabled(), TGSAShowOverlay(), TGSADiscoveryMode());
        TGSALog(@"=========================================");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TGSADumpPaths();
        });
    }
}
