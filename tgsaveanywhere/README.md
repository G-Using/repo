# TGSaveAnywhere

注入 Telegram（iOS，需越狱）的 tweak，作用：频道里**正在播放的视频**可以直接存到**相册**或**文件 App**，二选一；「禁止保存内容 / 私密频道」的内容同样可用。

---

## 一、原理（为什么要这样写）

Telegram 的「禁止保存内容」本质上只是 **UI 层禁掉了保存/转发入口**，视频本身仍然必须解密并交给系统播放器渲染，否则用户根本看不到。所以：

1. **不 hook 任何 Telegram 的 Swift 类。** telegram-iOS 是纯 Swift 大工程，符号带 mangling、每个版本类名方法名都在变，硬 hook `ChatController` / `Message` 一升级就崩或失效。
2. **hook AVFoundation（Apple 的稳定 API）。** 任何版本的 Telegram 播视频都会创建 `AVURLAsset` / `AVPlayerItem`，我们在这里拿到真实媒体源：
   - 本地缓存 → `file://` 路径，直接复制；
   - 未缓存 → Telegram CDN 的 `https://` 直链（URL query 里已带鉴权参数），用 `NSURLSession` 直接下。
3. 拿到源之后弹菜单：**保存到相册** / **存储到文件…** / **复制直链**。

好处：和 Telegram 版本基本解耦，不需要维护一堆 Swift 头文件，也不会因为 TG 改 UI 就挂。

---

## 二、编译

需要 **macOS 或 Linux + Theos**（Windows 编不了 iOS 的 Mach-O，本项目源码已就绪，编译请放到你的打包机上）。

```bash
# 安装 Theos（一次性）
#   https://theos.dev/docs/installation-macos  或  installation-linux

export THEOS=~/theos
cd tgsaveanywhere

# rootful（checkra1n / unc0ver 等）
make clean package

# rootless（Dopamine / palera1n / Serotonin 等 iOS 15+）
make clean package THEOS_PACKAGE_SCHEME=rootless

# 带符号，方便看崩溃日志
make clean package DEBUG=1
```

产物：`packages/com.gusing.tgsaveanywhere_0.1.0_iphoneos-arm.deb`

安装到设备：`scp` 上去后 `dpkg -i`，或直接丢进你的 Cydia 源。

> 注意 `TGSaveAnywhere.plist` 里的 Bundle 过滤是 `ph.telegra.Telegraph`（App Store 官方版）。如果你用的是其他包名的 Telegram 分支，改这里。

---

## 三、用法

1. 打开 Telegram，进任意频道，**播放一个视频**（点开让它开始播）。
2. 屏幕右侧会出现一个半透明圆形 **↓** 按钮（可拖动位置，长按隐藏，25 秒无操作自动隐藏）。
3. 点它，弹出菜单：
   - **保存到相册 / 下载到相册** — 存进系统相册
   - **存储到文件… / 下载到文件…** — 调起系统 `UIDocumentPickerViewController`，可以选「存储到文件」到任意位置（含 iCloud Drive、Filza 等）
   - **复制直链** — 把 CDN 直链复制到剪贴板，方便自己用别的工具下

---

## 四、配置

首次运行会在 Telegram 的 Documents 目录生成模板：

```
/var/mobile/Containers/Data/Application/<TG-UUID>/Documents/TGSaveAnywhere/config.plist
```

用 Filza 编辑即可：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Enabled` | Bool | true | 总开关 |
| `ShowOverlay` | Bool | true | 是否显示悬浮 ↓ 按钮 |
| `DiscoveryMode` | Bool | false | 符号探测模式，见第五节 |
| `ForceTrueHooks` | Array | [] | 额外的强制返回 YES 的 hook，格式 `"类名::selector"` |

**注意**：Telegram 是沙盒 App，读 `/var/mobile/Library/Preferences/...` 可能被拒，所以主配置文件放在 App 自己的 Documents 里，程序也会尝试读取 `/var/mobile/Library/Preferences/com.gusing.tgsaveanywhere.plist` 作为备选（两个位置哪个读得到用哪个）。

---

## 五、遇到抓不到源 / 想更彻底地解锁保存按钮

绝大多数情况下 AV 层直接就能拿到源。如果某个版本 Telegram 用了自定义 `AVAssetResourceLoaderDelegate`（自定义 scheme，不是 file/https），或者你想让 Telegram **原生的保存按钮和转发按钮也恢复可用**，就开探测模式：

1. 编辑 `config.plist`，`DiscoveryMode` 设为 `true`。
2. 重启 Telegram，随便逛一圈频道，多开几个视频。
3. 取出日志：

```
/var/mobile/Containers/Data/Application/<TG-UUID>/Documents/TGSaveAnywhere/tgsaveanywhere.log
```

4. 把日志发我（同时告诉我 **Telegram 版本号** 和 **越狱方式 / iOS 版本**），我从里面找出真正的限制判定方法，给你一行 `ForceTrueHooks` 配置，例如：

```xml
<key>ForceTrueHooks</key>
<array>
    <string>Message::isContentProtected</string>
    <string>ChatController::canSaveMedia</string>
</array>
```

填进去重启 Telegram 即可，不用重编译。

> `ForceTrueHooks` 出于安全考虑**只接受返回 void / BOOL / char 的方法**；返回对象指针的方法不会 hook（否则会造出野指针直接崩）。

---

## 六、文件说明

| 文件 | 作用 |
|---|---|
| `TGSAHeaders.h` | 公共声明 |
| `TGSAUtil.m` | 日志、配置读取、runtime swizzle 工具、取顶层 VC |
| `TGSAMediaCapture.xm` | hook `AVAsset` / `AVURLAsset` / `AVPlayerItem` / `AVPlayer` / `AVPlayerLayer` 抓源 |
| `TGSAStore.m` | 复制本地缓存、下载远程直链、存相册、导出到文件 |
| `TGSAOverlay.m` | 悬浮按钮 + 操作菜单 |
| `TGSARestriction.xm` | 符号探测 + `ForceTrueHooks` 强制解锁 |
| `TGSAMain.xm` | 注入入口，打印版本与路径信息 |
| `Makefile` / `control` / `TGSaveAnywhere.plist` | Theos 构建与过滤配置 |

---

## 七、已知限制

- 必须**先让视频开始播放**才会出现按钮 —— 这是设计使然，源只有播放时才产生。
- 如果走的是「本地缓存」分支，**等进度条缓冲完再点**，否则复制出来的可能是半个文件（点了「存储到文件」发现只有几 MB 就是这原因，等一会儿重新播一次即可）。
- 缓存文件通常无扩展名，程序统一按 `.mp4` 命名；个别 `.mov` 源不影响播放。
- 「加密频道」如果指的是 Secret Chat（端到端 + 阅后即焚），本 tweak 不解密任何内容，只处理已经渲染到你屏幕上的媒体流。
- 相册保存依赖 `NSPhotoLibraryAddUsageDescription`；若目标版本 Info.plist 缺这个键，程序会自动降级为「存储到文件」而不是崩溃。
- 大视频下载没有断点续传，失败重来一次即可（todo）。

---

## 八、声明

这是给你**自己设备上个人备份**用的工具。用它下载别人的付费/私密内容并二次分发，你自己承担后果 —— 也别拿它去干蠢事。
