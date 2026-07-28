import AppKit

@main
struct DroidMountApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let mountController = MountController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "DroidMount")
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item

        mountController.onStateChange = { [weak self] _ in
            self?.refreshMenu()
        }
        refreshMenu()
        mountController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mountController.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    @objc private func mountNow() {
        mountController.mountIfNeeded()
    }

    @objc private func openFinder() {
        mountController.openFinder()
    }

    @objc private func unmount() {
        Task { await mountController.unmount() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        statusItem.button?.toolTip = "DroidMount：\(mountController.state.statusText)"
        statusItem.button?.image = icon(for: mountController.state)

        let menu = NSMenu()
        let stateItem = menu.addItem(withTitle: mountController.state.statusText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(.separator())

        switch mountController.state {
        case .mounted:
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(openFinder), keyEquivalent: "o")
            menu.addItem(withTitle: "卸载 Finder", action: #selector(unmount), keyEquivalent: "e")
        case .mounting:
            break
        case .waitingForAndroid, .failed, .unavailable:
            let item = menu.addItem(withTitle: "立即挂载", action: #selector(mountNow), keyEquivalent: "m")
            item.isEnabled = !isUnavailable
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DroidMount", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private var isUnavailable: Bool {
        if case .unavailable = mountController.state { return true }
        return false
    }

    private func icon(for state: MountState) -> NSImage? {
        let name: String
        switch state {
        case .mounted:
            name = "externaldrive.connected.to.line.below.fill"
        case .mounting:
            name = "arrow.triangle.2.circlepath"
        case .waitingForAndroid, .failed, .unavailable:
            name = "externaldrive.badge.xmark"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "DroidMount")
    }
}
