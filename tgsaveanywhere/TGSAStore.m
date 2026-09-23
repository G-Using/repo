//  TGSaveAnywhere — 源收集 / 下载 / 存相册 / 导出到文件
//  Photos 必须在这个纯 ObjC 的 .m 里引入，不能放进公共头文件（见 TGSAHeaders.h 注释）

#import "TGSAHeaders.h"
#import <Photos/Photos.h>

#pragma mark - 临时文件

NSString *TGSATempPathForExtension(NSString *ext) {
    if (!ext || ext.length == 0 || ext.length > 5) ext = @"mp4";
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGSaveAnywhere"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    NSString *name = [NSString stringWithFormat:@"TG_%lld.%@",
                      (long long)([[NSDate date] timeIntervalSince1970] * 1000.0), ext];
    return [dir stringByAppendingPathComponent:name];
}

static NSString *TGSAGuessExtension(NSURL *url) {
    NSString *s = url.absoluteString.lowercaseString;
    NSArray *exts = @[@"mp4", @"mov", @"m4v", @"webm", @"mkv", @"avi", @"gif", @"ts"];
    for (NSString *e in exts) {
        if ([s hasSuffix:[@"." stringByAppendingString:e]]) return e;
    }
    NSString *pe = url.path.pathExtension;
    if (pe.length > 0 && pe.length <= 5) return pe;
    return @"mp4";
}

#pragma mark - 源报告

static NSURL *lastURL = nil;
static NSTimeInterval lastTS = 0;

/// 判断一个 URL 是否可能是视频源。
/// 远程：Telegram CDN 直链（通常带 .mp4/.mov 或 /file/ 路径）；
/// 本地：Telegram 的媒体缓存文件——注意缓存文件通常**没有扩展名**，
///       所以这里用「存在且体积够大 + 排除数据库类文件」来判断。
static BOOL TGSAIsCandidateMedia(NSURL *url) {
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    if (s.length == 0) return NO;

    if ([s hasPrefix:@"assets-library"] || [s hasPrefix:@"ipod-library"] || [s hasPrefix:@"ph://"]) return NO;

    if (url.isFileURL) {
        NSString *p = url.path;
        NSArray *blacklist = @[@".db", @".sqlite", @".sqlitedb", @"-wal", @"-shm", @".plist", @".json", @".log", @".dat", @".bin"];
        for (NSString *b in blacklist) {
            if ([p.lowercaseString hasSuffix:b]) return NO;
        }
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
        return size > 20000; // 小于 20KB 的基本不是视频
    }

    NSArray *exts = @[@".mp4", @".mov", @".m4v", @".webm", @".mkv", @".avi", @".gif", @".ts"];
    for (NSString *e in exts) {
        if ([s containsString:e]) return YES;
    }
    BOOL isCdn = [s containsString:@"/file/"] || [url.host.lowercaseString containsString:@"telegram"];
    return isCdn;
}

void TGSAReportMediaURL(NSURL *url, NSString *source) {
    if (!TGSAEnabled()) return;
    if (!url) return;

    // 探测模式下无条件记录，方便排查自定义 scheme（如 Telegram 自建 resourceLoader 的情况）
    if (TGSADiscoveryMode()) {
        TGSALog(@"AV 源 [%@] scheme=%@ %@", source, url.scheme, url.absoluteString);
    }

    if (!TGSAIsCandidateMedia(url)) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ([lastURL.absoluteString isEqualToString:url.absoluteString] && (now - lastTS) < 3.0) {
        return; // 同一个源 3 秒内去重（AVFoundation 常重复初始化）
    }
    lastURL = url;
    lastTS = now;

    if (TGSADiscoveryMode()) {
        TGSALog(@"捕获源 [%@] %@", source, url.absoluteString);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (TGSAShowOverlay()) {
            [[TGSAOverlay shared] showForURL:url];
        }
    });
}

#pragma mark - 下载

