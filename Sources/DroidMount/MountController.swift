import AppKit
import Foundation

/// Carries out the mount lifecycle: watches for MTP phones, starts and stops aft-mtp-mount,
/// and clears away whatever a helper leaves mounted when it dies.
@MainActor
final class MountController {
    static let macFUSEFileSystemURL = URL(fileURLWithPath: "/Library/Filesystems/macfuse.fs", isDirectory: true)
    static let macFUSELibraryURL = URL(fileURLWithPath: "/usr/local/lib/libfuse3.4.dylib")

    /// A phone that answers mounts in well under a second; a slow one still gets time to
    /// open its MTP session.
    private static let mountTimeout: Duration = .seconds(15)
    /// How long a helper may linger after its volume was unmounted before it is stopped.
    private static let helperExitGrace: Duration = .seconds(3)

    private(set) var lifecycle = MountLifecycle()
    private(set) var unavailableReason: String?
    var onStateChange: (() -> Void)?

    let mountPoint: URL
    private let baseDirectory: URL
    private var monitor: USBDeviceMonitor?
    private var devices: [MTPDevice] = []
    /// The phone the running helper was started for.
    private var activeDevice: MTPDevice?
    private var helper: HelperProcess?
    private var retryTimer: Timer?
    /// Bumped whenever a mount attempt is abandoned, so its pending steps stand down.
    private var attempt = 0

    init() {
        baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        mountPoint = MountConfiguration.mountPoint(baseDirectory: baseDirectory)
        unavailableReason = Self.checkAvailability()
    }

    var statusText: String {
        unavailableReason ?? lifecycle.statusText
    }

    func start() {
        if unavailableReason == nil {
            startMonitoring()
        }
        onStateChange?()
    }

    /// macFUSE can be installed or approved while DroidMount runs; checked when the menu opens.
    func refreshAvailability() {
        let reason = Self.checkAvailability()
        guard reason != unavailableReason else { return }
        unavailableReason = reason
        if reason == nil {
            startMonitoring()
        }
        onStateChange?()
    }

    func mountNow() {
        send(.mountRequested)
    }

    func unmount() {
        send(.unmountRequested)
    }

    func openFinder() {
        guard lifecycle.phase == .mounted else { return }
        NSWorkspace.shared.open(mountPoint)
    }

    /// Unmounts and stops the helper before the app exits. Blocks for a few seconds at most.
    func shutdown() {
        retryTimer?.invalidate()
        retryTimer = nil
        monitor?.stop()
        monitor = nil
        attempt += 1
        let helper = self.helper
        self.helper = nil
        guard helper != nil || MountTable.isMounted(mountPoint) else { return }

        if MountTable.isMounted(mountPoint) {
            Self.runAndWait("/sbin/umount", [mountPoint.path], timeout: 3)
        }
        helper?.terminate()
        helper?.waitForExit(timeout: 2)
        if MountTable.isMounted(mountPoint) {
            Self.runAndWait("/sbin/umount", ["-f", mountPoint.path], timeout: 2)
        }
    }

    // MARK: - Events

