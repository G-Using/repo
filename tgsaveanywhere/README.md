# TGSaveAnywhere

注入 Telegram（iOS）的 tweak：频道里**正在播放的视频**可以直接存到**相册**或**文件 App**，「禁止保存内容 / 私密频道」的内容同样可用。

支持两种注入方式：

- **越狱注入**（Substrate / TweakInject，Dopamine、palera1n、roothide 等）
- **巨魔注入器（TrollFools）注入** —— 不需要越狱也能用，直接把 dylib 插进 Telegram 的 IPA

---

## 一、原理

**1. Telegram 自己软解视频，不走 AVFoundation。**
telegram-iOS 的播放器是自带的 ffmpeg 软解 + 自绘图层，绝大多数视频**根本不会创建 `AVPlayerItem`**。所以只 hook AV 层是抓不到源的 —— 这也是第一版按钮不出来的根本原因。

**2. 但视频文件一定会在本地留下缓存。**
无论什么解码方式，媒体都会落盘到 Telegram 的 `telegram-data/postbox/media`（在 App Group 容器里）。而且**普通频道的缓存就是明文 mp4**——「禁止保存内容」只是 UI 层禁掉了保存/转发入口，媒体文件本身并没有加密。

所以主力方案是：**扫出"刚刚被读写的那个视频文件"**。缓存文件通常没有扩展名，因此用**文件头魔数**（`ftyp` / `\x1A\x45\xDF\xA3` / `RIFF` …）判断类型，不看后缀。

**3. AV 层 hook 保留作为补充。**
有些场景（例如 Telegram 走系统播放器、或受限内容走 FairPlay）仍然会经过 `AVURLAsset` / `AVPlayer`，这时能直接拿到 CDN 直链或本地路径。这部分依然有效，两者互补。

**4. 不 hook 任何 Telegram 的 Swift 类。**
telegram-iOS 符号带 mangling、每个版本都在变，硬 hook 一升级就废。本 tweak 只依赖 Apple 的公开 API 和文件系统，与 Telegram 版本基本解耦。

**5. 不依赖 CydiaSubstrate。**
所有 hook 都是 Objective-C runtime 直接替换（`class_replaceMethod`），**没有 `%hook`，也不链接 `libsubstrate.dylib`**。这一点对巨魔注入至关重要：TrollFools 注入的 dylib 由 dyld 直接加载，不在 Substrate 注入链路里，依赖 libsubstrate 会导致加载失败或 hook 静默失效。

---

## 二、编译

需要 **macOS + Theos**（Windows 编不了 iOS 的 Mach-O）。

```bash
export THEOS=~/theos
cd tgsaveanywhere

# 越狱 rootful（checkra1n / unc0ver）
make clean package

# 越狱 rootless（Dopamine / palera1n / roothide，iOS 15+）
make clean package THEOS_PACKAGE_SCHEME=rootless

# 巨魔注入器（TrollFools）专用：只产出独立 dylib，不链接 Substrate
make clean all TROLLSTORE=1
```

产物：

- 越狱：`packages/com.gusing.tgsaveanywhere_<ver>_iphoneos-arm*.deb`
- 巨魔：`out/TGSaveAnywhere.dylib`（thin arm64，正好匹配 App Store 版 Telegram）

---

## 三、用法

### 3.1 越狱方式

`dpkg -i` 安装 deb，或丢进 Cydia 源。装完确保 Telegram 在注入列表里（roothide 需要在 roothide App 里手动给 Telegram 打开 tweak 注入开关）。

### 3.2 巨魔注入器（TrollFools）方式

1. 准备 Telegram 的 **解密 IPA**（App Store 版可直接用），装进 TrollStore。
2. 打开 TrollFools → 选 Telegram → 选 `TGSaveAnywhere.dylib` → 注入。
3. 它会生成一个注入后的 IPA，用 TrollStore 安装（会替换原来的 Telegram，数据不丢）。

> 注意 `TGSaveAnywhere.plist` 的 Bundle 过滤是 `ph.telegra.Telegraph`（App Store 官方版）。巨魔注入不需要这个 plist，它靠 IPA 里的二进制直接加载 dylib。

### 3.3 操作

1. 打开 Telegram，进频道**播放一个视频**（让它缓冲完整一点）。
2. 屏幕右侧出现半透明圆形 **↓** 按钮（可拖动，长按隐藏）。现在它是**常驻**的，App 启动 3 秒后就出现，不依赖是否抓到源。
3. 点它：
   - 如果抓到了 AV 源 → 直接弹「保存到相册 / 存储到文件… / 复制直链」
   - 否则 → 扫描本地缓存，列出最近修改过的视频（按时间倒序，**第一个通常就是刚播放的**），选中后再选「保存到相册」或「存储到文件…」
   - 列表里没有？点「全盘扫描（较慢）」扩大时间窗口到 24 小时

