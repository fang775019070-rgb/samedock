import AppKit
import ApplicationServices

@MainActor
final class PrivacySettingsViewController: NSViewController {
    private let preferences: PreferencesStore
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var hasStarted = false
    var onFinish: (() -> Void)?
    private var card: PermissionCardView { view as! PermissionCardView }
    private var access: PermissionSetupAccess {
        let accessibility = AXIsProcessTrusted()
        let capture = NativeDockContentSync.shared.captureAuthorization
        let supported: Bool
        if #available(macOS 14.0, *) { supported = true } else { supported = false }
        return PermissionSetupAccess(accessibilityGranted: accessibility, capturePreflightGranted: capture == .granted,
            captureRejected: capture == .rejected,
            thumbnailsSupported: supported)
    }

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        view = PermissionCardView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
        card.onContinue = { [weak self] in self?.continueSetup() }
        hasStarted = preferences.permissionSetupPending
        for name in [NSApplication.didBecomeActiveNotification, .echoDockPreferencesDidChange, .sameDockCaptureHealthDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    override func viewDidDisappear() {
        timer?.invalidate()
        timer = nil
        super.viewDidDisappear()
    }

    func refresh() {
        guard isViewLoaded else { return }
        NativeDockContentSync.shared.refreshAuthorization()
        let access = access
        let accessibility = access.accessibilityGranted
        let capture = access.captureGranted
        let supported = access.thumbnailsSupported
        let granted = access.complete
        let enabled = preferences.nativeDockSyncEnabled && preferences.nativeThumbnailsEnabled
        let sync = NativeDockContentSync.shared
        let action: String
        let note: String
        if granted {
            action = enabled ? (supported && sync.captureSetupValidation == .pending ? "setup.checking" : "setup.finish") : "setup.enable"
            if sync.captureSetupValidation != .pending || !supported {
                if preferences.permissionSetupPending { preferences.permissionSetupPending = false }
            }
            if !supported { note = "setup.unsupported" }
            else if !enabled { note = "setup.note" }
            else {
                switch sync.captureHealth {
                case .ready: note = "setup.ready"
                case .noWindows: note = "setup.noWindows"
                case .paused: note = "setup.waitingDisplay"
                default: note = "setup.syncing"
                }
            }
        } else if accessibility && sync.captureAuthorization == .needsRelaunch {
            action = "setup.openCaptureSettings"
            note = "setup.needsRelaunch"
        } else if accessibility && sync.captureAuthorization == .rejected {
            action = "setup.openCaptureSettings"
            note = "setup.captureRejected"
        } else if !hasStarted {
            action = "setup.begin"
            note = "setup.note"
        } else {
            action = accessibility ? "setup.continueCapture" : "setup.continueAccessibility"
            note = accessibility ? "setup.captureNotActive" : "setup.waitingPermission"
        }
        card.update(accessibilityGranted: accessibility, captureGranted: capture,
                    status: L10n.text(note), action: L10n.text(action), actionEnabled: action != "setup.checking")

        if access.shouldDismissWelcome(isWelcome: onFinish != nil, enabled: enabled,
            visible: view.window?.isVisible == true, captureValidation: sync.captureSetupValidation) {
            preferences.hasSeenWelcome = true
            preferences.permissionSetupPending = false
            onFinish?()
            return
        }

        // Only a setup explicitly started by the user may advance to its second
        // permission. Returning to SameDock continues the same flow once.
        if access.shouldAdvanceCapture(started: hasStarted, active: NSApp.isActive,
            visible: view.window?.isVisible == true, requested: preferences.permissionSetupCaptureRequested) {
            preferences.permissionSetupCaptureRequested = true
            requestCapture(access)
        }
    }

    private func continueSetup() {
        hasStarted = true
        preferences.hasSeenWelcome = true
        preferences.nativeDockSyncEnabled = true
        preferences.nativeThumbnailsEnabled = true
        let access = access
        if !access.accessibilityGranted {
            preferences.permissionSetupPending = true
            preferences.permissionSetupCaptureRequested = false
            AccessibilityPermissionService().requestIfNeeded()
            openPrivacy("Privacy_Accessibility")
        } else if access.thumbnailsSupported && !access.captureGranted {
            preferences.permissionSetupPending = true
            preferences.permissionSetupCaptureRequested = true
            requestCapture(access)
        } else {
            if access.thumbnailsSupported && NativeDockContentSync.shared.captureSetupValidation == .pending {
                NativeDockContentSync.shared.refresh()
                refresh()
                return
            }
            preferences.permissionSetupPending = false
            NativeDockContentSync.shared.refresh()
            if let onFinish { onFinish() } else { view.window?.close() }
        }
        refresh()
    }

    private func requestCapture(_ access: PermissionSetupAccess) {
        if access.captureRejected || NativeDockContentSync.shared.captureAuthorization == .needsRelaunch {
            openPrivacy("Privacy_ScreenCapture")
        }
        else { NativeDockContentSync.shared.requestScreenCapture() }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
