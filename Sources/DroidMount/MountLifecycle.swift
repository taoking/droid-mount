import Foundation

/// How an aft-mtp-mount process ended.
enum HelperExit: Equatable, Sendable {
    /// The FUSE session ended because the volume was unmounted - by Finder's eject,
    /// `diskutil unmount`, or DroidMount itself. The helper exits 0 only then.
    case unmounted
    /// DroidMount gave up waiting for the volume and stopped the helper.
    case timedOut
    /// Any other exit: a failure status or a signal. Carries the tail of its output.
    case failed(String)
}

/// Why the volume is not (or no longer) available, as shown in the menu.
enum MountFailure: Equatable, Sendable {
    /// The phone's MTP interface is on the bus but the helper could not open it.
    case deviceBusy
    /// A mount was requested with no MTP device on the bus and the helper found none.
    case noDevice
    case timedOut
    case helperFailed(String)
    /// An eject was refused because something still uses the volume.
    case volumeBusy

    init(exit: HelperExit, deviceConnected: Bool) {
        switch exit {
        case .unmounted:
            self = .helperFailed("")
        case .timedOut:
            self = .timedOut
        case .failed(let output):
            let normalized = output.lowercased()
            if normalized.contains("no mtp device") || normalized.contains("device not found") {
                self = deviceConnected ? .deviceBusy : .noDevice
            } else {
                self = .helperFailed(Self.lastLine(of: output))
            }
        }
    }

    /// A headline and, after a newline, what to do about it; the menu shows one item per line.
    var message: String {
        switch self {
        case .deviceBusy:
            return "手机已连接，但 MTP 接口被其他程序占用\n关闭 macMTP、OpenMTP 等程序后会自动重试"
        case .noDevice:
            return "未找到 Android MTP 设备\n请解锁手机并选择“文件传输 / MTP”"
        case .timedOut:
            return "等待 Android 挂载超时\n请确认手机已解锁并选择“文件传输 / MTP”"
        case .helperFailed(let detail):
            return detail.isEmpty ? "挂载助手意外退出" : "挂载失败\n\(detail)"
        case .volumeBusy:
            return "Android 卷正在使用中，无法推出\n请先停止拷贝并关闭卷上的文件"
        }
    }

    private static func lastLine(of output: String, limit: Int = 160) -> String {
        let line = output
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

/// The mount state machine. It decides what to do from what has happened and leaves
/// processes, IOKit and timers to `MountController`, so every rule here is testable.
struct MountLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case mounting
        case mounted
        case unmounting
    }

    enum Event: Equatable, Sendable {
        /// Whether any MTP interface is present on the USB bus.
        case deviceConnectionChanged(Bool)
        case mountRequested
        case unmountRequested
        case volumeAppeared
        case unmountRefused
        case helperExited(HelperExit)
        case retryTimerFired
    }

    enum Command: Equatable, Sendable {
        case startHelper
        /// Unmount the volume normally; the helper exits once its session ends.
        case unmountVolume
        /// Stop the helper and force away any mount it leaves behind.
        case stopHelper
        case scheduleRetry(seconds: Int)
        case cancelRetry
    }

    private(set) var phase: Phase = .idle
    private(set) var deviceConnected = false
    /// The user ejected the volume - from the menu or from Finder - while the phone stayed
    /// connected. Auto-mount stays off until the phone is unplugged or a mount is requested;
    /// otherwise the next USB event would mount the volume right back.
    private(set) var pausedByUser = false
    private(set) var failure: MountFailure?
    private(set) var consecutiveFailures = 0

    mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case .deviceConnectionChanged(let connected):
            guard connected != deviceConnected else { return [] }
            deviceConnected = connected
            consecutiveFailures = 0
            failure = nil
            if connected {
                return phase == .idle && !pausedByUser ? beginMount() : []
            }
            pausedByUser = false
            guard phase != .idle else { return [.cancelRetry] }
            phase = .unmounting
            return [.cancelRetry, .stopHelper]

        case .mountRequested:
            pausedByUser = false
            consecutiveFailures = 0
            failure = nil
            return phase == .idle ? beginMount() : []

        case .unmountRequested:
            switch phase {
            case .mounted:
                pausedByUser = true
                failure = nil
                phase = .unmounting
                return [.unmountVolume]
            case .mounting:
                pausedByUser = true
                phase = .unmounting
                return [.stopHelper]
            case .idle, .unmounting:
                return []
            }

        case .volumeAppeared:
            guard phase == .mounting else { return [] }
            phase = .mounted
            failure = nil
            consecutiveFailures = 0
            return []

        case .unmountRefused:
            guard phase == .unmounting else { return [] }
            phase = .mounted
            pausedByUser = false
            failure = .volumeBusy
            return []

        case .helperExited(let exit):
            let previous = phase
            phase = .idle
            switch previous {
            case .idle:
                return []
            case .unmounting:
                // Expected after an eject or an unplug. If the phone came back meanwhile,
                // mount it now that the old helper has let go of it.
                return deviceConnected && !pausedByUser ? beginMount() : []
            case .mounted where exit == .unmounted:
                // Ejected outside DroidMount (Finder, diskutil): respect it.
                if deviceConnected {
                    pausedByUser = true
                }
                return []
            case .mounted, .mounting:
                return recordFailure(exit)
            }

        case .retryTimerFired:
            guard phase == .idle, deviceConnected, !pausedByUser else { return [] }
            return beginMount()
        }
    }

    var statusText: String {
        switch phase {
        case .mounting:
            return "正在挂载 Android…"
        case .unmounting:
            return "正在推出 Android…"
        case .mounted:
            return failure?.message ?? "Android 已挂载到 Finder"
        case .idle:
            if let failure {
                return failure.message
            }
            if pausedByUser && deviceConnected {
                return "Android 已推出\n重新插拔手机或选择“立即挂载”"
            }
            return "等待 Android MTP 设备"
        }
    }

    /// Seconds before retrying after `failures` consecutive failed attempts: 2, 4, 8, 15.
    /// An attempt costs the helper ~25 ms and touches only the phone, so the cap is mostly
    /// how long a phone released by another MTP app waits to be mounted.
    static func retryDelay(afterFailures failures: Int) -> Int {
        min(15, 1 << min(max(failures, 1), 4))
    }

    private mutating func beginMount() -> [Command] {
        phase = .mounting
        return [.cancelRetry, .startHelper]
    }

    private mutating func recordFailure(_ exit: HelperExit) -> [Command] {
        consecutiveFailures += 1
        failure = MountFailure(exit: exit, deviceConnected: deviceConnected)
        guard deviceConnected, !pausedByUser else { return [] }
        return [.scheduleRetry(seconds: Self.retryDelay(afterFailures: consecutiveFailures))]
    }
}
