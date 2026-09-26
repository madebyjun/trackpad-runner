import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runner = LiveRunner()
    private var statusItem: NSStatusItem?
    private let toggleItem = NSMenuItem(title: "有効", action: #selector(toggle), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runner.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "trackpad-runner を開始できませんでした"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "trackpad-runner")

        let menu = NSMenu()
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func toggle() {
        runner.isEnabled.toggle()
        toggleItem.state = runner.isEnabled ? .on : .off
        statusItem?.button?.appearsDisabled = !runner.isEnabled
    }
}
