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

#pragma mark - MP4 结构 / 时长 / 已缓冲检测

static uint32_t TGSABE32(const unsigned char *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

static uint64_t TGSABE64(const unsigned char *b) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | b[i];
    return v;
}

#define TGSA_FCC(a, b, c, d) ((uint32_t)(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d)))

/// 顶层 box 遍历游标
typedef struct {
    const unsigned char *p;
    NSUInteger len;
    NSUInteger off;
} TGSABoxCursor;

static BOOL TGSANextBox(TGSABoxCursor *c, uint32_t *outType, NSUInteger *outBodyOff, uint64_t *outBodyLen) {
    if (!c->p || c->off + 8 > c->len) return NO;
    const unsigned char *b = c->p + c->off;
    uint64_t size = TGSABE32(b);
    uint32_t type = TGSABE32(b + 4);
    NSUInteger headerLen = 8;
    if (size == 1) {                       // 64 位 largesize
        if (c->off + 16 > c->len) return NO;
        size = TGSABE64(b + 8);
        headerLen = 16;
    } else if (size == 0) {                // 延伸到数据末尾
        size = c->len - c->off;
    }
    if (size < headerLen || c->off + size > c->len) return NO;
    *outType = type;
    *outBodyOff = c->off + headerLen;
    *outBodyLen = size - headerLen;
    c->off += (NSUInteger)size;
    return YES;
}

/// 一条轨道的采样表（stbl 的 stts / stsz / stsc / stco 四件套）
typedef struct {
    uint32_t sampleCount;
    uint64_t uniformSize;        // stsz 的 sample_size 字段；非 0 表示所有采样等大
    uint64_t *sizes;             // 每采样大小（uniformSize == 0 时有效）
    uint32_t *sttsCounts;        // stts entry：连续 N 个采样
    uint32_t *sttsDeltas;        // stts entry：每个采样时长（timescale 单位）
    uint32_t sttsEntries;
    uint64_t *chunkOffsets;      // stco / co64
    uint32_t chunkCount;
    uint32_t *stscFirst;         // stsc：起始 chunk（1-based）
    uint32_t *stscPerChunk;      // stsc：每个 chunk 含多少采样
    uint32_t stscCount;
    BOOL valid;
} TGSASampleTable;

static void TGSATableFree(TGSASampleTable *t) {
    if (!t) return;
    free(t->sizes);
    free(t->chunkOffsets);
    free(t->stscFirst);
    free(t->stscPerChunk);
    free(t->sttsCounts);
    free(t->sttsDeltas);
    memset(t, 0, sizeof(*t));
}

