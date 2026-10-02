import Darwin
import Foundation

/// Reads the kernel's mount table without calling into any file system.
///
/// statfs(2) on a FUSE mount is a round trip to its daemon - for aft-mtp-mount an MTP
/// transaction that waits behind any transfer in flight, and never returns if the phone
/// stops answering. A dead mount, on the other hand, still answers statfs with made-up
/// numbers. getfsstat(MNT_NOWAIT) only reports what the kernel already knows.
enum MountTable {
    static func isMounted(_ url: URL) -> Bool {
        mountedPaths().contains(url.path)
    }

    static func mountedPaths() -> Set<String> {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Leave room for mounts that appear between the two calls.
        var entries = Array<statfs>(repeating: statfs(), count: Int(count) + 4)
        let filled = entries.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return Set(entries.prefix(Int(filled)).map { entry in
            withUnsafeBytes(of: entry.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        })
    }
}
