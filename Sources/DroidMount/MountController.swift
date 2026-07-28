import AppKit
import Darwin
import Foundation

enum MountState: Equatable {
    case waitingForAndroid
    case mounting
    case mounted(URL)
    case unavailable(String)
    case failed(String)

    var statusText: String {
        switch self {
        case .waitingForAndroid:
            return "等待 Android MTP 设备"
        case .mounting:
            return "正在挂载 Android…"
        case .mounted:
            return "Android 已挂载到 Finder"
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }
}

@MainActor
final class MountController: NSObject {
    static let macFUSEFileSystemURL = URL(fileURLWithPath: "/Library/Filesystems/macfuse.fs", isDirectory: true)
    static let macFUSELibraryURL = URL(fileURLWithPath: "/usr/local/lib/libfuse3.4.dylib")

    private(set) var state: MountState {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((MountState) -> Void)?

    private let fileManager: FileManager
    private var usbMonitor: USBDeviceMonitor?
    private var retryTimer: Timer?
    private var mountProcess: Process?
    private var pendingUnmountProcess: Process?
    private var outputPipe: Pipe?
    private var activeConfiguration: MountConfiguration?

    override init() {
        fileManager = .default
        state = .waitingForAndroid
        super.init()
        if let reason = unavailableReason() {
            state = .unavailable(reason)
        }
    }

    func start() {
        guard unavailableReason() == nil else {
            state = .unavailable(unavailableReason() ?? "Finder 挂载不可用。")
            return
        }

        usbMonitor = USBDeviceMonitor { [weak self] in
            self?.mountIfNeeded()
        }
        usbMonitor?.start()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.mountIfNeeded()
            }
        }
        mountIfNeeded()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        usbMonitor?.stop()
        usbMonitor = nil
        unmountSynchronously()
    }

    func mountIfNeeded() {
        guard !state.isMounted, state != .mounting, unavailableReason() == nil else { return }
        Task { await mount() }
    }

    func mount() async {
        guard !state.isMounted, state != .mounting,
              let helperURL = bundledHelperURL(), unavailableReason() == nil else { return }

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configuration = MountConfiguration.make(baseDirectory: baseDirectory)

        // A previous app instance can leave a FUSE mount behind after its helper
        // exits. Treat that mount as an existing volume instead of spawning a
        // new helper and repeatedly asking Finder to open the same path.
        guard !isMountPoint(configuration.mountPoint) else {
            activeConfiguration = configuration
            state = .mounted(configuration.mountPoint)
            return
        }

        state = .mounting

        do {
            try fileManager.createDirectory(at: configuration.mountPoint, withIntermediateDirectories: true)

            let process = Process()
            let pipe = Pipe()
            process.executableURL = helperURL
            process.arguments = configuration.arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { [weak self, weak process] _ in
                guard let process else { return }
                Task { @MainActor [weak self] in
                    self?.didTerminate(process: process)
                }
            }

            try process.run()
            mountProcess = process
            outputPipe = pipe
            activeConfiguration = configuration

            try await waitForMount(at: configuration.mountPoint, process: process)
            guard process.isRunning else {
                throw MountError.processExited(readProcessOutput())
            }

            state = .mounted(configuration.mountPoint)
        } catch {
            cleanUpAfterFailure()
            state = stateFor(error: error)
        }
    }

    func unmount() async {
        guard let configuration = activeConfiguration else {
            state = .waitingForAndroid
            return
        }

        state = .mounting
        requestUnmount(at: configuration.mountPoint)
        for _ in 0..<20 where isMountPoint(configuration.mountPoint) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if isMountPoint(configuration.mountPoint) {
            state = .failed("Finder 卷卸载失败，请先关闭正在使用该卷的文件。")
        } else {
            clearProcessState()
            state = .waitingForAndroid
        }
    }

    func openFinder() {
        guard case .mounted(let url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    private func bundledHelperURL() -> URL? {
        Bundle.main.url(forResource: "aft-mtp-mount", withExtension: nil, subdirectory: "FinderMount")
    }

    private func unavailableReason() -> String? {
        guard fileManager.fileExists(atPath: Self.macFUSEFileSystemURL.path),
              fileManager.fileExists(atPath: Self.macFUSELibraryURL.path) else {
            return "需要安装并批准 macFUSE。"
        }
        guard let helperURL = bundledHelperURL(), fileManager.isExecutableFile(atPath: helperURL.path) else {
            return "DroidMount 未包含挂载助手，请重新构建应用。"
        }
        return nil
    }

    private func waitForMount(at mountPoint: URL, process: Process) async throws {
        for _ in 0..<150 {
            guard process.isRunning else {
                throw MountError.processExited(readProcessOutput())
            }
            if isMountPoint(mountPoint) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MountError.timedOut
    }

    private func isMountPoint(_ url: URL) -> Bool {
        var fileSystem = statfs()
        let result = url.path.withCString { statfs($0, &fileSystem) }
        guard result == 0 else { return false }
        let capacity = MemoryLayout.size(ofValue: fileSystem.f_mntonname)
        let mountedPath = withUnsafePointer(to: &fileSystem.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        return mountedPath == url.path
    }

    private func requestUnmount(at mountPoint: URL) {
        if let pendingUnmountProcess, pendingUnmountProcess.isRunning {
            return
        }

        let unmount = Process()
        unmount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        unmount.arguments = [mountPoint.path]
        try? unmount.run()
        pendingUnmountProcess = unmount
        if let mountProcess, mountProcess.isRunning {
            mountProcess.terminate()
        }
    }

    private func unmountSynchronously() {
        guard let configuration = activeConfiguration else { return }
        requestUnmount(at: configuration.mountPoint)
        clearProcessState()
    }

    private func didTerminate(process: Process) {
        guard mountProcess === process else { return }
        let output = readProcessOutput()
        clearProcessState()
        if state == .mounting || state.isMounted {
            state = output.isEmpty ? .waitingForAndroid : stateFor(output: output)
        }
    }

    private func cleanUpAfterFailure() {
        if let mountProcess, mountProcess.isRunning {
            mountProcess.terminate()
        }
        clearProcessState()
    }

    private func clearProcessState() {
        mountProcess = nil
        outputPipe = nil
        activeConfiguration = nil
        if let pendingUnmountProcess, !pendingUnmountProcess.isRunning {
            self.pendingUnmountProcess = nil
        }
    }

    private func readProcessOutput() -> String {
        guard let outputPipe,
              let data = try? outputPipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else { return "" }
        return String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    private func stateFor(error: Error) -> MountState {
        if let error = error as? MountError,
           case .processExited(let output) = error {
            return stateFor(output: output)
        }
        if let error = error as? MountError,
           case .timedOut = error {
            return .failed("等待 Android 挂载超时。请确认手机已解锁并选择“文件传输 / MTP”。")
        }
        return .failed(error.localizedDescription)
    }

    private func stateFor(output: String) -> MountState {
        let normalized = output.lowercased()
        if normalized.isEmpty || normalized.contains("no mtp device") || normalized.contains("device not found") {
            return .waitingForAndroid
        }
        return .failed("挂载失败：\(output)")
    }
}

private enum MountError: Error {
    case timedOut
    case processExited(String)
}
