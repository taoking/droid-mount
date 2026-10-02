import Foundation
import IOKit
import IOKit.usb

/// A phone exposing its MTP interface on the USB bus.
struct MTPDevice: Equatable, Sendable {
    /// Registry entry ID of the interface; stable while it stays on the bus.
    let registryID: UInt64
    let vendorID: Int
    let productID: Int
    let name: String

    /// The `-D vid:pid` filter for aft-mtp-mount. Without it the helper opens every USB
    /// device on the Mac and sends each one descriptor requests until one answers like an
    /// MTP device.
    var helperFilter: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// Android names its MTP interface "MTP" - USB class 6/1/1 on current releases,
    /// vendor-specific on older ones. Cameras and iPhones share class 6/1/1 for PTP, so the
    /// class alone would claim them too.
    static func isMTPInterface(named name: String?) -> Bool {
        name?.range(of: "MTP", options: .caseInsensitive) != nil
    }
}

/// Watches the IORegistry for MTP interfaces appearing and disappearing.
///
/// It only reads registry properties: no device is opened and no USB request is sent, so
/// nothing else on the bus notices it. The mount helper performs the MTP handshake.
@MainActor
final class USBDeviceMonitor {
    private let onChange: ([MTPDevice]) -> Void
    private var notificationPort: IONotificationPortRef?
    private var appearedIterator: io_iterator_t = 0
    private var disappearedIterator: io_iterator_t = 0
    private var devices: [UInt64: MTPDevice] = [:]

    init(onChange: @escaping ([MTPDevice]) -> Void) {
        self.onChange = onChange
    }

    /// Starts watching and reports the devices already present before returning.
    func start() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        // Callbacks arrive on the main run loop, which is what makes assumeIsolated sound.
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let reference = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"), { reference, iterator in
            guard let reference else { return }
            MainActor.assumeIsolated {
                Unmanaged<USBDeviceMonitor>.fromOpaque(reference).takeUnretainedValue().interfacesAppeared(iterator)
            }
        }, reference, &appearedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostInterface"), { reference, iterator in
            guard let reference else { return }
            MainActor.assumeIsolated {
                Unmanaged<USBDeviceMonitor>.fromOpaque(reference).takeUnretainedValue().interfacesDisappeared(iterator)
            }
        }, reference, &disappearedIterator)

        // Draining both iterators lists what is already attached and arms the notifications.
        interfacesAppeared(appearedIterator, reportAlways: true)
        interfacesDisappeared(disappearedIterator)
    }

    func stop() {
        if let notificationPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(), .commonModes)
        }
        for iterator in [appearedIterator, disappearedIterator] where iterator != 0 {
            IOObjectRelease(iterator)
        }
        appearedIterator = 0
        disappearedIterator = 0
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        devices = [:]
    }

    private func interfacesAppeared(_ iterator: io_iterator_t, reportAlways: Bool = false) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let device = Self.mtpDevice(for: service) {
                devices[device.registryID] = device
                changed = true
            }
            IOObjectRelease(service)
        }
        if changed || reportAlways {
            report()
        }
    }

    private func interfacesDisappeared(_ iterator: io_iterator_t) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            var registryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
               devices.removeValue(forKey: registryID) != nil {
                changed = true
            }
            IOObjectRelease(service)
        }
        if changed {
            report()
        }
    }

    private func report() {
        onChange(devices.values.sorted { $0.registryID < $1.registryID })
    }

    private static func mtpDevice(for service: io_service_t) -> MTPDevice? {
        guard isMTPInterface(service) else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
              let vendorID: Int = property(service, "idVendor"),
              let productID: Int = property(service, "idProduct") else { return nil }
        let name: String = property(service, "USB Product Name") ?? "Android"
        return MTPDevice(registryID: registryID, vendorID: vendorID, productID: productID, name: name)
    }

    private static func isMTPInterface(_ service: io_service_t) -> Bool {
        MTPDevice.isMTPInterface(named: property(service, "kUSBString"))
    }

    private static func property<Value>(_ service: io_service_t, _ key: String) -> Value? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Value
    }
}