---

## 四、配置

首次运行会在 Telegram 的 Documents 生成模板：

```
/var/mobile/Containers/Data/Application/<TG-UUID>/Documents/TGSaveAnywhere/config.plist
```

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Enabled` | Bool | true | 总开关 |
| `ShowOverlay` | Bool | true | 是否显示悬浮 ↓ 按钮 |
| `AlwaysShowButton` | Bool | true | 按钮常驻显示（不依赖是否抓到 AV 源） |
| `ScanWindowSeconds` | Number | 900 | 缓存扫描时间窗口（秒），只认这段时间内被修改过的文件 |
| `DiscoveryMode` | Bool | false | 符号探测模式，见第六节 |
| `ForceTrueHooks` | Array | [] | 额外强制返回 YES 的 hook，格式 `"类名::selector"` |

---

## 五、排查

日志文件：

```
/var/mobile/Containers/Data/Application/<TG-UUID>/Documents/TGSaveAnywhere/tgsaveanywhere.log
```

启动时会打印这些信息，基本能一次定位问题：

- `TGSaveAnywhere 已注入` —— 没有这行说明 **dylib 根本没被加载**（注入失败）
- `AV 层 hook 安装完成：n/m` —— n 远小于 m 说明 AVFoundation 没加载上
- `AppGroup group.ph.telegra.Telegraph -> ...` —— 显示 telegram-data 在哪
- `本 dylib 加载自：...` —— 确认是 TweakInject 注入还是巨魔注入
- `[存在]/[缺失]` 列表 —— 判断越狱环境
- `缓存扫描（窗口 900s）命中 n 个` —— 扫描到几个候选文件

---

## 六、想更彻底地解锁原生保存按钮

如果还想让 Telegram 自己的保存/转发按钮也恢复可用：

1. `config.plist` 里 `DiscoveryMode` 设为 `true`
2. 重启 Telegram，逛一圈频道、多开几个视频
3. 把日志发我（附 **Telegram 版本号** 和 **iOS / 越狱方式**），我从中找出真正的限制判定方法，给你一行 `ForceTrueHooks` 配置：

```xml
<key>ForceTrueHooks</key>
<array>
    <string>Message::isContentProtected</string>
    <string>ChatController::canSaveMedia</string>
</array>
```

填进去重启即可，不用重编译。

> `ForceTrueHooks` 只接受返回 void / BOOL / char 的方法；返回对象指针的不 hook（会造野指针直接崩）。

---

## 七、文件说明

| 文件 | 作用 |
|---|---|
| `TGSAHeaders.h` | 公共声明（跨 ObjC/ObjC++ 的 C 函数都包在 `extern "C"` 里） |
| `TGSAUtil.m` | 日志、配置、runtime swizzle 工具、取顶层 VC |
| `TGSAMediaCapture.m` | 纯 runtime hook `AVAsset` / `AVURLAsset` / `AVPlayerItem` / `AVPlayer` / `AVPlayerLayer` 抓源 |
| `TGSACacheScan.m` | **主力**：扫 Telegram 媒体缓存目录，按文件头魔数找视频 |
| `TGSAStore.m` | 复制缓存 / 下载直链 / 存相册 / 导出到文件 |
| `TGSAOverlay.m` | 悬浮按钮 + 缓存文件列表 + 操作菜单 |
| `TGSARestriction.m` | 符号探测 + `ForceTrueHooks` 强制解锁 |
| `TGSAMain.m` | 注入入口（constructor）、环境诊断日志 |
| `Makefile` / `control` / `TGSaveAnywhere.plist` | 构建与过滤配置 |

---

## 八、已知限制

- 必须**先让视频缓冲完**再点保存，否则复制出来的可能是半个文件。
- 「加密频道」如果指 Secret Chat（端到端 + 阅后即焚），本 tweak 不解密任何内容，只处理已经落盘到你设备上的媒体。
- 相册保存依赖 `NSPhotoLibraryAddUsageDescription`；缺这个键时会自动降级为「存储到文件」而不是崩溃。
- 缓存扫描只认 100KB 以上、且在时间窗口内被修改过的文件；老视频用「全盘扫描」或直接改 `ScanWindowSeconds`。

---

## 九、声明

这是给你**自己设备上个人备份**用的工具。用它下载别人的付费/私密内容并二次分发，后果自负。
