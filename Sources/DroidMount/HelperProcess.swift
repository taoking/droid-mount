import Darwin
import Foundation

/// Keeps the last few KiB of the helper's output for error messages.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()

    init(limit: Int = 8 * 1024) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// One running aft-mtp-mount, with its output drained as it arrives.
///
/// The helper's stdout and stderr share a pipe. Left unread, the pipe fills at 64 KiB of
/// log output and the helper blocks in write(2) inside whatever FUSE request it is
/// serving, which hangs the whole volume.
final class HelperProcess: @unchecked Sendable {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let process = Process()
    private let output = OutputTail()
    private let outputClosed = DispatchSemaphore(value: 0)
    private let timedOut = Flag()

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
    }

    var isRunning: Bool { process.isRunning }

    /// Launches the helper. `onExit` runs once, on a background queue.
    func start(onExit: @escaping @Sendable (HelperExit) -> Void) throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [output, outputClosed] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outputClosed.signal()
            } else {
                output.append(chunk)
            }
        }
        process.terminationHandler = { [output, outputClosed, timedOut] process in
            // Let the reader reach end-of-file so the message includes the final lines.
            _ = outputClosed.wait(timeout: .now() + 0.5)
            if timedOut.isSet {
                onExit(.timedOut)
            } else if process.terminationReason == .exit && process.terminationStatus == 0 {
                onExit(.unmounted)
            } else {
                onExit(.failed(output.text))
            }
        }
        try process.run()
    }

    /// Stops a helper that never produced a volume; its exit is reported as a timeout.
    func stopAfterTimeout() {
        timedOut.set()
        terminate()
    }

    /// Sends SIGTERM, which ends the FUSE session cleanly, and SIGKILL if the helper is
    /// still stuck in a USB call a few seconds later.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Blocks until the helper exits or `timeout` passes. Only for application shutdown.
    func waitForExit(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
