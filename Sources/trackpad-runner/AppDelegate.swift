import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runner = LiveRunner()
    private var statusItem: NSStatusItem?
    private let toggleItem = NSMenuItem(title: "有効", action: #selector(toggle), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "アクセシビリティ権限がありません（許可すると再開します）", action: nil, keyEquivalent: "")
    private let openSettingsItem = NSMenuItem(title: "システム設定を開く…", action: #selector(openAccessibilitySettings), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner.onPermissionChange = { [weak self] _ in self?.updateState() }
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
        permissionItem.isEnabled = false
        openSettingsItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(openSettingsItem)
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        updateState()
    }

    @objc private func toggle() {
        runner.isEnabled.toggle()
        updateState()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateState() {
        let hasPermission = runner.hasPermission
        permissionItem.isHidden = hasPermission
        openSettingsItem.isHidden = hasPermission
        toggleItem.isHidden = !hasPermission
        toggleItem.state = runner.isEnabled ? .on : .off
        statusItem?.button?.image = NSImage(
            systemSymbolName: hasPermission ? "hand.tap" : "exclamationmark.triangle",
            accessibilityDescription: "trackpad-runner"
        )
        statusItem?.button?.appearsDisabled = !hasPermission || !runner.isEnabled
    }
}
