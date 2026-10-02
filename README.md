# DroidMount｜安卓文件挂载器

DroidMount 是一个菜单栏应用：检测到已解锁、处于“文件传输 / MTP”模式的 Android 手机后，自动将其以**可写**卷挂载到 macOS Finder。

挂载成功后，手机存储像普通外接磁盘一样出现在 Finder 中，可直接浏览、复制、移动、创建文件夹、重命名和删除。DroidMount 不提供双栏文件浏览器、传输队列或手机文件管理窗口。

## 下载与安装

在 [Releases](https://github.com/taoking/droid-mount/releases) 下载与 Mac 芯片匹配的 ZIP，解压后将 `DroidMount.app` 拖入“应用程序”文件夹即可。

首次使用前仍必须从 macFUSE 官网安装并批准 macFUSE。当前 `v0.1.2` 为开发者临时签名的 arm64 构建，未使用 Apple Developer ID 公证；若 macOS 阻止打开，请在 Finder 中按住 Control 点按应用并选择“打开”，或在“系统设置 → 隐私与安全性”中确认打开。

## 使用方法

1. 安装并批准 macFUSE；Apple Silicon 首次安装可能需要在启动安全性实用工具中允许内核扩展，并按系统提示重启。
2. 启动 `DroidMount.app`。应用只显示在菜单栏，不显示 Dock 图标或主窗口。
3. 连接并解锁手机，在 Android 的 USB 用途中选择“文件传输 / MTP”。
4. DroidMount 自动挂载 Finder 卷 `DroidMount Android`；它会出现在 Finder 边栏中。
5. 在 Finder 内直接进行读写、创建、移动、改名、删除等操作。
6. 完成后从菜单栏选择“卸载 Finder”。

挂载期间，DroidMount 独占该手机的 MTP 会话。当前版本只支持一台 Android MTP 设备；如有多台，请先断开其余设备。

## 菜单栏状态

- **等待 Android MTP 设备**：未检测到可挂载的手机；连接、解锁并选择文件传输后会自动重试。
- **正在挂载 Android**：正在建立 MTP/FUSE 会话。
- **Android 已挂载到 Finder**：可按需选择“在 Finder 中显示”或“卸载 Finder”。
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

`android-file-transfer-linux` 保持上游原样，不做任何本地修改。构建时会先把它同步到 `.build/aft-src-<架构>/`，再按顺序套用 `patches/*.patch`，然后从该副本编译。新增改动请写成 `patches/` 下的补丁文件。

### 传输性能

拷贝速度由两处配置共同决定，二者独立生效：

1. **USB 批量传输缓冲**。`patches/0001-darwin-usb-bulk-buffer.patch` 把 macOS USB 后端的单次批量传输从「一个 USB 包」（高速 512 字节 / 超速 1024 字节）提升到 256 KiB。IOKit 的 `ReadPipe`/`WritePipe` 是同步调用，每次调用都要付一次用户态/内核态往返加一次 USB 往返，因此调用次数直接决定吞吐。
2. **FUSE 请求大小**。`MountConfiguration` 传入 `-o iosize=1048576` 和 `-o noappledouble`：每个 FUSE 读请求对应一次 MTP 事务，请求越大往返越少；`noappledouble` 则避免 Finder 为每个文件额外写入 `._` 附属文件。

在小米 17 Pro 上从 DCIM 拷贝 100 张 JPEG 的实测（每组文件互不重叠，每次测量前重新挂载）：

| 配置 | 吞吐 |
|---|---|
| 每次调用一个 USB 包（打补丁前） | 5.1 MiB/s |
| 16 KiB | 21.5–23.0 MiB/s |
| 64 KiB | 24.6 MiB/s |
| 256 KiB | 25.9 MiB/s |
| 16 KiB + `iosize=1M` | 28.2 MiB/s |
| 256 KiB + `iosize=1M` + `noappledouble`（当前默认） | 31.6–32.3 MiB/s |

缓冲大小可用环境变量在运行时调整，便于在真机上对比，不必重新构建：

```bash
# 复现打补丁前的行为（每次调用一个 USB 包）
AFTL_USB_BULK_BUFFER_SIZE=1 ./aft-mtp-mount /path/to/mountpoint

# 试其他缓冲，上限 1 MiB；实际值会向下取整到 USB 包大小的整数倍
AFTL_USB_BULK_BUFFER_SIZE=65536 ./aft-mtp-mount /path/to/mountpoint
```

## 已知行为

- 挂载时已传入 `noappledouble`，Finder 不会再为每个文件写入 `._` 前缀的附属文件；`.DS_Store` 等其他元数据文件仍可能出现。
- 卸载前请停止正在进行的拷贝并关闭占用该卷的文件；DroidMount 会保持菜单栏可响应，并在卸载失败时提示处理方式。
- 物理拔线时，先重新插入、解锁并重新选择“文件传输 / MTP”；DroidMount 会自动重新尝试挂载。
- 应用不提供多设备选择器；连接多台设备时，挂载助手会使用第一台可用 MTP 设备。
- `v0.1.2` 发布包仅支持 Apple Silicon（arm64）Mac。

## 开发验证

```bash
swift test
bash scripts/build.sh debug --arch arm64
codesign --verify --deep --strict --verbose=2 DroidMount.app
```
