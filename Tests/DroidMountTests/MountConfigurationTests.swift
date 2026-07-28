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
