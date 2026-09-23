//  TGSaveAnywhere — 公共头文件
//  所有模块共享的声明

#ifndef TGSA_HEADERS_H
#define TGSA_HEADERS_H

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
// 注意：不要把 <Photos/Photos.h> 放到这个公共头文件里。
// .xm 是按 Objective-C++ 编译的，而 Xcode 15 的 clang 默认仍是 gnu++98，
// Photos 框架要求 C++11，在 .mm 里 include 会直接报 "Photos requires C++11 or later"。
// 所以 Photos 只在需要的 .m（纯 ObjC 编译）里 import，见 TGSAStore.m。
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

NS_ASSUME_NONNULL_BEGIN

// 这些 C 函数定义在 .m（ObjC）里，但会被 .xm 预处理成的 .mm（ObjC++）调用。
// 不加 extern "C" 的话 C++ 会做名字改编（mangling），链接期报 symbol(s) not found。
#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - 配置

/// 读取配置项，缺省值由 defaultValue 提供
id TGSASetting(NSString *key, id defaultValue);
BOOL TGSAEnabled(void);          // 总开关，默认 YES
BOOL TGSAShowOverlay(void);      // 悬浮下载按钮，默认 YES
BOOL TGSADiscoveryMode(void);    // 符号探测模式（写详细日志），默认 NO
BOOL TGSAAlwaysShowButton(void); // 悬浮按钮常驻（不依赖是否抓到 AV 源），默认 YES
/// 缓存扫描的时间窗口（秒），默认 900（15 分钟内被修改过的文件）
NSTimeInterval TGSAScanWindow(void);

#pragma mark - 日志

void TGSALog(NSString *fmt, ...);
NSString *TGSALogPath(void);
NSString *TGSADocDir(void);

#pragma mark - Runtime 工具

/// 只 hook 已经存在、且返回值安全（void / BOOL / char）的实例方法
BOOL TGSASwizzleInstance(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);
BOOL TGSASwizzleClass(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);

/// 同上，但不检查返回值类型（调用方必须自己保证替换实现的签名与原方法一致）
BOOL TGSASwizzleInstanceRaw(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);
BOOL TGSASwizzleClassRaw(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);

/// 取方法返回值类型编码。新版 SDK 的 method_getReturnType 是三参数且返回 void，
/// 旧版是一参数返回 const char *，这里统一封装，避免版本差异。
void TGSACopyReturnType(Method _Nullable m, char *dst, size_t dstLen);
/// 返回值是否为可安全强塞 YES 的类型（void / BOOL / char / bool）
BOOL TGSAReturnTypeIsSafe(Method _Nullable m);

UIViewController *_Nullable TGSATopViewController(void);

#pragma mark - 媒体源捕获

/// 由 AV 层 hook 调用，报告一个可能是视频源的 URL
void TGSAReportMediaURL(NSURL *_Nullable url, NSString *source);

#pragma mark - 本地媒体缓存扫描

/// 扫描 Telegram 的媒体缓存目录，返回 maxAge 秒内被修改过的视频文件（按时间倒序）
/// 这条路是主力：Telegram 自己软解播放，不走 AVFoundation，但缓存文件一定落盘
NSArray<NSString *> *TGSAScanRecentVideos(NSTimeInterval maxAge, NSUInteger limit);
/// 用文件头魔数判断类型，返回扩展名；不是视频返回 nil
NSString *_Nullable TGSAExtensionForVideoFile(NSString *path);

#pragma mark - 保存 / 导出

NSString *TGSATempPathForExtension(NSString *_Nullable ext);
void TGSAFetchRemoteURL(NSURL *url, UIViewController *_Nullable presenter, void (^completion)(NSString *_Nullable filePath, NSError *_Nullable error));
void TGSASaveVideoAtPathToAlbum(NSString *path);
void TGSAExportFileAtPath(NSString *path);

#ifdef __cplusplus
}
#endif

#pragma mark - 悬浮层

@interface TGSAOverlay : NSObject
@property (nonatomic, strong, nullable) NSURL *currentURL;
+ (instancetype)shared;
- (void)showForURL:(NSURL *)url;
/// url 可以为 nil —— 此时按钮点开后会去扫描本地缓存文件列表
- (void)showWithURL:(NSURL *_Nullable)url;
- (void)hide;
@end

@interface TGSAPickerProxy : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
@end

NS_ASSUME_NONNULL_END

#endif /* TGSA_HEADERS_H */
