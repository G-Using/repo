//  TGSaveAnywhere — 限制绕过 + 符号探测
//
//  说明：
//  1) 主路径（AV 层抓源）不需要任何 Telegram 内部符号，天然可下载「禁止保存」内容，
//     因为这类内容只是 UI 屏蔽了保存入口，视频仍必须解密播放。
//  2) 本模块是补充手段：
//     - DiscoveryMode = YES 时，扫描 Telegram 里所有疑似「保存限制」相关的 ObjC 方法并写日志，
//       把日志发给我，我就能给出精确的一行 hook 配置。
//     - config.plist 里的 ForceTrueHooks 可以手动指定 "类名:selector"，强制返回 YES。

#import "TGSAHeaders.h"

#pragma mark - 探测

static void TGSADumpCandidates(void) {
    NSMutableString *out = [NSMutableString string];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);

    NSArray *classKeys = @[@"message", @"media", @"chat", @"peer", @"gallery", @"viewer", @"content", @"telegram"];
    NSArray *selKeys = @[@"save", @"saving", @"restrict", @"protect", @"forward", @"download", @"export",
                         @"nosave", @"nosav", @"copy", @"content", @"cantsave", @"cannotsave", @"lock"];

    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;

        const char *rawName = class_getName(c);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        NSString *lower = name.lowercaseString;

        BOOL nameMatch = NO;
        for (NSString *k in classKeys) {
            if ([lower containsString:k]) { nameMatch = YES; break; }
        }
        if (!nameMatch) continue;

        @autoreleasepool {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(c, &mcount);
            for (unsigned int j = 0; j < mcount; j++) {
                Method m = methods[j];
                if (!m) continue;
                SEL s = method_getName(m);
                const char *sn = sel_getName(s);
                if (!sn) continue;
                NSString *selName = [[NSString stringWithUTF8String:sn] lowercaseString];
                for (NSString *k in selKeys) {
                    if ([selName containsString:k]) {
                        const char *rt = method_getReturnType(m) ?: "?";
                        [out appendFormat:@"%@\t-[%@ %@]\tret=%s\n", name, name, selName, rt];
                        break;
                    }
                }
            }
            free(methods);
        }
        if (out.length > 350000) break;
    }
    free(classes);

    TGSALog(@"=== 符号探测开始（%u 个类）===", count);
    if (out.length == 0) {
        TGSALog(@"未命中任何候选方法，可尝试放宽 classKeys/selKeys 后重编译");
    } else {
        TGSALog(@"候选方法：\n%@", out);
    }
    TGSALog(@"=== 符号探测结束 ===");
}

#pragma mark - 强制返回 YES 的 hook

static void TGSAApplyForcedHooks(void) {
    NSArray *hooks = TGSASetting(@"ForceTrueHooks", @[]);
    if (![hooks isKindOfClass:NSArray.class] || hooks.count == 0) return;

    for (NSString *spec in hooks) {
        if (![spec isKindOfClass:NSString.class]) continue;
        NSArray *parts = [spec componentsSeparatedByString:@"::"];
        if (parts.count != 2) {
            TGSALog(@"配置格式错误（应为 类名::selector）：%@", spec);
            continue;
        }
        Class cls = NSClassFromString(parts[0]);
        SEL sel = NSSelectorFromString(parts[1]);
        if (!cls || !sel) {
            TGSALog(@"找不到类或选择器：%@", spec);
            continue;
        }
        // 只处理返回值安全的方法：void / BOOL / char / bool
        // 返回对象的不能强塞 YES，否则会得到一个野指针
        IMP imp = imp_implementationWithBlock(^BOOL(id _self, SEL _cmd) {
            return YES;
        });
        BOOL ok = TGSASwizzleInstance(cls, sel, imp, NULL);
        TGSALog(@"ForceTrue %@ -> %@", spec, ok ? @"成功" : @"跳过（方法不存在或返回值类型不安全）");
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void TGSARestrictInit(void) {
    // 等 Telegram 完成初始化、Swift 类都注册好之后再动手
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        TGSAApplyForcedHooks();
        if (TGSADiscoveryMode()) {
            TGSADumpCandidates();
        }
    });
}
