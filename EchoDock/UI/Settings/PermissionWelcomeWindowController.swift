import AppKit

@MainActor
final class PermissionWelcomeWindowController: NSWindowController, NSWindowDelegate {
    init(preferences: PreferencesStore) {
        let controller = PrivacySettingsViewController(preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "SameDock"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        super.init(window: window)
        window.delegate = self
        controller.onFinish = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