void TGSAFetchRemoteURL(NSURL *url, UIViewController *presenter, void (^completion)(NSString *filePath, NSError *error)) {
    UIAlertController *wait = nil;
    if (presenter) {
        wait = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                   message:@"0%"
                                            preferredStyle:UIAlertControllerStyleAlert];
        [presenter presentViewController:wait animated:YES completion:nil];
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForResource = 300;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    forHTTPHeaderField:@"User-Agent"];
    req.HTTPMethod = @"GET";

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:req
                                                   completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:nil];
            if (err || !loc) {
                TGSALog(@"下载失败：%@", err.localizedDescription);
                completion(nil, err);
                return;
            }
            NSString *dst = TGSATempPathForExtension(TGSAGuessExtension(url));
            NSError *moveErr = nil;
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            [[NSFileManager defaultManager] moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dst] error:&moveErr];
            if (moveErr) {
                TGSALog(@"移动文件失败：%@", moveErr.localizedDescription);
                completion(nil, moveErr);
                return;
            }
            unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:dst error:nil][NSFileSize] unsignedLongLongValue];
            TGSALog(@"下载完成：%@（%.1f MB）", dst.lastPathComponent, size / 1024.0 / 1024.0);
            completion(dst, nil);
        });
    }];
    [task resume];
}

#pragma mark - 存到相册

void TGSASaveVideoAtPathToAlbum(NSString *path) {
    TGSASaveVideoAtPathToAlbumWithCompletion(path, nil);
}

void TGSASaveVideoAtPathToAlbumWithCompletion(NSString *path, void (^completion)(BOOL ok, NSString *detail)) {
    void (^done)(BOOL, NSString *) = ^(BOOL ok, NSString *detail) {
        TGSALog(@"存相册%@ %@", ok ? @"成功" : @"失败", detail ?: @"");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, detail); });
        }
    };

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        done(NO, @"文件不存在");
        return;
    }

    // 没有相册权限描述键时直接写相册会崩溃，这里降级为导出到文件
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    if (!info[@"NSPhotoLibraryAddUsageDescription"] && !info[@"NSPhotoLibraryUsageDescription"]) {
        TGSALog(@"Info.plist 缺少相册权限描述，降级为「存储到文件」");
        TGSAExportFileAtPathWithCompletion(path, completion);
        return;
    }

    // 统一走 PHAsset：无论什么路径都有明确的 success/error 回调
    void (^doSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
        } completionHandler:^(BOOL success, NSError *error) {
            if (success) done(YES, nil);
            else done(NO, error.localizedDescription ?: @"未知错误");
        }];
    };

    if ([PHPhotoLibrary respondsToSelector:@selector(requestAuthorizationForAccessLevel:handler:)]) {
        if (@available(iOS 14.0, *)) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                        doSave();
                    } else {
                        done(NO, @"相册权限未授权");
                    }
                });
            }];
            return;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
#pragma clang diagnostic pop
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == PHAuthorizationStatusAuthorized) doSave();
            else done(NO, @"相册权限未授权");
        });
    }];
}

#pragma mark - 导出到「文件」App

void TGSAExportFileAtPath(NSString *path) {
    TGSAExportFileAtPathWithCompletion(path, nil);
}

void TGSAExportFileAtPathWithCompletion(NSString *path, void (^completion)(BOOL ok, NSString *detail)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            TGSALog(@"导出失败，文件不存在：%@", path);
            if (completion) completion(NO, @"文件不存在");
            return;
        }
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                        inMode:UIDocumentPickerModeExportToService];
        [TGSAPickerProxy shared].completion = completion;
        picker.delegate = [TGSAPickerProxy shared];
        UIViewController *top = TGSATopViewController();
        if (!top) {
            TGSALog(@"找不到用于展示的 ViewController");
            if (completion) completion(NO, @"找不到可展示的界面");
            return;
        }
        [top presentViewController:picker animated:YES completion:nil];
    });
}
