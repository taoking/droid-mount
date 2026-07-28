import Foundation

/// A single Android MTP device is presented to Finder as one writable volume.
struct MountConfiguration: Equatable, Sendable {
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
                mountPoint.path,
            ]
        )
    }
}