/// 解析 stbl 的四个关键子 box；缺一或字段非法则置 valid=NO
static void TGSAParseStbl(NSData *stblBody, TGSASampleTable *t) {
    memset(t, 0, sizeof(*t));
    if (!stblBody.length) return;

    NSData *stts = nil, *stsz = nil, *stsc = nil, *stco = nil;
    BOOL isCo64 = NO;
    TGSABoxCursor c = { stblBody.bytes, stblBody.length, 0 };
    uint32_t type; NSUInteger bodyOff; uint64_t bodyLen;
    while (TGSANextBox(&c, &type, &bodyOff, &bodyLen)) {
        NSData *slice = [stblBody subdataWithRange:NSMakeRange(bodyOff, (NSUInteger)bodyLen)];
        if (type == TGSA_FCC('s','t','t','s')) stts = slice;
        else if (type == TGSA_FCC('s','t','s','z')) stsz = slice;
        else if (type == TGSA_FCC('s','t','s','c')) stsc = slice;
        else if (type == TGSA_FCC('s','t','c','o')) { stco = slice; isCo64 = NO; }
        else if (type == TGSA_FCC('c','o','6','4')) { stco = slice; isCo64 = YES; }
    }
    if (!stts.length || !stsz.length || !stsc.length || !stco.length) return;

    // stts：时长表
    const unsigned char *p = stts.bytes;
    if (stts.length < 8) return;
    uint32_t entries = TGSABE32(p + 4);
    if (entries == 0 || entries > 65536 || 8 + (NSUInteger)entries * 8 > stts.length) return;
    t->sttsCounts = malloc(entries * sizeof(uint32_t));
    t->sttsDeltas = malloc(entries * sizeof(uint32_t));
    if (!t->sttsCounts || !t->sttsDeltas) { TGSATableFree(t); return; }
    for (uint32_t i = 0; i < entries; i++) {
        t->sttsCounts[i] = TGSABE32(p + 8 + i * 8);
        t->sttsDeltas[i] = TGSABE32(p + 8 + i * 8 + 4);
    }
    t->sttsEntries = entries;

    // stsz：采样大小表
    p = stsz.bytes;
    if (stsz.length < 12) { TGSATableFree(t); return; }
    uint32_t uniform = TGSABE32(p + 4);
    uint32_t count = TGSABE32(p + 8);
    if (count == 0 || count > 8000000) { TGSATableFree(t); return; }   // 防御性上限
    t->sampleCount = count;
    t->uniformSize = uniform;
    if (!uniform) {
        if (stsz.length < 12 + (NSUInteger)count * 4) { TGSATableFree(t); return; }
        t->sizes = malloc((size_t)count * sizeof(uint64_t));
        if (!t->sizes) { TGSATableFree(t); return; }
        for (uint32_t i = 0; i < count; i++) t->sizes[i] = TGSABE32(p + 12 + i * 4);
    }

    // stsc：采样 → chunk 映射
    p = stsc.bytes;
    if (stsc.length < 8) { TGSATableFree(t); return; }
    uint32_t sc = TGSABE32(p + 4);
    if (sc == 0 || sc > 100000 || 8 + (NSUInteger)sc * 12 > stsc.length) { TGSATableFree(t); return; }
    t->stscFirst = malloc(sc * sizeof(uint32_t));
    t->stscPerChunk = malloc(sc * sizeof(uint32_t));
    if (!t->stscFirst || !t->stscPerChunk) { TGSATableFree(t); return; }
    for (uint32_t i = 0; i < sc; i++) {
        t->stscFirst[i] = TGSABE32(p + 8 + i * 12);
        t->stscPerChunk[i] = TGSABE32(p + 8 + i * 12 + 4);
    }
    t->stscCount = sc;

    // stco / co64：chunk 在文件里的绝对偏移
    p = stco.bytes;
    if (stco.length < 8) { TGSATableFree(t); return; }
    uint32_t cc = TGSABE32(p + 4);
    NSUInteger stride = isCo64 ? 8 : 4;
    if (cc == 0 || cc > 2000000 || 8 + (NSUInteger)cc * stride > stco.length) { TGSATableFree(t); return; }
    t->chunkOffsets = malloc((size_t)cc * sizeof(uint64_t));
    if (!t->chunkOffsets) { TGSATableFree(t); return; }
    for (uint32_t i = 0; i < cc; i++) {
        t->chunkOffsets[i] = isCo64 ? TGSABE64(p + 8 + (NSUInteger)i * 8)
                                    : TGSABE32(p + 8 + i * 4);
    }
    t->chunkCount = cc;

    t->valid = YES;
}

