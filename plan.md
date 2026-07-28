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
