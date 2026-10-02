import Foundation

/// A single Android MTP device is presented to Finder as one writable volume.
struct MountConfiguration: Equatable, Sendable {
    /// Bytes per FUSE read/write request handed to the mount helper.
    static let readWriteBlockSize = 1024 * 1024

    let mountPoint: URL
    let volumeName: String
    let arguments: [String]

    static func make(baseDirectory: URL) -> MountConfiguration {
        let mountPoint = baseDirectory
            .appendingPathComponent("DroidMount", isDirectory: true)
            .appendingPathComponent("Mounts", isDirectory: true)
            .appendingPathComponent("Android", isDirectory: true)
        let volumeName = "DroidMount Android"

        return MountConfiguration(
            mountPoint: mountPoint,
            volumeName: volumeName,
            arguments: [
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
                "-o", "noappledouble",
                mountPoint.path,
            ]
        )
    }
}
