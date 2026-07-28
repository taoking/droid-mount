# DroidMount｜安卓文件挂载器

DroidMount 是一个菜单栏应用：检测到已解锁、处于“文件传输 / MTP”模式的 Android 手机后，自动将其以**可写**卷挂载到 macOS Finder。

挂载成功后，手机存储像普通外接磁盘一样出现在 Finder 中，可直接浏览、复制、移动、创建文件夹、重命名和删除。DroidMount 不提供双栏文件浏览器、传输队列或手机文件管理窗口。

## 下载与安装

在 [Releases](https://github.com/taoking/droid-mount/releases) 下载与 Mac 芯片匹配的 ZIP，解压后将 `DroidMount.app` 拖入“应用程序”文件夹即可。

首次使用前仍必须从 macFUSE 官网安装并批准 macFUSE。当前 `v0.1.0` 为开发者临时签名的 arm64 构建，未使用 Apple Developer ID 公证；若 macOS 阻止打开，请在 Finder 中按住 Control 点按应用并选择“打开”，或在“系统设置 → 隐私与安全性”中确认打开。

## 使用方法

1. 安装并批准 macFUSE；Apple Silicon 首次安装可能需要在启动安全性实用工具中允许内核扩展，并按系统提示重启。
2. 启动 `DroidMount.app`。应用只显示在菜单栏，不显示 Dock 图标或主窗口。
3. 连接并解锁手机，在 Android 的 USB 用途中选择“文件传输 / MTP”。
4. DroidMount 自动挂载 Finder 卷 `DroidMount Android` 并打开 Finder。
5. 在 Finder 内直接进行读写、创建、移动、改名、删除等操作。
6. 完成后从菜单栏选择“卸载 Finder”。

挂载期间，DroidMount 独占该手机的 MTP 会话。当前版本只支持一台 Android MTP 设备；如有多台，请先断开其余设备。

## 菜单栏状态

- **等待 Android MTP 设备**：未检测到可挂载的手机；连接、解锁并选择文件传输后会自动重试。
- **正在挂载 Android**：正在建立 MTP/FUSE 会话。
- **Android 已挂载到 Finder**：可选择“在 Finder 中显示”或“卸载 Finder”。
- **需要安装并批准 macFUSE**：按下文完成安装并重新构建。

## 构建

依赖：macOS 14+、Swift 6、CMake、macFUSE，以及同级目录的 `android-file-transfer-linux` 源码。

```bash
brew install cmake
brew install --cask macfuse
git clone https://github.com/whoozle/android-file-transfer-linux.git ../android-file-transfer-linux

bash scripts/build.sh debug --arch "$(uname -m)"
open DroidMount.app
```

构建脚本会编译并打包 `aft-mtp-mount`。DroidMount 不包含云服务、账号、遥测或钥匙串凭证。

## 已知行为

- Finder 的 macOS 元数据可能作为 `._` 前缀的普通文件写入手机存储。
- 卸载前请停止正在进行的拷贝并关闭占用该卷的文件；DroidMount 会保持菜单栏可响应，并在卸载失败时提示处理方式。
- 物理拔线时，先重新插入、解锁并重新选择“文件传输 / MTP”；DroidMount 会自动重新尝试挂载。
- 应用不提供多设备选择器；连接多台设备时，挂载助手会使用第一台可用 MTP 设备。
- `v0.1.0` 发布包仅支持 Apple Silicon（arm64）Mac。

## 开发验证

```bash
swift test
bash scripts/build.sh debug --arch arm64
codesign --verify --deep --strict --verbose=2 DroidMount.app
```
