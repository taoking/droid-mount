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
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Items are enabled by hand; auto-enabling would turn on every item with a target.
        menu.autoenablesItems = false
        menu.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        mountController.onStateChange = { [weak self] in
            self?.refresh()
        }
        mountController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mountController.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // macFUSE may have been installed or approved since launch.
        mountController.refreshAvailability()
        rebuildMenu()
    }

    @objc private func mountNow() {
        mountController.mountNow()
    }

    @objc private func openFinder() {
        mountController.openFinder()
    }

    @objc private func eject() {
        mountController.unmount()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        let status = mountController.statusText.replacingOccurrences(of: "\n", with: " ")
        statusItem?.button?.toolTip = "DroidMount：\(status)"
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "DroidMount")
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for line in mountController.statusText.split(separator: "\n") {
            menu.addItem(withTitle: String(line), action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())

        switch mountController.lifecycle.phase {
        case .mounted:
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(openFinder), keyEquivalent: "o")
            menu.addItem(withTitle: "推出", action: #selector(eject), keyEquivalent: "e")
        case .mounting, .unmounting:
            break
        case .idle:
            let item = menu.addItem(withTitle: "立即挂载", action: #selector(mountNow), keyEquivalent: "m")
            item.isEnabled = mountController.unavailableReason == nil
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DroidMount", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    private var iconName: String {
        switch mountController.lifecycle.phase {
        case .mounted:
            return "externaldrive.connected.to.line.below.fill"
        case .mounting, .unmounting:
            return "arrow.triangle.2.circlepath"
        case .idle:
            return "externaldrive.badge.xmark"
        }
    }
}
