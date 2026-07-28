import Foundation
import IOKit
import IOKit.usb

/// Watches USB topology changes. The mount helper performs the final MTP
/// handshake, so this monitor deliberately does not keep its own MTP session.
@MainActor
final class USBDeviceMonitor: @unchecked Sendable {
    private let onChange: () -> Void
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var isWatching = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isWatching, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }

        notificationPort = port
        isWatching = true
        runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        register(notification: kIOPublishNotification, iterator: &addedIterator)
        register(notification: kIOTerminatedNotification, iterator: &removedIterator)

        drain(addedIterator)
        drain(removedIterator)
        onChange()
    }

    func stop() {
        guard isWatching || notificationPort != nil || addedIterator != 0 || removedIterator != 0 else { return }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        isWatching = false
    }

    private func register(notification: String, iterator: inout io_iterator_t) {
        guard let notificationPort,
              let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return }

        let reference = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = notification.withCString { notificationPointer in
            IOServiceAddMatchingNotification(
                notificationPort,
                notificationPointer,
                matching,
                { reference, iterator in
                    guard let reference else { return }
                    let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(reference).takeUnretainedValue()
                    Task { @MainActor in
                        monitor.drain(iterator)
                        monitor.onChange()
                    }
                },
                reference,
                &iterator
            )
        }

        if result != kIOReturnSuccess {
            iterator = 0
        }
    }

    private func drain(_ iterator: io_iterator_t) {
        guard iterator != 0 else { return }
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
