//  TGSaveAnywhere — Telegram 本地媒体缓存扫描
//
//  为什么需要这个文件：
//  Telegram 的绝大多数视频走的是自带的 ffmpeg 软解（SoftwareVideoLayer / Metal 自绘），
//  **根本不经过 AVFoundation**，所以只 hook AVAsset / AVPlayer 是抓不到源的。
//  但不管用什么解码，视频文件一定会在本地留下一份缓存（postbox media 目录），
//  而且普通频道的缓存就是**明文 mp4**（「禁止保存」只是 UI 层禁了按钮 + 防截屏，文件本身没加密）。
//  所以直接从磁盘上把「刚刚被读写的那个视频文件」找出来，才是最稳的路子。
//
//  缓存文件通常没有扩展名，因此这里用**文件头魔数**判断类型，不看后缀。

#import "TGSAHeaders.h"

#pragma mark - 文件类型判断

static BOOL TGSAHasMagic(FILE *f, NSString *path) {
    (void)path;
    return f != NULL;
}

/// 读文件头判断是否为视频/动图，返回合适的扩展名（不匹配返回 nil）
NSString *TGSAExtensionForVideoFile(NSString *path) {
    if (!path) return nil;
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;

    unsigned char b[512];
    size_t n = fread(b, 1, sizeof(b), f);
    fclose(f);
    if (n < 12) return nil;

    // ISO BMFF：mp4 / mov / m4v / 3gp —— 第 4 字节起是 "ftyp"
    if (memcmp(b + 4, "ftyp", 4) == 0) {
        // 进一步区分 3gp / mp4 / mov
        if (memcmp(b + 8, "3gp", 3) == 0) return @"3gp";
        if (memcmp(b + 8, "qt", 2) == 0)  return @"mov";
        if (memcmp(b + 8, "M4V", 3) == 0) return @"m4v";
        return @"mp4";
    }
    // Matroska / WebM
    if (memcmp(b, "\x1A\x45\xDF\xA3", 4) == 0) return @"mkv";
    // RIFF....AVI / WEBP
    if (memcmp(b, "RIFF", 4) == 0) {
        if (memcmp(b + 8, "AVI ", 4) == 0) return @"avi";
        if (memcmp(b + 8, "WEBP", 4) == 0) return @"webp";
    }
    // GIF
    if (memcmp(b, "GIF8", 4) == 0) return @"gif";
    // FLV
    if (memcmp(b, "FLV\x01", 4) == 0) return @"flv";
    // Ogg
    if (memcmp(b, "OggS", 4) == 0) return @"ogv";
    // MPEG-TS（0x47 同步字节，188 字节包长）
    if (b[0] == 0x47 && b[188] == 0x47) return @"ts";
    // ASF / WMV
    if (memcmp(b, "\x30\x26\xB2\x75", 4) == 0) return @"wmv";

    return nil;
}

#pragma mark - 目录收集

static NSArray<NSString *> *TGSACandidateRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) App Group：Telegram 把 telegram-data（含 postbox/media）放在这里
    NSArray *groupIds = @[
        @"group.ph.telegra.Telegraph",
        @"group.ph.telegra.Telegraph.1",
        @"group.ph.telegra.Telegraph.2",
    ];
    for (NSString *gid in groupIds) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        if (!u) continue;
        NSString *data = [u.path stringByAppendingPathComponent:@"telegram-data"];
        if ([fm fileExistsAtPath:data]) [roots addObject:data];
        [roots addObject:u.path];
    }

    // 2) 兜底：越狱后直接扫 AppGroup 容器目录（有些版本 group id 对不上）
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *items = [fm contentsOfDirectoryAtPath:shared error:nil];
    for (NSString *it in items) {
        NSString *data = [shared stringByAppendingPathComponent:
                          [it stringByAppendingPathComponent:@"telegram-data"]];
        if ([fm fileExistsAtPath:data] && ![roots containsObject:data]) {
            [roots addObject:data];
        }
    }

    // 3) App 自己的沙盒目录
    NSArray *libs  = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSArray *docs  = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    for (NSArray *a in @[libs, caches, docs]) {
        NSString *p = a.firstObject;
        if (p.length && ![roots containsObject:p]) [roots addObject:p];
    }

    return roots;
}

#pragma mark - 扫描

/// 找出 maxAge 秒内被修改过、体积够大、且文件头确实是视频的本地文件
/// 结果按修改时间倒序（最新的在最前）
NSArray<NSString *> *TGSAScanRecentVideos(NSTimeInterval maxAge, NSUInteger limit) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    NSMutableArray *hits = [NSMutableArray array];
    NSArray *skipDirs = @[@"Caches/com.apple", @"WebKit", @"Snapshots", @"SystemData",
                          @"Preferences", @"SplashBoard", @".com.apple", @"HTTPStorages"];

    __block NSUInteger visited = 0;
    const NSUInteger kMaxVisited = 6000;   // 防止在巨型目录里卡死主线程

    for (NSString *root in TGSACandidateRoots()) {
        if (visited > kMaxVisited) break;

        NSDirectoryEnumerator *enu = [fm enumeratorAtPath:root];
        if (!enu) continue;
        const NSUInteger kMaxDepth = 6;         // 限制深度，够覆盖 postbox/media/xx/yy

        for (NSString *rel in enu) {
            if (visited++ > kMaxVisited) break;
            if (rel.length == 0) continue;

            // NSDirectoryEnumerator.level 是只读的，这里自己数路径分隔符控制深度
            NSUInteger depth = [[rel componentsSeparatedByString:@"/"] count];
            if (depth > kMaxDepth) { [enu skipDescendants]; continue; }

            BOOL isDir = NO;
            NSString *full = [root stringByAppendingPathComponent:rel];
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

            // 跳过明显无关的目录
            BOOL skip = NO;
            for (NSString *s in skipDirs) {
                if ([rel containsString:s]) { skip = YES; break; }
            }
            if (skip) continue;

            NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
            if (!attr) continue;

            unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
            if (size < 100 * 1024) continue;                 // 小于 100KB 基本不是视频

            NSDate *mtime = attr[NSFileModificationDate];
            NSTimeInterval age = now - (mtime ? mtime.timeIntervalSince1970 : 0);
            if (age < 0) age = -age;
            if (age > maxAge) continue;

            NSString *ext = TGSAExtensionForVideoFile(full);
            if (!ext) continue;

            [hits addObject:@{ @"path": full, @"mtime": @(mtime.timeIntervalSince1970),
                               @"size": @(size), @"ext": ext }];
        }
    }

    [hits sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"mtime"] compare:a[@"mtime"]];
    }];

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *h in hits) {
        [out addObject:h[@"path"]];
        if (out.count >= limit) break;
    }
    return out;
}