    private func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = USBDeviceMonitor { [weak self] devices in
            self?.devicesChanged(devices)
        }
        self.monitor = monitor
        monitor.start()
    }

    private func devicesChanged(_ devices: [MTPDevice]) {
        self.devices = devices
        if let activeDevice, !devices.contains(where: { $0.registryID == activeDevice.registryID }) {
            // The phone this helper serves went away while another one stays attached:
            // tear down, then mount the remaining phone once the helper has exited.
            send(.deviceConnectionChanged(false))
        }
        send(.deviceConnectionChanged(!devices.isEmpty))
    }

    private func send(_ event: MountLifecycle.Event) {
        let commands = lifecycle.handle(event)
        onStateChange?()
        for command in commands {
            perform(command)
        }
    }

    private func perform(_ command: MountLifecycle.Command) {
        switch command {
        case .startHelper:
            attempt += 1
            let attempt = attempt
            Task { await runHelper(attempt: attempt) }
        case .unmountVolume:
            Task { await unmountVolume() }
        case .stopHelper:
            stopHelper()
        case .scheduleRetry(let seconds):
            scheduleRetry(after: seconds)
        case .cancelRetry:
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    // MARK: - Commands

    private func runHelper(attempt: Int) async {
        // A crashed helper - or a previous DroidMount - leaves its mount behind. macFUSE keeps
        // answering statfs for it, so it looks mounted while every access fails.
        if MountTable.isMounted(mountPoint) {
            await Self.run("/sbin/umount", ["-f", mountPoint.path])
        }
        guard attempt == self.attempt, lifecycle.phase == .mounting else { return }
        guard let helperURL = Self.helperURL else {
            send(.helperExited(.failed("aft-mtp-mount is missing from the app bundle")))
            return
        }

        let device = devices.first
        let configuration = MountConfiguration.make(baseDirectory: baseDirectory, deviceFilter: device?.helperFilter)
        let helper = HelperProcess(executableURL: helperURL, arguments: configuration.arguments)
        let helperID = ObjectIdentifier(helper)
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try helper.start { [weak self] exit in
                Task { @MainActor in
                    self?.helperDidExit(helperID, exit)
                }
            }
        } catch {
            send(.helperExited(.failed(error.localizedDescription)))
            return
        }
        self.helper = helper
        activeDevice = device

        let deadline = ContinuousClock.now + Self.mountTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard attempt == self.attempt, self.helper === helper, lifecycle.phase == .mounting else { return }
            if MountTable.isMounted(mountPoint) {
                send(.volumeAppeared)
                return
            }
        }
        helper.stopAfterTimeout()
    }

    private func helperDidExit(_ helperID: ObjectIdentifier, _ exit: HelperExit) {
        guard let helper, ObjectIdentifier(helper) == helperID else { return }
        self.helper = nil
        activeDevice = nil
        send(.helperExited(exit))
        // Whatever the helper left mounted is dead now. Remove it so Finder does not keep a
        // volume that fails every access; a new attempt clears it on its own.
        if lifecycle.phase != .mounting, MountTable.isMounted(mountPoint) {
            Task { await Self.run("/sbin/umount", ["-f", mountPoint.path]) }
        }
    }

    private func unmountVolume() async {
        let status = await Self.run("/sbin/umount", [mountPoint.path])
        guard lifecycle.phase == .unmounting else { return }
        guard status == 0 else {
            send(.unmountRefused)
            return
        }
        guard let helper else {
            send(.helperExited(.unmounted))
            return
        }
        // The helper's session ends with the volume and it exits by itself; a stuck one must
        // not keep holding the phone.
        try? await Task.sleep(for: Self.helperExitGrace)
        if self.helper === helper {
            helper.terminate()
        }
    }

    private func stopHelper() {
        attempt += 1
        if let helper {
            helper.terminate()
            return
        }
        // The attempt had not launched its helper yet, so no exit will arrive.
        Task {
            if MountTable.isMounted(mountPoint) {
                await Self.run("/sbin/umount", ["-f", mountPoint.path])
            }
            send(.helperExited(.unmounted))
        }
    }

    private func scheduleRetry(after seconds: Int) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryTimer = nil
                self?.send(.retryTimerFired)
            }
        }
    }

    // MARK: - Environment

    private static var helperURL: URL? {
        Bundle.main.url(forResource: "aft-mtp-mount", withExtension: nil, subdirectory: "FinderMount")
    }

    private static func checkAvailability() -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: macFUSEFileSystemURL.path),
              fileManager.fileExists(atPath: macFUSELibraryURL.path) else {
            return "需要安装并批准 macFUSE。"
        }
        guard let helperURL, fileManager.isExecutableFile(atPath: helperURL.path) else {
            return "DroidMount 未包含挂载助手，请重新构建应用。"
        }
        return nil
    }

    @discardableResult
    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    private nonisolated static func runAndWait(_ path: String, _ arguments: [String], timeout: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
