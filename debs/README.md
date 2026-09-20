# debs 文件夹

把你编译好的 **.deb** 文件直接丢进这个文件夹即可。

- 支持 rootful (`iphoneos-arm`) 和 rootless (`iphoneos-arm64`，Dopamine / TrollStore) 的包。
- 每个 deb 的 `control` 信息（包名、版本、依赖、作者等）会被 `build_repo.py` 自动读取并写进索引。
- 添加 / 删除 deb 后，推送（push）到 GitHub，GitHub Actions 会自动重建 `Packages` / `Release` 索引。
- 之后在手机端刷新源就能看到新包。

> 这个文件夹里现在只有一个占位文件，源刚建好时是空的（0 个包），正常现象。
