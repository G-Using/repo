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

#pragma mark - 配置

/// 读取配置项，缺省值由 defaultValue 提供
id TGSASetting(NSString *key, id defaultValue);
BOOL TGSAEnabled(void);          // 总开关，默认 YES
BOOL TGSAShowOverlay(void);      // 悬浮下载按钮，默认 YES
BOOL TGSADiscoveryMode(void);    // 符号探测模式（写详细日志），默认 NO

#pragma mark - 日志

void TGSALog(NSString *fmt, ...);
NSString *TGSALogPath(void);
NSString *TGSADocDir(void);

#pragma mark - Runtime 工具

/// 只 hook 已经存在、且返回值安全（void / BOOL / char）的实例方法
BOOL TGSASwizzleInstance(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);
BOOL TGSASwizzleClass(Class cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable outOriginal);

/// 取方法返回值类型编码。新版 SDK 的 method_getReturnType 是三参数且返回 void，
/// 旧版是一参数返回 const char *，这里统一封装，避免版本差异。
void TGSACopyReturnType(Method _Nullable m, char *dst, size_t dstLen);
/// 返回值是否为可安全强塞 YES 的类型（void / BOOL / char / bool）
BOOL TGSAReturnTypeIsSafe(Method _Nullable m);

UIViewController *_Nullable TGSATopViewController(void);

#pragma mark - 媒体源捕获

/// 由 AV 层 hook 调用，报告一个可能是视频源的 URL
void TGSAReportMediaURL(NSURL *_Nullable url, NSString *source);

#pragma mark - 保存 / 导出

NSString *TGSATempPathForExtension(NSString *_Nullable ext);
void TGSAFetchRemoteURL(NSURL *url, UIViewController *_Nullable presenter, void (^completion)(NSString *_Nullable filePath, NSError *_Nullable error));
void TGSASaveVideoAtPathToAlbum(NSString *path);
void TGSAExportFileAtPath(NSString *path);

#pragma mark - 悬浮层

@interface TGSAOverlay : NSObject
@property (nonatomic, strong, nullable) NSURL *currentURL;
+ (instancetype)shared;
- (void)showForURL:(NSURL *)url;
- (void)hide;
@end

@interface TGSAPickerProxy : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
@end

NS_ASSUME_NONNULL_END

#endif /* TGSA_HEADERS_H */
