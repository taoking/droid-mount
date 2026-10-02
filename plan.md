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
- [x] 待当前 macOS 内核中挂起的旧 `umount` 清理后，再补一次实际菜单卸载与重连验证（2026-10-03 已补，见下方真机补测）。
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
- [x] 用新默认值复跑 100 张 JPG 拷贝（2026-10-02，小米 17 Pro，链路为 USB 2.0 High Speed，`UsbLinkSpeed` 480 Mbps）：3 轮各 100 张互不重叠的 `DCIM/101MSDCF` JPG、每轮重新挂载，33.8 / 33.7 / 33.3 MiB/s；`iosize=4194304` 对照 33.6 / 33.1 / 33.4 MiB/s，无收益。写入：128 MiB 单文件 36.6 MiB/s，20×6 MiB 32.4 MiB/s；12 个 ZLP 边界尺寸（0–3407860 字节）与 20+1 个文件重挂后 SHA-256 一致。
- [x] 修复 `-o noappledouble` 引入的写入回归（2026-10-02 真机复现）：助手未实现 xattr，macFUSE 的 `._` 回退又被禁止，每个带 `com.apple.provenance` 的文件 `cp` 都报 “could not copy extended attributes: Operation not permitted”，带 `com.apple.quarantine` 的文件在手机上变成 0 字节（SHA-256 为空文件）。去掉该参数则数据正确但会生成 `._*`。原型补丁（setxattr 接受并丢弃、getxattr 返回 ENOATTR、listxattr 返回空）在 `noappledouble` 下 4 类 xattr 用例全部 rc=0、SHA-256 一致、无 `._*`。已合入为 `patches/0002-fuse-accept-xattrs.patch`：经 app 挂载写入 4 组共 37 个带 xattr 的文件（ZLP 边界尺寸、20×6 MiB、128 MiB 单文件、xattr 用例），`cp` 全部 rc=0，重新挂载后 37/37 SHA-256 一致，无 `._*`。
- [x] 修复子文件夹不可写（2026-10-02 真机复现）：经 `GetObjectPropertyList` 列出的条目未设置 `st_uid/st_gid`，被报告为 `0:0`，重新挂载后存储根以下的已有子文件夹内新建、删除、改名均为 EACCES。原型补丁（属性列表回调中补 `getuid()/getgid()`）验证后可在已有子文件夹新建和删除。已合入为 `patches/0003-fuse-owner-for-property-list-entries.patch`：重新挂载后子文件夹各级条目属主为 501:20，测试目录可整体删除。macMTP 内置的助手仍未带此补丁。
- [x] 修复挂载生命周期（2026-10-02 真机复现）：Finder 推出（`diskutil unmount`）后 0.6 秒内被自动重新挂载；助手被杀后遗留的死挂载被 `isMountPoint` 认领为“已挂载”，此后不再重挂。改为纯状态机 `MountLifecycle`（18 个单元测试），设备检测改为 IOKit 接口通知，挂载表改读 `getfsstat`。2026-10-02 真机验证：启动即以 `-D 2717:ff48` 挂载；`diskutil unmount` 后观察 15 秒保持未挂载；`kill -9` 助手后清理死挂载，2.4 秒后重新挂载，挂载点上只有 1 个挂载；退出应用后卷被卸载；手机被另一个 MTP 会话占用时每次尝试约 25 ms 失败（“no MTP device found”），按 2 / 4 / 8 / 16 秒退避，释放后在下一次重试时挂载（之后把退避上限定为 15 秒）。
- [x] 新增 `patches/0004-fuse-fewer-mtp-round-trips.patch`：顺序读取时预读（最多 8 MiB，首次读取与跳转读取不预读）、statfs 结果缓存 5 秒、open() 不再额外询问设备、末尾追加写入不再先截断。同一时段交替实测（各 3 轮 100 张不重叠 JPG）：30.8 / 30.7 / 30.8 → 32.7 / 32.5 / 33.5 MiB/s；通过页缓存只读文件开头 64 KiB 两者都约 40 ms（首版对任何 1 MiB 请求都取 8 MiB，此项退化到约 226 ms，已改掉）；60 项读取校验逐字节一致。经 app 挂载写入：128 MiB 单文件 37.6 MiB/s，20×6 MiB 34.8 MiB/s。
- [x] `scripts/build_finder_mount.sh` 记录补丁集哈希，补丁变化时清空构建目录：rsync 会还原上游文件的修改时间，删掉或改动补丁后 make 会继续链接旧补丁编出的目标文件。CI 增加检查，确认补丁仍能套用到上游最新代码。
- [x] 真机补测（2026-10-03，小米 17 Pro，用户手动操作，构建自 `b04f47a`）：菜单“推出”后卷消失且不再被自动挂回；“立即挂载”重新挂载；物理拔下手机后卷被移除，插回并解锁后自动重新挂载。
- [ ] 待补测：卷被占用时菜单“推出”提示“Android 卷正在使用中”并保持挂载；菜单“在 Finder 中显示”。
- [x] 构建并发布包含挂载生命周期重写、写入修复与顺序预读的 `v0.2.0` arm64 安装包。