/// 按采样表算「连续可播的已缓冲时长」：
/// chunk 顺序推进采样，逐个核对采样数据的 [offset, offset+size) 是否都在文件大小内，
/// 遇到第一个没下载完整的采样就停 —— 它就是系统播放器会卡住的位置。
/// outTotal 带回该轨总时长（秒）。
static double TGSATableBufferedSeconds(const TGSASampleTable *t, unsigned long long fsize,
                                       double timescale, double *outTotal) {
    if (outTotal) *outTotal = -1;
    if (!t || !t->valid || timescale <= 0) return -1;

    // 1) 总时长：stts 各 entry 的 count × delta 累加（不超过采样总数）
    double totalUnits = 0;
    uint32_t counted = 0;
    for (uint32_t e = 0; e < t->sttsEntries && counted < t->sampleCount; e++) {
        uint32_t n = t->sttsCounts[e];
        if (n > t->sampleCount - counted) n = t->sampleCount - counted;
        totalUnits += (double)n * t->sttsDeltas[e];
        counted += n;
    }
    if (totalUnits <= 0) return -1;
    if (outTotal) *outTotal = totalUnits / timescale;

    // 2) 已缓冲：从头开始数连续完整的采样
    double bufferedUnits = 0;
    uint32_t sampleIdx = 0, stscIdx = 0, entry = 0, leftInEntry = 0, curDelta = 0;
    for (uint32_t ch = 0; ch < t->chunkCount; ch++) {
        while (stscIdx + 1 < t->stscCount && t->stscFirst[stscIdx + 1] <= ch + 1) stscIdx++;
        if (stscIdx >= t->stscCount) break;
        uint32_t per = t->stscPerChunk[stscIdx];
        if (per == 0) continue;
        uint64_t off = t->chunkOffsets[ch];
        for (uint32_t s = 0; s < per && sampleIdx < t->sampleCount; s++) {
            while (leftInEntry == 0) {
                if (entry >= t->sttsEntries) { sampleIdx = t->sampleCount; break; }
                leftInEntry = t->sttsCounts[entry];
                curDelta = t->sttsDeltas[entry];
                entry++;
            }
            if (sampleIdx >= t->sampleCount) break;
            uint64_t sz = t->uniformSize ? t->uniformSize : t->sizes[sampleIdx];
            if (off + sz > fsize) return bufferedUnits / timescale;   // ← 第一个缺数据的位置
            bufferedUnits += curDelta;
            off += sz;
            sampleIdx++;
            leftInEntry--;
        }
    }
    return bufferedUnits / timescale;
}

/// 解析一条 trak：mdhd 拿 timescale，minf/stbl 拿采样表，算出该轨已缓冲时长。
/// minBuffered / maxTotal 跨轨取最短（音频/视频哪条先缺数据，播放就在哪卡住）。
static void TGSAParseTrak(NSData *trakBody, unsigned long long fsize, double defaultTimescale,
                          double *minBuffered, double *maxTotal) {
    if (!trakBody.length) return;
    double timescale = defaultTimescale;
    NSData *minfBody = nil;

    TGSABoxCursor c = { trakBody.bytes, trakBody.length, 0 };
    uint32_t type; NSUInteger bodyOff; uint64_t bodyLen;
    while (TGSANextBox(&c, &type, &bodyOff, &bodyLen)) {
        if (type != TGSA_FCC('m','d','i','a')) continue;
        NSData *mdia = [trakBody subdataWithRange:NSMakeRange(bodyOff, (NSUInteger)bodyLen)];
        TGSABoxCursor c2 = { mdia.bytes, mdia.length, 0 };
        uint32_t t2; NSUInteger b2; uint64_t l2;
        while (TGSANextBox(&c2, &t2, &b2, &l2)) {
            NSData *s2 = [mdia subdataWithRange:NSMakeRange(b2, (NSUInteger)l2)];
            if (t2 == TGSA_FCC('m','d','h','d')) {
                const unsigned char *m = s2.bytes;
                if (s2.length >= 16 && m[0] == 0) {
                    uint32_t ts = TGSABE32(m + 12);        // v0：ver/flags(4)+creation(4)+mod(4)
                    if (ts) timescale = ts;
                } else if (s2.length >= 24 && m[0] == 1) {
                    uint32_t ts = TGSABE32(m + 20);        // v1：creation/mod 各 8 字节
                    if (ts) timescale = ts;
                }
            } else if (t2 == TGSA_FCC('m','i','n','f')) {
                minfBody = s2;
            }
        }
    }
    if (!minfBody.length || timescale <= 0) return;

    TGSABoxCursor c3 = { minfBody.bytes, minfBody.length, 0 };
    while (TGSANextBox(&c3, &type, &bodyOff, &bodyLen)) {
        if (type != TGSA_FCC('s','t','b','l')) continue;
        NSData *stbl = [minfBody subdataWithRange:NSMakeRange(bodyOff, (NSUInteger)bodyLen)];
        TGSASampleTable table;
        TGSAParseStbl(stbl, &table);
        double total = -1;
        double buffered = TGSATableBufferedSeconds(&table, fsize, timescale, &total);
        TGSATableFree(&table);
        if (total > 0 && total > *maxTotal) *maxTotal = total;
        if (buffered >= 0 && (*minBuffered < 0 || buffered < *minBuffered)) *minBuffered = buffered;
    }
}

