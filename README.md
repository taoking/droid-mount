# DroidMount｜安卓文件挂载器

DroidMount 是一个菜单栏应用：检测到已解锁、处于“文件传输 / MTP”模式的 Android 手机后，自动将其以**可写**卷挂载到 macOS Finder。

挂载成功后，手机存储像普通外接磁盘一样出现在 Finder 中，可直接浏览、复制、移动、创建文件夹、重命名和删除。DroidMount 不提供双栏文件浏览器、传输队列或手机文件管理窗口。

## 下载与安装

在 [Releases](https://github.com/taoking/droid-mount/releases) 下载与 Mac 芯片匹配的 ZIP，解压后将 `DroidMount.app` 拖入“应用程序”文件夹即可。

首次使用前仍必须从 macFUSE 官网安装并批准 macFUSE。当前 `v0.2.0` 为开发者临时签名的 arm64 构建，未使用 Apple Developer ID 公证；若 macOS 阻止打开，请在 Finder 中按住 Control 点按应用并选择“打开”，或在“系统设置 → 隐私与安全性”中确认打开。

## 使用方法

1. 安装并批准 macFUSE；Apple Silicon 首次安装可能需要在启动安全性实用工具中允许内核扩展，并按系统提示重启。
2. 启动 `DroidMount.app`。应用只显示在菜单栏，不显示 Dock 图标或主窗口。
3. 连接并解锁手机，在 Android 的 USB 用途中选择“文件传输 / MTP”。
4. DroidMount 自动挂载 Finder 卷 `DroidMount Android`；它会出现在 Finder 边栏中。
5. 在 Finder 内直接进行读写、创建、移动、改名、删除等操作。
6. 完成后从菜单栏选择“推出”，或直接在 Finder 中推出该卷。

推出后 DroidMount 不会立刻把卷挂回来：手机保持连接期间自动挂载会暂停，拔下再插上手机，或在菜单中选择“立即挂载”即可再次挂载。

挂载期间，DroidMount 独占该手机的 MTP 会话。当前版本只挂载一台 Android MTP 设备：挂载助手只连接最先检测到的那台手机，不会逐个打开其他 USB 设备。

## 菜单栏状态

- **等待 Android MTP 设备**：USB 上没有 MTP 接口；连接、解锁并选择“文件传输 / MTP”后会自动挂载。
- **正在挂载 Android… / 正在推出 Android…**：正在建立或结束 MTP/FUSE 会话。
- **Android 已挂载到 Finder**：可选择“在 Finder 中显示”或“推出”。
- **Android 已推出**：卷已从菜单或 Finder 推出，手机仍连着；自动挂载暂停，直到拔下手机或选择“立即挂载”。
- **手机已连接，但 MTP 接口被其他程序占用**：macMTP、OpenMTP 等程序正在使用这台手机；关闭它们后 DroidMount 会自动重试。
- **等待 Android 挂载超时 / 挂载失败**：后者附带挂载助手的最后一行输出。手机连着时，以上失败都会按 2、4、8 秒的间隔重试，之后每 15 秒重试一次。
- **Android 卷正在使用中，无法推出**：仍有程序在读写卷上的文件，卷保持挂载；结束后再推出即可。
- **需要安装并批准 macFUSE**：按下文完成安装；每次打开菜单都会重新检测，无需重启应用。

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

`android-file-transfer-linux` 保持上游原样，不做任何本地修改。构建时会先把它同步到 `.build/aft-src-<架构>/`，再按顺序套用 `patches/*.patch`，然后从该副本编译；补丁集一有变化就清空对应的构建目录，避免沿用旧补丁编出的目标文件。新增改动请写成 `patches/` 下的补丁文件。

| 补丁 | 作用 |
|---|---|
| `0001-darwin-usb-bulk-buffer.patch` | macOS USB 后端的单次批量传输由一个 USB 包提升到 256 KiB |
| `0002-fuse-accept-xattrs.patch` | 接受并丢弃扩展属性。配合 `noappledouble` 使用，否则 `cp` 会报 “could not copy extended attributes”，带隔离属性的文件写到手机上会变成 0 字节 |
| `0003-fuse-owner-for-property-list-entries.patch` | 经属性列表列出的条目同样归当前用户所有，修复在已有子文件夹内新建、删除、改名时报 EACCES |
| `0004-fuse-fewer-mtp-round-trips.patch` | 顺序读取时预读（最多 8 MiB）；statfs 结果缓存 5 秒；open() 不再额外询问设备；末尾追加写入不再先截断 |

### 传输性能

拷贝速度由三处配置共同决定，各自独立生效：

1. **USB 批量传输缓冲**。`patches/0001-darwin-usb-bulk-buffer.patch` 把 macOS USB 后端的单次批量传输从「一个 USB 包」（高速 512 字节 / 超速 1024 字节）提升到 256 KiB。IOKit 的 `ReadPipe`/`WritePipe` 是同步调用，每次调用都要付一次用户态/内核态往返加一次 USB 往返，因此调用次数直接决定吞吐。
2. **FUSE 请求大小**。`MountConfiguration` 传入 `-o iosize=1048576` 和 `-o noappledouble`：每个 FUSE 读请求对应一次 MTP 事务，请求越大往返越少；`noappledouble` 则避免 Finder 为每个文件额外写入 `._` 附属文件。
3. **顺序预读**。每次 MTP 事务在数据之外还有约 1.5 ms 固定开销。`patches/0004-fuse-fewer-mtp-round-trips.patch` 让接着上次位置继续读的请求一次取回最多 8 MiB，后续请求直接从内存返回；文件的第一次读取和跳转读取只取所请求的大小，因此只读文件开头（Finder 取缩略图、EXIF）或在视频里拖动不会多读数据。

在小米 17 Pro 上从 DCIM 拷贝 100 张 JPEG 的实测（每组文件互不重叠，每次测量前重新挂载）：

| 配置 | 吞吐 |
|---|---|
| 每次调用一个 USB 包（打补丁前） | 5.1 MiB/s |
| 16 KiB | 21.5–23.0 MiB/s |
| 64 KiB | 24.6 MiB/s |
| 256 KiB | 25.9 MiB/s |
| 16 KiB + `iosize=1M` | 28.2 MiB/s |
| 256 KiB + `iosize=1M` + `noappledouble` | 31.6–32.3 MiB/s |

预读的收益在同一时段交替测量（各 3 轮）：不带 `0004` 为 30.8 / 30.7 / 30.8 MiB/s，带 `0004`（当前默认）为 32.7 / 32.5 / 33.5 MiB/s，约快 7%。通过页缓存只读取文件开头 64 KiB 仍是一次 1 MiB 事务，两者都约 40 ms。60 项读取校验（含随机偏移读取）与不带 `0004` 时逐字节一致。

缓冲大小可用环境变量在运行时调整，便于在真机上对比，不必重新构建：

```bash
# 复现打补丁前的行为（每次调用一个 USB 包）
AFTL_USB_BULK_BUFFER_SIZE=1 ./aft-mtp-mount /path/to/mountpoint

# 试其他缓冲，上限 1 MiB；实际值会向下取整到 USB 包大小的整数倍
AFTL_USB_BULK_BUFFER_SIZE=65536 ./aft-mtp-mount /path/to/mountpoint
```

## 已知行为

- 挂载时传入了 `noappledouble`：Finder 不会在手机上创建 `._*` 附属文件或 `.DS_Store`，手机上原有的 `._*` 文件在 Finder 中也会被隐藏。
- 扩展属性（Finder 标签、隔离标记等）不会写到手机上：MTP 没有存放它们的位置，挂载助手接受后直接丢弃，文件内容不受影响。
- 推出前请停止正在进行的拷贝并关闭占用该卷的文件；卷被占用时 DroidMount 会提示“Android 卷正在使用中，无法推出”并保持挂载，菜单栏始终可响应。
- 拔下手机后，DroidMount 会结束挂载助手并移除卷，拔线时正在进行的拷贝会失败；重新插入、解锁并选择“文件传输 / MTP”后会自动挂载。
- 挂载助手意外退出时，DroidMount 会清理遗留的失效挂载，并按上文的间隔自动重新挂载。
- 应用不提供多设备选择器；连接多台 Android 手机时，只挂载最先检测到的一台。
- `v0.2.0` 发布包仅支持 Apple Silicon（arm64）Mac。

## 开发验证

```bash
swift test
bash scripts/build.sh debug --arch arm64
codesign --verify --deep --strict --verbose=2 DroidMount.app
```
