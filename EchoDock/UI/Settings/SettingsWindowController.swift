import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let privacyViewController: PrivacySettingsViewController
    private let tabController = NSTabViewController()
    private let generalViewController: GeneralSettingsViewController
    private let appearanceViewController: AppearanceSettingsViewController
    private let displaysViewController: DisplaysSettingsViewController
    private var hasCenteredWindow = false

    init(
        preferences: PreferencesStore,
        displayCoordinator: DisplayCoordinator,
        nativeDockPolicyController: NativeDockPolicyController
    ) {
        privacyViewController = PrivacySettingsViewController(preferences: preferences)
        generalViewController = GeneralSettingsViewController(preferences: preferences)
        appearanceViewController = AppearanceSettingsViewController(preferences: preferences)
        displaysViewController = DisplaysSettingsViewController(
            preferences: preferences,
            displayCoordinator: displayCoordinator,
            nativeDockPolicyController: nativeDockPolicyController
        )

        tabController.tabStyle = .toolbar

        let generalTitle = L10n.text("settings.general.title")
        let generalItem = NSTabViewItem(viewController: generalViewController)
        generalItem.label = generalTitle
        generalItem.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: generalTitle
        )

        let appearanceTitle = L10n.text("settings.appearance.title")
        let appearanceItem = NSTabViewItem(viewController: appearanceViewController)
        appearanceItem.label = appearanceTitle
        appearanceItem.image = NSImage(
            systemSymbolName: "paintbrush",
            accessibilityDescription: appearanceTitle
        )

        let displaysTitle = L10n.text("settings.displays.tabTitle")
        let displaysItem = NSTabViewItem(viewController: displaysViewController)
        displaysItem.label = displaysTitle
        displaysItem.image = NSImage(
            systemSymbolName: "display.2",
            accessibilityDescription: displaysTitle
        )

        tabController.addTabViewItem(generalItem)
        tabController.addTabViewItem(appearanceItem)
        tabController.addTabViewItem(displaysItem)
        let privacyItem = NSTabViewItem(viewController: privacyViewController)
        privacyItem.label = L10n.text("privacy.title")
        privacyItem.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: privacyItem.label)
        tabController.addTabViewItem(privacyItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("settings.window.title")
        window.contentViewController = tabController
        window.contentMinSize = NSSize(width: 620, height: 560)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showPrivacy() {
        tabController.selectedTabViewItemIndex = 3
        show()
    }

    func show() {
        if !hasCenteredWindow {
            window?.center()
            hasCenteredWindow = true
        }
        generalViewController.refresh()
        appearanceViewController.refresh()
        displaysViewController.refresh()
        privacyViewController.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