BOOL TGSAMp4InspectEx(NSString *path, NSTimeInterval *_Nullable outTotalDuration,
                      NSTimeInterval *_Nullable outBufferedDuration) {
    if (outTotalDuration) *outTotalDuration = -1;
    if (outBufferedDuration) *outBufferedDuration = -1;
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

        double mvhdTs = 0, mvhdTotal = -1;
        double minBuffered = -1, maxTrackTotal = -1;
        BOOL hasMoof = NO;   // fMP4（分片）不适用这套连续性推算

        unsigned long long off = 0;
        BOOL overran = NO;
        while (off + 8 <= fsize) {
            [fh seekToFileOffset:off];
            NSData *hdr = [fh readDataOfLength:16];
            const unsigned char *b = hdr.bytes;
            if (hdr.length < 8) { overran = YES; break; }
            uint64_t boxSize = TGSABE32(b);
            uint32_t boxType = TGSABE32(b + 4);
            unsigned long long headerLen = 8;
            if (boxSize == 1) {
                if (hdr.length < 16) { overran = YES; break; }
                boxSize = TGSABE64(b + 8);
                headerLen = 16;
            } else if (boxSize == 0) {
                boxSize = fsize - off;
            }
            if (boxSize < headerLen || off + boxSize > fsize) { overran = YES; break; }   // box 越界 → 结构不完整

            if (boxType == TGSA_FCC('m','o','o','v') && boxSize - headerLen <= 64ULL * 1024 * 1024) {
                [fh seekToFileOffset:off + (NSUInteger)headerLen];
                NSData *moov = [fh readDataOfLength:(NSUInteger)(boxSize - headerLen)];
                TGSABoxCursor c = { moov.bytes, moov.length, 0 };
                uint32_t t; NSUInteger bo; uint64_t bl;
                while (TGSANextBox(&c, &t, &bo, &bl)) {
                    NSData *slice = [moov subdataWithRange:NSMakeRange(bo, (NSUInteger)bl)];
                    if (t == TGSA_FCC('m','v','h','d')) {
                        const unsigned char *m = slice.bytes;
                        if (slice.length >= 20 && m[0] == 0) {
                            uint32_t ts = TGSABE32(m + 12);
                            uint32_t du = TGSABE32(m + 16);
                            if (ts && du && du != 0xFFFFFFFF) mvhdTotal = (NSTimeInterval)du / ts;
                            if (ts) mvhdTs = ts;
                        } else if (slice.length >= 32 && m[0] == 1) {
                            uint32_t ts = TGSABE32(m + 20);
                            uint64_t du = TGSABE64(m + 24);
                            if (ts && du && du != 0xFFFFFFFFFFFFFFFFULL) mvhdTotal = (NSTimeInterval)du / ts;
                            if (ts) mvhdTs = ts;
                        }
                    } else if (t == TGSA_FCC('t','r','a','k')) {
                        TGSAParseTrak(slice, fsize, mvhdTs, &minBuffered, &maxTrackTotal);
                    }
                }
            } else if (boxType == TGSA_FCC('m','o','o','f')) {
                hasMoof = YES;
            }
            off += boxSize;
        }

        if (outTotalDuration) *outTotalDuration = (mvhdTotal > 0) ? mvhdTotal : maxTrackTotal;
        if (outBufferedDuration) *outBufferedDuration = hasMoof ? -1 : minBuffered;
        return (!overran && off == fsize);   // box 链恰好铺满整个文件才算结构完整
    } @catch (NSException *e) {
        TGSALog(@"mp4 检测异常：%@", e.reason);
        return NO;
    } @finally {
        [fh closeFile];
    }
}

BOOL TGSAMp4Inspect(NSString *path, NSTimeInterval *_Nullable outDuration) {
    return TGSAMp4InspectEx(path, outDuration, NULL);
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
