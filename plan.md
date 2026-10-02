# DroidMount 开发计划

## 目标

构建独立菜单栏应用 DroidMount（Bundle ID `com.taoking.droidmount`）：检测到 Android MTP 手机后自动以可写方式挂载到 Finder，不提供 macMTP 的双栏浏览或传输界面。

## 执行清单

- [x] 确认产品范围、名称、仓库名、Bundle ID 与自动挂载行为。
- [x] 创建独立 Swift/AppKit 菜单栏工程与可写挂载配置。
- [x] 复用并独立打包 `aft-mtp-mount` 与 macFUSE 构建流程。
- [x] 构建、自动化测试和签名验证。
- [x] 用已连接的小米 17 Pro 验证自动挂载、Finder 创建目录和复制写入（SHA-256 一致）。
- [x] 将卸载改为非阻塞请求，避免 Finder 占用卷时菜单栏应用卡死。
- [ ] 待当前 macOS 内核中挂起的旧 `umount` 清理后，再补一次实际菜单卸载与重连验证。
- [x] 创建公开 GitHub 仓库 `taoking/droid-mount` 并推送代码。
- [x] 构建 `v0.1.0` arm64 发布包并上传到 GitHub Releases。
- [x] 生成并接入 DroidMount 应用图标（透明 PNG 与 macOS `.icns`）。
- [x] 构建并发布包含新图标的 `v0.1.1` arm64 安装包。
- [x] 修复遗留 FUSE 挂载被重试循环误判为成功、反复唤起 Finder 的问题；Finder 打开改为显式菜单操作。
- [x] 构建并发布包含弹窗修复的 `v0.1.2` arm64 安装包。
- [x] 将 macOS USB 后端单次批量传输由「一个 USB 包」提升到 16 KiB（`patches/0001-darwin-usb-bulk-buffer.patch`），并把上游源码改为补丁化暂存构建。
- [x] 在小米 17 Pro 上实测拷贝速度：`DCIM/101MSDCF` 的 100 张 JPG，打补丁前 5.14 MiB/s，打补丁后 21.5–23.0 MiB/s（4.2×）；15 个文件跨两条代码路径 SHA-256 一致，900 个拷贝件 JPEG 首尾标记完整。
- [x] 把默认缓冲提到 256 KiB，并为挂载参数加上 `-o iosize=1048576 -o noappledouble`（实测组合 31.6–32.3 MiB/s）。
- [x] 修复 `scripts/build.sh` 把 7 月 28 日的陈旧二进制打进 app bundle 的问题：产物路径改为向 SwiftPM 查询 `--show-bin-path`，并新增 `lipo -archs` 架构校验（当前工具链的输出目录不再按 triple 区分）。
- [ ] 待手机重新连接后，用新默认值复跑 100 张 JPG 拷贝，确认落在 31–32 MiB/s。
