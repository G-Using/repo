# 我的个人越狱源（Cydia / Sileo / Zebra）

一个**纯静态、零服务器**的越狱软件源：用 GitHub 仓库 + GitHub Pages 托管，
把 `.deb` 丢进去，索引自动生成，手机端刷新源就能下载安装你自己的 tweak / 插件。

---

## 一、你需要准备

- 一个 **GitHub 账号**（必须是**你自己的**或**已获授权**的账号，别用别人的令牌乱建仓）
- 电脑装了 `git` 和 `python3`（仅本地生成索引时需要；用网页上传方式可完全不装 Python）
- 已经编译好的 `.deb` 文件（rootless 用 `iphoneos-arm64`，rootful 用 `iphoneos-arm`）

---

## 二、5 分钟搭起来

1. **在 GitHub 新建一个公开仓库**（必须 public，否则免费版 GitHub Pages 不能用）。
   名字随意，例如 `repo`。建的时候**不要**勾选 "Add a README"（保持空仓最干净）。

2. **把本工具包的所有文件**（`build_repo.py`、`.github/`、`debs/`、`index.html`、`README.md`）
   放进仓库根目录，然后 `git add -A && git commit -m "init" && git push`。

3. **开启 GitHub Pages**（一次性）：
   - 进仓库 → **Settings → Pages**
   - Source 选 **Deploy from a branch**
   - Branch 选 **main**，目录选 **/ (root)**
   - 保存。等 1~2 分钟生效。

4. 你的源地址就是：
   ```
   https://<你的GitHub用户名>.github.io/<仓库名>/
   ```
   例如用户名 `myname`、仓库 `repo` → `https://myname.github.io/repo/`

> 推送后 GitHub Actions 会自动跑 `build_repo.py` 生成索引；第一次会是空源（0 个包），正常。

---

## 三、怎么放入插件（重点）

两种方法，任选其一。无论哪种，**放进 `debs/` 后索引都会自动重建**，手机刷新源即可看到。

### 方法 A：用 GitHub 网页（最简单，不用装任何东西）
1. 打开仓库里的 `debs/` 文件夹。
2. 点 **Add file → Upload files**，把你的 `.deb` 拖进去。
3. 点 **Commit changes** 提交。
4. 仓库的 **Actions** 标签页会跑一次 "Build Repo Index"，跑完后索引更新。
5. 手机端刷新源 → 看到新包 → 安装。

### 方法 B：本地 git + 脚本（适合批量/频繁更新）
```sh
# 1. 把 .deb 复制到 debs/ 目录
cp 你的插件.deb debs/

# 2. 本地生成索引（装了 python3 即可，无需 dpkg）
python3 build_repo.py

# 3. 提交并推送
git add -A
git commit -m "add 你的插件"
git push
```
推送后 Actions 会再跑一次（幂等，无变化就不提交），双重保险。

---

## 四、在手机上添加这个源

- **Sileo / Zebra**：Sources → Edit / + → 输入源地址 `https://<用户名>.github.io/<仓库名>/` → 添加 → 刷新。
- **Cydia**：Sources → Edit → Add → 同样输入地址。
- 想一键添加，可把 `index.html` 里的链接改成：
  `sileo://source/https://<用户名>.github.io/<仓库名>/`

---

## 五、验证源是否正常

在电脑上跑这两条确认索引对得上（避免"显示为空/只有 1 个包"）：

```sh
# 1) 看包数量
curl -s https://<用户名>.github.io/<仓库名>/Packages | grep -c '^Package:'

# 2) 校验和是否一致（拿 Release 里 Packages 那行的 md5 比对）
curl -s https://<用户名>.github.io/<仓库名>/Packages -o liveP.txt
curl -s https://<用户名>.github.io/<仓库名>/Release  -o R.txt
md5sum liveP.txt
```
如果 `grep -c` 数量和实际 deb 数一致、`md5sum` 与 `Release` 吻合，源就是健康的。
（GitHub Pages 有 CDN 缓存，刚推送完可用 `?t=时间戳` 破缓存，等 1~2 分钟再测。）

---

## 六、常见问题

- **源添加后为空 / 只有 1 个包**：99% 是索引生成脚本读不到 `control.tar.xz`（老脚本只认 `.gz`）。
  本工具包用通用 ar 解析，gz/xz/zst 都支持，不会踩这个坑。
- **要不要签名？** 不签名也能用（Sileo/Zebra 只会弹个"未签名源"警告）。要去掉警告需配 GPG 私钥签名 `Release`，个人自用一般没必要。
- **换电脑/换人加包**：先在最新代码上 `git pull` 再操作，避免把别人新加的包覆盖掉（索引是整文件覆盖，不是增量）。
- **私有源？** 免费版 GitHub Pages 只支持公开仓库。要私有就得付费或自己托管服务器。

---

## 七、安全提醒

- **GitHub 个人访问令牌（PAT）等同于你账号的密码**，只在自己机器上用，用完可从 GitHub → Settings → Developer settings 撤销。
- **不要在别人的 GitHub 账号上建源**——需要账号主人授权，否则属于未经授权的操作。
- 本工具包不会上传任何令牌；所有索引都在你自己的仓库里生成。
