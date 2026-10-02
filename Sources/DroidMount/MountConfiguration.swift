import Foundation

/// A single Android MTP device is presented to Finder as one writable volume.
struct MountConfiguration: Equatable, Sendable {
    /// Bytes per FUSE read/write request handed to the mount helper.
    static let readWriteBlockSize = 1024 * 1024
    static let volumeName = "DroidMount Android"

    let mountPoint: URL
    let volumeName: String
    let arguments: [String]

    static func mountPoint(baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("DroidMount", isDirectory: true)
            .appendingPathComponent("Mounts", isDirectory: true)
            .appendingPathComponent("Android", isDirectory: true)
    }

    /// `deviceFilter` is a `vid:pid` pair restricting the helper to one USB device; without
    /// it the helper probes every device on the bus and takes the first MTP one.
    static func make(baseDirectory: URL, deviceFilter: String? = nil) -> MountConfiguration {
        let mountPoint = mountPoint(baseDirectory: baseDirectory)
        var arguments: [String] = []
        if let deviceFilter {
            arguments += ["-D", deviceFilter]
        }
        arguments += [
            "-f",
            "-o", "rw",
            "-o", "volname=\(volumeName)",
            // Every FUSE read becomes one MTP transaction, so the request size sets
            // how many round trips a copy costs. macFUSE's default caps reads well
            // below what the device can stream; 1 MiB measured ~30% faster on an
            // MTP phone than the default.
            "-o", "iosize=\(readWriteBlockSize)",
            // Finder otherwise writes an AppleDouble sidecar next to every file it
            // touches, doubling the transaction count for metadata nobody reads back.
            // The helper accepts and drops extended attributes instead
            // (patches/0002-fuse-accept-xattrs.patch), without which this option makes
            // copies of quarantined files arrive empty.
            "-o", "noappledouble",
            mountPoint.path,
        ]
        return MountConfiguration(mountPoint: mountPoint, volumeName: volumeName, arguments: arguments)
    }
}
