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

@Test
func deviceFilterRestrictsTheHelperToOnePhone() {
    let base = URL(fileURLWithPath: "/tmp/droid-mount", isDirectory: true)
    let configuration = MountConfiguration.make(baseDirectory: base, deviceFilter: "2717:ff48")

    let index = configuration.arguments.firstIndex(of: "-D")
    #expect(index != nil)
    if let index {
        #expect(configuration.arguments[index + 1] == "2717:ff48")
    }
    #expect(configuration.arguments.last == configuration.mountPoint.path)
    #expect(configuration.mountPoint == MountConfiguration.mountPoint(baseDirectory: base))
}

@Test
func helperFilterIsZeroPaddedHex() {
    let device = MTPDevice(registryID: 1, vendorID: 0x2717, productID: 0xff48, name: "Xiaomi 17 Pro")
    #expect(device.helperFilter == "2717:ff48")
    let legacy = MTPDevice(registryID: 2, vendorID: 0x18d1, productID: 0x4ee1, name: "Pixel")
    #expect(legacy.helperFilter == "18d1:4ee1")
    #expect(MTPDevice(registryID: 3, vendorID: 0x5c6, productID: 0x9039, name: "").helperFilter == "05c6:9039")
}

@Test
func onlyInterfacesNamedMTPCount() {
    #expect(MTPDevice.isMTPInterface(named: "MTP"))
    #expect(MTPDevice.isMTPInterface(named: "mtp"))
    #expect(MTPDevice.isMTPInterface(named: "Android MTP Interface"))
    // PTP cameras and iPhones share USB class 6/1/1 with Android's MTP interface.
    #expect(!MTPDevice.isMTPInterface(named: "PTP"))
    #expect(!MTPDevice.isMTPInterface(named: "ADB Interface"))
    #expect(!MTPDevice.isMTPInterface(named: nil))
}

@Test
func outputTailKeepsOnlyTheLastBytes() {
    let tail = OutputTail(limit: 8)
    tail.append(Data("0123456789".utf8))
    #expect(tail.text == "23456789")
    tail.append(Data("ab".utf8))
    #expect(tail.text == "456789ab")
}

@Test
func mountTableReadsTheKernelTable() throws {
    #expect(MountTable.isMounted(URL(fileURLWithPath: "/")))

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmount-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!MountTable.isMounted(directory))
}
