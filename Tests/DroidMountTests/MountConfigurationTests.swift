import Foundation
import Testing
@testable import DroidMount

@Test
func writableMountUsesStableFinderVolumeArguments() {
    let configuration = MountConfiguration.make(
        baseDirectory: URL(fileURLWithPath: "/tmp/droid-mount", isDirectory: true)
    )

    #expect(configuration.mountPoint.path == "/tmp/droid-mount/DroidMount/Mounts/Android")
    #expect(configuration.volumeName == "DroidMount Android")
    #expect(configuration.arguments.contains("-f"))
    #expect(configuration.arguments.contains("rw"))
    #expect(!configuration.arguments.contains("ro"))
    #expect(!configuration.arguments.contains("-D"))
    #expect(configuration.arguments.last == configuration.mountPoint.path)
}

@Test
func writableMountRequestsLargeIOAndSkipsAppleDouble() {
    let configuration = MountConfiguration.make(
        baseDirectory: URL(fileURLWithPath: "/tmp/droid-mount", isDirectory: true)
    )

    // Each FUSE read costs one MTP transaction, so the request size drives copy speed.
    #expect(configuration.arguments.contains("iosize=1048576"))
    #expect(configuration.arguments.contains("noappledouble"))

    // Options only count when the helper sees them as "-o <value>" pairs.
    for option in ["rw", "iosize=1048576", "noappledouble"] {
        let index = configuration.arguments.firstIndex(of: option)
        #expect(index != nil)
        if let index {
            #expect(index > 0)
            #expect(configuration.arguments[index - 1] == "-o")
        }
    }
}
