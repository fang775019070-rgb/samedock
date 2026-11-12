import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore.shared
    private var modelController: DockModelController?
    private var displayCoordinator: DisplayCoordinator?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var welcomeWindowController: PermissionWelcomeWindowController?
    private var nativeDockPolicyController: NativeDockPolicyController?
    private var windowReservationService: WindowReservationService?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()

        let iconProvider = ApplicationIconProvider.shared
        iconProvider.startObservingApplicationLaunches()
        let modelController = DockModelController(preferences: preferences, nativeContentSync: .shared)
        let fileUndoAction = FileUndoMenuAction(
            isAvailable: { [weak modelController] in modelController?.canUndoFileOperation ?? false },
            perform: { [weak modelController] in modelController?.undoLastFileOperation() }
        )
        modelController.onFileUndoFailure = { message in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("fileUndo.error.title")
            alert.informativeText = message
            alert.addButton(withTitle: L10n.text("fileUndo.error.dismiss"))
            alert.runModal()
        }
        let nativeDockPolicyController = NativeDockPolicyController(preferences: preferences)
        let displayCoordinator = DisplayCoordinator(
            preferences: preferences,
            nativeDockDisplayProvider: { [weak nativeDockPolicyController] in
                nativeDockPolicyController?.currentNativeDockDisplayID
            },
            iconProvider: iconProvider,
            onItemAction: { [weak modelController] item in
                modelController?.performPrimaryAction(for: item)
            },
            onItemContextAction: { [weak modelController] item, action in
                modelController?.performContextAction(action, for: item)
            },
            contextMenuStateProvider: { [weak modelController] item in
                modelController?.contextMenuState(for: item) ?? .unavailable
            },
            onDropRequest: { [weak modelController] request in
                modelController?.handleDrop(request) ?? false
            },
            fileUndoAction: fileUndoAction
        )
        let windowReservationService = WindowReservationService(
            preferences: preferences,
            snapRegionsProvider: { [weak displayCoordinator] in
                displayCoordinator?.windowSnapRegions ?? []
            }
        )
        displayCoordinator.onContentAvailabilityChange = { NativeDockContentSync.shared.setDisplayAvailability($0) }
        displayCoordinator.onTopologyChange = { [weak nativeDockPolicyController] _ in
            nativeDockPolicyController?.reconcile()
        }
        nativeDockPolicyController.onProtectedEdgePointerMotion = {
            [weak displayCoordinator] location, pressedButtons in
            displayCoordinator?.processMouse(
                location: location,
                pressedButtons: pressedButtons
            )
        }

        let settingsWindowController = SettingsWindowController(
            preferences: preferences,
            displayCoordinator: displayCoordinator,
            nativeDockPolicyController: nativeDockPolicyController
        )
        let statusItemController = StatusItemController(
            preferences: preferences,
            onOpenSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            },
            onRefresh: { [weak modelController, weak displayCoordinator, weak nativeDockPolicyController] in
                modelController?.refresh()
                displayCoordinator?.rebuildPanels()
                nativeDockPolicyController?.reconcile()
            },
            fileUndoAction: fileUndoAction
        )

        modelController.onSnapshotChange = { [weak displayCoordinator, weak statusItemController] snapshot in
            displayCoordinator?.apply(snapshot: snapshot)
            statusItemController?.update(snapshot: snapshot)
        }

        self.modelController = modelController
        self.displayCoordinator = displayCoordinator
        self.statusItemController = statusItemController
        self.settingsWindowController = settingsWindowController
        self.nativeDockPolicyController = nativeDockPolicyController
        self.windowReservationService = windowReservationService

        observeAppActions()
        observeWorkspaceLifecycle()
        nativeDockPolicyController.start()
        displayCoordinator.start()
        windowReservationService.start()
        modelController.start()
        displayCoordinator.apply(snapshot: modelController.snapshot)
        statusItemController.update(snapshot: modelController.snapshot)
        displayCoordinator.setItemAnimationsEnabled(true)
        let thumbnailsSupported: Bool
        if #available(macOS 14.0, *) { thumbnailsSupported = true } else { thumbnailsSupported = false }
        let setupAccess = PermissionSetupAccess(accessibilityGranted: AXIsProcessTrusted(),
            capturePreflightGranted: NativeDockContentSync.shared.screenCaptureGranted,
            captureRejected: false, thumbnailsSupported: thumbnailsSupported)
        if setupAccess.shouldPresent(hasSeenWelcome: preferences.hasSeenWelcome, pending: preferences.permissionSetupPending,
                                     enabled: preferences.isEnabled, syncEnabled: preferences.nativeDockSyncEnabled) {
            let welcome = PermissionWelcomeWindowController(preferences: preferences)
            welcomeWindowController = welcome
            welcome.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelController?.stop()
        windowReservationService?.stop()
        nativeDockPolicyController?.stop()
        displayCoordinator?.stop()
        ApplicationIconProvider.shared.stopObservingApplicationLaunches()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        windowReservationService?.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        if windowReservationService == nil { return .terminateNow }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcome = welcomeWindowController, welcome.window?.isVisible == true {
            welcome.window?.makeKeyAndOrderFront(nil)
        } else {
            settingsWindowController?.show()
        }
        return false
    }

    private func configureMainMenu() {
        // A status-item menu alone does not dispatch keyboard equivalents from
        // settings windows. Keep the standard application commands available.
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "SameDock")
        let about = NSMenuItem(title: L10n.text("statusItem.about"), action: #selector(showAboutFromMainMenu), keyEquivalent: "")
        about.target = self
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("statusItem.settings"), action: #selector(showSettingsFromMainMenu), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("statusItem.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("menu.window"))
        windowMenu.addItem(NSMenuItem(title: L10n.text("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsFromMainMenu() {
        settingsWindowController?.show()
    }

    @objc private func showAboutFromMainMenu() {
        statusItemController?.showAboutWindow()
    }

    private func observeWorkspaceLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.modelController?.refresh()
                    self?.displayCoordinator?.rebuildPanels()
                }
            }
        }
    }

    private func observeAppActions() {
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: .echoDockOpenPrivacyRequest, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.settingsWindowController?.showPrivacy() }
            },
            center.addObserver(
                forName: .echoDockOpenSettingsRequest,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.settingsWindowController?.show()
                }
            },
            center.addObserver(
                forName: .echoDockShowAboutRequest,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.statusItemController?.showAboutWindow()
                }
            },
            center.addObserver(
                forName: .echoDockQuitRequest,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        ]
    }
}

extension Notification.Name {
    static let echoDockOpenPrivacyRequest = Notification.Name("Docklune.openPrivacy")
}
