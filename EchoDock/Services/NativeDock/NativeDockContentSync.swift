import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os

/// A value-only copy of the system Dock. AX references stay on the worker queue.
struct NativeDockEntry: Equatable {
    let id: String
    let title: String
    let subrole: String
    let url: URL?
    let badge: String?
    let running: Bool
    let frame: CGRect

    var isWindow: Bool { subrole == "AXMinimizedWindowDockItem" }
    var isApplication: Bool { subrole == "AXApplicationDockItem" }
    var isTrash: Bool { subrole == "AXTrashDockItem" }
}

private final class NativeDockContentReader {
    private var elements: [String: AXUIElement] = [:]
    private var nextID: UInt64 = 0
    private var dockPID: pid_t = 0
    private var deadline: TimeInterval = 0

    func read() -> [NativeDockEntry]? {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            elements.removeAll()
            return nil
        }
        deadline = ProcessInfo.processInfo.systemUptime + 0.7
        if dockPID != dock.processIdentifier {
            elements.removeAll()
            dockPID = dock.processIdentifier
        }
        let application = AXUIElementCreateApplication(dockPID)
        guard let children = dockItems(in: application, depth: 0), !children.isEmpty else { return nil }
        var updated: [String: AXUIElement] = [:]
        var entries: [NativeDockEntry] = []
        for element in children.prefix(128) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let subrole = value(element, "AXSubrole") as? String,
                  subrole != "AXSeparatorDockItem" else { continue }
            let title = (value(element, "AXTitle") as? String) ?? ""
            let rawURL = value(element, "AXURL")
            let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            let badge = (value(element, "AXStatusLabel") as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let id: String
            if let existing = elements.first(where: { CFEqual($0.value, element) })?.key {
                id = existing
            } else {
                nextID &+= 1
                id = "native:\(dockPID):\(nextID)"
            }
            updated[id] = element
            entries.append(NativeDockEntry(
                id: id, title: title, subrole: subrole, url: url, badge: badge,
                running: (value(element, "AXIsApplicationRunning") as? Bool) ?? false,
                frame: frame(element)
            ))
        }
        elements = updated
        return entries
    }

    func press(_ id: String) -> Bool {
        // Re-read before acting: an expired tile must never activate a replacement.
        guard let expected = elements[id], let live = read(),
              live.contains(where: { $0.id == id }), let current = elements[id],
              CFEqual(expected, current) else { return false }
        AXUIElementSetMessagingTimeout(current, 0.2)
        return AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
    }

    private func dockItems(in element: AXUIElement, depth: Int) -> [AXUIElement]? {
        guard depth < 5, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        if children.contains(where: { (value($0, kAXRoleAttribute) as? String) == "AXDockItem" }) {
            return children
        }
        for child in children.prefix(32) {
            if let items = dockItems(in: child, depth: depth + 1) { return items }
        }
        return nil
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.04, remaining)))
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(_ element: AXUIElement) -> CGRect {
        guard let position = value(element, kAXPositionAttribute),
              let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor
final class NativeDockContentSync {
    static let shared = NativeDockContentSync()
    private static let timingLog = Logger(subsystem: "app.docklune.mac", category: "thumbnail-timing")
    var onChange: (() -> Void)?
    private let reader = AccessibilityWorkQueue(
        backend: NativeDockContentReader(), name: "com.baikaihao.EchoDock.native-content"
    )
    private(set) var entries: [NativeDockEntry] = []
    private var images: [String: NSImage] = [:]
    /// In-memory artwork signatures, only to detect when Dock's tile settles.
    private var fingerprints: [String: NativeDockThumbnail.Fingerprint] = [:]
    /// A differing capture of an already visible window, waiting for a second
    /// matching capture before it may replace the published artwork.
    private var pendingFingerprints: [String: NativeDockThumbnail.Fingerprint] = [:]
    /// Display of the last identified Dock surface; survives soft invalidation.
    private var lastCaptureDisplayID: CGDirectDisplayID?
    /// Artwork of windows that just left Dock, kept only while their slot
    /// collapses so the closing tile never turns into a placeholder glyph.
    private var departingImages: [String: (image: NSImage, since: TimeInterval)] = [:]
    static let departingImageLifetime: TimeInterval = 1.0
    /// When each window's artwork first appeared (in-memory only).
    private var firstPublishedAt: [String: TimeInterval] = [:]
    private var timer: Timer?
    private var captureRetryTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var imageRevision: UInt64 = 0
    private var recovery = NativeDockThumbnailRecoveryPolicy()
    private var captureSource: CaptureSource?
    private var hasReadSnapshot = false
    private var captureAuthorizationRejected = false
    private var captureRequestAccepted = false
    private var hasRequestedCaptureThisSession = false
    private var captureAuthorizationVerified = false
    private var hasCompletedInitialCaptureAttempt = false
    private var previousScreenCaptureGranted = false
    private var publishedCaptureAuthorization: ScreenCaptureAuthorizationStatus = .notGranted
    private var publishedCaptureValidation: PermissionCaptureValidation = .notNeeded
    private(set) var captureHealth: NativeDockCaptureHealth = .paused
    private var failures = 0
    private var trashFull = false
    private var isStarted = false
    private let preferences: PreferencesStore
    private var policy = NativeDockPrivacyPolicy()
    private var preferenceObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    private struct CaptureSource: Equatable {
        let windowID: CGWindowID
        let displayID: CGDirectDisplayID
        let displayFrame: CGRect
    }

    init(preferences: PreferencesStore? = nil) {
        self.preferences = preferences ?? .shared
    }

    var isSynchronizing: Bool { isStarted && policy.mayRead }

    func setDisplayAvailability(_ available: Bool) {
        policy.hasAvailableDisplay = available
        reconcile()
    }

    private func reconcile() {
        let previouslyCapturing = policy.thumbnailsEnabled
        policy.enabled = preferences.nativeDockSyncEnabled
        policy.panelsEnabled = preferences.isEnabled
        policy.thumbnailsEnabled = preferences.nativeThumbnailsEnabled
        guard isStarted else { return }
        if !policy.mayRead {
            suspend()
        } else {
            if previouslyCapturing && !policy.thumbnailsEnabled { clearCapture() }
            if timer == nil {
                // Read lightweight Dock metadata promptly; unchanged images still
                // refresh only every 15 seconds, never at this polling frequency.
                timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                timer?.tolerance = 0.05
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
            refresh()
        }
        updateCaptureHealth()
    }

    private func clearCapture() {
        generation &+= 1
        captureTask?.cancel()
        captureTask = nil
        captureRetryTimer?.invalidate()
        captureRetryTimer = nil
        recovery = NativeDockThumbnailRecoveryPolicy()
        captureSource = nil
        lastCaptureDisplayID = nil
        fingerprints.removeAll()
        firstPublishedAt.removeAll()
        pendingFingerprints.removeAll()
        departingImages.removeAll()
        // Image/source invalidation must not erase an actual permission refusal.
        if !images.isEmpty {
            images.removeAll()
            imageRevision &+= 1
            onChange?()
        }
    }

    private func suspend() {
        timer?.invalidate()
        timer = nil
        reader.cancelAll()
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        failures = 0
        hasReadSnapshot = false
        clearCapture()
        if hadEntries { onChange?() }
        updateCaptureHealth()
    }

    var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    var captureAuthorization: ScreenCaptureAuthorizationStatus {
        .evaluate(preflightGranted: screenCaptureGranted, requestAccepted: captureRequestAccepted,
                  captureRejected: captureAuthorizationRejected)
    }

    var captureSetupValidation: PermissionCaptureValidation {
        let windows = entries.filter(\.isWindow)
        return .evaluate(active: isSynchronizing && policy.thumbnailsEnabled,
            hasReadSnapshot: hasReadSnapshot, windowCount: windows.count,
            capturableWindowCount: windows.filter { $0.frame.width > 4 && $0.frame.height > 4 }.count,
            verified: captureAuthorizationVerified, attemptCompleted: hasCompletedInitialCaptureAttempt)
    }

    private func updateCaptureHealth() {
        let supported: Bool
        if #available(macOS 14.0, *) { supported = true } else { supported = false }
        let windows = entries.filter(\.isWindow)
        let available = windows.filter { images[$0.id] != nil }.count
        let next = NativeDockCaptureHealth.evaluate(
            active: isSynchronizing && policy.thumbnailsEnabled,
            supported: supported,
            permissionGranted: AXIsProcessTrusted() && screenCaptureGranted && !captureAuthorizationRejected,
            hasReadSnapshot: hasReadSnapshot, windowCount: windows.count,
            availableCount: available, retryPending: recovery.retryPending)
        let authorization = captureAuthorization
        let validation = captureSetupValidation
        guard next != captureHealth || authorization != publishedCaptureAuthorization
            || validation != publishedCaptureValidation else { return }
        captureHealth = next
        publishedCaptureAuthorization = authorization
        publishedCaptureValidation = validation
        NotificationCenter.default.post(name: .sameDockCaptureHealthDidChange, object: self)
    }

    private func pruneImages(now: TimeInterval) {
        let validIDs = Set(entries.filter(\.isWindow).map(\.id))
        let removed = recovery.prune(validIDs: validIDs, now: now)
        let previousCount = images.count
        departingImages = Self.departing(images: images, previous: departingImages, validIDs: validIDs, now: now)
        images = images.filter { validIDs.contains($0.key) && !removed.contains($0.key) }
        fingerprints = fingerprints.filter { images[$0.key] != nil }
        pendingFingerprints = pendingFingerprints.filter { images[$0.key] != nil }
        firstPublishedAt = firstPublishedAt.filter { images[$0.key] != nil }
        if images.count != previousCount {
            imageRevision &+= 1
            onChange?()
        }
    }

    /// Screen parameters also change when an app launches or quits and Dock
    /// resizes. Re-identify the Dock surface and recapture, but keep every
    /// published thumbnail: blanking them all is what native Dock never does.
    private func invalidateCaptureSource() {
        generation &+= 1
        captureTask?.cancel()
        captureTask = nil
        captureRetryTimer?.invalidate()
        captureRetryTimer = nil
        captureSource = nil
        updateCaptureHealth()
        refresh()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .echoDockPreferencesDidChange, object: preferences, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        let events: [(Notification.Name, Bool, Bool)] = [
            (NSWorkspace.willSleepNotification, false, false),
            (NSWorkspace.screensDidSleepNotification, false, false),
            (NSWorkspace.didWakeNotification, false, true),
            (NSWorkspace.screensDidWakeNotification, false, true),
            (NSWorkspace.sessionDidResignActiveNotification, true, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true, true)
        ]
        workspaceObservers = events.map { name, isSession, active in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if isSession { self.policy.sessionActive = active }
                    else { self.policy.screenAwake = active }
                    self.reconcile()
                }
            }
        }
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateCaptureSource() }
        })
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        reconcile()
    }

    func stop() {
        isStarted = false
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
        suspend()
    }

    /// Polling authorization never starts capture or prompts. It must also work
    /// while no companion display exists, so a settings change can finish setup.
    @discardableResult
    func refreshAuthorization() -> Bool {
        let captureGranted = screenCaptureGranted
        if captureGranted && !previousScreenCaptureGranted { captureAuthorizationRejected = false }
        if captureGranted {
            captureRequestAccepted = false
        } else {
            captureAuthorizationVerified = false
            hasCompletedInitialCaptureAttempt = false
        }
        previousScreenCaptureGranted = captureGranted
        if !captureGranted, !images.isEmpty || captureTask != nil || captureSource != nil { clearCapture() }
        updateCaptureHealth()
        return captureGranted
    }

    func refresh() {
        let captureGranted = refreshAuthorization()
        guard isSynchronizing else { return }
        if !policy.mayCapture(permissionGranted: captureGranted),
           !images.isEmpty || captureTask != nil || captureSource != nil { clearCapture() }
        pruneImages(now: ProcessInfo.processInfo.systemUptime)
        updateCaptureHealth()
        guard AXIsProcessTrusted() else {
            let hadEntries = !entries.isEmpty
            entries.removeAll()
            hasReadSnapshot = false
            clearCapture()
            if hadEntries { onChange?() }
            updateCaptureHealth()
            return
        }
        guard !reader.contains("read") else { return }
        let expectedGeneration = generation
        synchronizeAppearance()
        reader.submit(key: "read", work: { backend, _ in backend.read() }) { [weak self] result in
            guard let self, self.isSynchronizing, self.generation == expectedGeneration else { return }
            if let result {
                self.failures = 0
                self.hasReadSnapshot = true
                let full = (CFPreferencesCopyValue("trash-full" as CFString, "com.apple.dock" as CFString,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
                let changed = result != self.entries || full != self.trashFull
                self.entries = result
                self.trashFull = full
                self.pruneImages(now: ProcessInfo.processInfo.systemUptime)
                if changed { self.onChange?() }
                self.updateCaptureHealth()
                self.captureThumbnailsIfNeeded()
            } else {
                self.hasReadSnapshot = false
                self.failures += 1
                if !AXIsProcessTrusted() || self.failures >= 3 {
                    let hadEntries = !self.entries.isEmpty
                    self.entries.removeAll()
                    self.clearCapture()
                    if hadEntries { self.onChange?() }
                }
                self.updateCaptureHealth()
            }
        }
    }

    func press(_ id: String) {
        guard isSynchronizing else { return }
        reader.submit(key: "press", priority: .veryHigh, work: { backend, _ in backend.press(id) }) { [weak self] success in
            if !success { NSSound.beep() }
            self?.refresh()
        }
    }

    /// Preserve fallback behavior when permission is unavailable or Dock is restarting.
    func synchronizedItems(from fallback: [DockItem]) -> [DockItem] {
        Self.project(fallback: fallback, entries: entries, trashFull: trashFull,
            imageRevision: imageRevision, availableWindowIDs: Set(images.keys))
    }

    static func project(fallback: [DockItem], entries: [NativeDockEntry], trashFull: Bool,
                        imageRevision: UInt64, availableWindowIDs: Set<String> = []) -> [DockItem] {
        guard entries.contains(where: { $0.isApplication && $0.url?.isFileURL == true }) else { return fallback }
        var result: [DockItem] = []
        var used = Set<ApplicationIdentity>()
        for entry in entries {
            if entry.isApplication, let url = entry.url, url.isFileURL {
                let identity = ApplicationIdentity(bundleIdentifier: nil, applicationURL: url)
                guard used.insert(identity).inserted else { continue }
                var item = fallback.first(where: { $0.kind.isApplication && $0.identity == identity })
                    ?? DockItem(identity: identity, bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                        applicationURL: url, displayName: entry.title, section: .running,
                        isRunning: entry.running, isActive: false, isHidden: false, transientState: .normal)
                item.badgeLabel = entry.badge
                result.append(item)
            } else if entry.isWindow || entry.subrole == "AXFileDockItem" || entry.subrole == "AXFolderDockItem" || entry.subrole == "AXURLDockItem" {
                // Keep the full AX entries for background recovery; only the
                // projected presentation omits windows without valid artwork.
                if entry.isWindow && !availableWindowIDs.contains(entry.id) { continue }
                var item = DockItem(identity: ApplicationIdentity(rawValue: entry.id), bundleIdentifier: nil,
                    applicationURL: entry.url ?? URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app"),
                    displayName: entry.title.isEmpty ? L10n.text("privacy.minimizedWindow") : entry.title, section: .files,
                    kind: .nativeDockItem(id: entry.id, isWindow: entry.isWindow),
                    isRunning: false, isActive: false, isHidden: false, transientState: .normal)
                item.nativeImageRevision = imageRevision
                result.append(item)
            }
        }
        // Keep explicitly added EchoDock shortcuts without duplicating native files.
        let nativePaths = Set(entries.compactMap { $0.url?.standardizedFileURL.path })
        let shortcuts = fallback.filter { $0.kind.shortcutID != nil && !nativePaths.contains($0.applicationURL.standardizedFileURL.path) }
        result.append(contentsOf: shortcuts)
        if var trash = fallback.first(where: { $0.kind == .trash }) {
            trash.nativeTrashFull = trashFull
            result.append(trash)
        }
        return result
    }

    /// Windows that just left Dock keep their artwork for the collapse only.
    static func departing(images: [String: NSImage], previous: [String: (image: NSImage, since: TimeInterval)],
                          validIDs: Set<String>, now: TimeInterval) -> [String: (image: NSImage, since: TimeInterval)] {
        var result = previous.filter { !validIDs.contains($0.key) && now - $0.value.since < departingImageLifetime }
        for (id, image) in images where !validIDs.contains(id) { result[id] = (image, now) }
        return result
    }

    func image(for id: String) -> NSImage? { images[id] ?? departingImages[id]?.image }

    func requestScreenCapture() {
        if !screenCaptureGranted && !hasRequestedCaptureThisSession {
            hasRequestedCaptureThisSession = true
            captureRequestAccepted = CGRequestScreenCaptureAccess()
        }
        if captureAuthorization != .granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
        }
        refresh()
        updateCaptureHealth()
    }

    private func synchronizeAppearance() {
        let preferences = PreferencesStore.shared
        func value(_ key: String) -> CFTypeRef? {
            CFPreferencesCopyValue(key as CFString, "com.apple.dock" as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        if let size = value("tilesize") as? Double {
            let clamped = min(64, max(32, size))
            if preferences.iconSize != clamped { preferences.iconSize = clamped }
        }
        if let magnify = value("magnification") as? Bool, preferences.magnificationEnabled != magnify {
            preferences.magnificationEnabled = magnify
        }
        if let autoHide = value("autohide") as? Bool, preferences.autoHide != autoHide {
            preferences.autoHide = autoHide
        }
    }

    private func scheduleCaptureRetry() {
        captureRetryTimer?.invalidate()
        guard isSynchronizing, policy.mayCapture(permissionGranted: screenCaptureGranted) else {
            captureRetryTimer = nil
            return
        }
        let delay = max(NativeDockThumbnailRecoveryPolicy.minimumCaptureInterval,
            recovery.nextAttemptAt - ProcessInfo.processInfo.systemUptime)
        let retry = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.captureRetryTimer = nil
                // Always re-read coordinates rather than retrying a stale crop.
                self?.refresh()
            }
        }
        retry.tolerance = 0.025
        captureRetryTimer = retry
        RunLoop.main.add(retry, forMode: .common)
    }

    private func captureThumbnailsIfNeeded() {
        guard policy.mayCapture(permissionGranted: screenCaptureGranted) else {
            updateCaptureHealth()
            return
        }
        guard #available(macOS 14.0, *), captureTask == nil else { return }
        // This source list is intentionally independent of the visible Dock.
        // A hidden window must still be retried and appear after its first image.
        let sourceEntries = entries
        let allWindows = sourceEntries.filter(\.isWindow)
        let windows = allWindows.filter { $0.frame.width > 4 && $0.frame.height > 4 }
        guard !windows.isEmpty else { return }
        let items = allWindows.map { NativeDockThumbnailRecoveryPolicy.Item(id: $0.id, frame: $0.frame) }
        let now = ProcessInfo.processInfo.systemUptime
        guard recovery.shouldAttempt(items: items, now: now) else { return }
        captureRetryTimer?.invalidate()
        captureRetryTimer = nil
        recovery.beginAttempt(items: items, now: now)
        let expectedIDs = Set(allWindows.map(\.id))
        let expectedGeneration = generation
        let diagnostics = UserDefaults.standard.bool(forKey: "thumbnailDiagnosticsEnabled")
        captureTask = Task { [weak self] in
            guard let self else { return }
            let attemptStartedAt = ProcessInfo.processInfo.systemUptime
            var shareableMs = -1, screenshotMs = -1, processMs = -1
            var successfulIDs = Set<String>()
            var unsettledIDs = Set<String>()
            var publishedIDs = Set<String>()
            var layoutWasSuperseded = false
            var allowFastRetry = true
            defer {
                if self.generation == expectedGeneration, !Task.isCancelled {
                    self.captureTask = nil
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    if layoutWasSuperseded {
                        self.recovery.layoutWasSuperseded(now: completedAt)
                    } else {
                        self.hasCompletedInitialCaptureAttempt = true
                        self.recovery.completeAttempt(expectedIDs: expectedIDs, successfulIDs: successfulIDs,
                            now: completedAt, allowFastRetry: allowFastRetry, unsettledIDs: unsettledIDs)
                    }
                    self.pruneImages(now: ProcessInfo.processInfo.systemUptime)
                    self.updateCaptureHealth()
                    if layoutWasSuperseded || self.recovery.retryPending || self.recovery.settlePending {
                        self.scheduleCaptureRetry()
                    }
                    if diagnostics {
                        // Durations and counts only; never titles or pixels.
                        Self.timingLog.info("capture total=\(Int((completedAt - attemptStartedAt) * 1000), privacy: .public)ms shareable=\(shareableMs, privacy: .public)ms screenshot=\(screenshotMs, privacy: .public)ms process=\(processMs, privacy: .public)ms ok=\(successfulIDs.count, privacy: .public)/\(expectedIDs.count, privacy: .public) changed=\(unsettledIDs.count, privacy: .public) superseded=\(layoutWasSuperseded, privacy: .public) settle=\(self.recovery.settlePending, privacy: .public)")
                    }
                }
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                shareableMs = Int((ProcessInfo.processInfo.systemUptime - attemptStartedAt) * 1000)
                guard !Task.isCancelled, self.generation == expectedGeneration, self.isSynchronizing else { return }
                guard self.policy.mayCapture(permissionGranted: self.screenCaptureGranted), AXIsProcessTrusted() else {
                    self.clearCapture()
                    self.updateCaptureHealth()
                    return
                }
                // Do not mix a newer Dock layout with the window frames captured
                // at the beginning of this attempt.
                let layout = sourceEntries.map { NativeDockThumbnailRecoveryPolicy.Item(id: $0.id, frame: $0.frame) }
                let currentLayout = self.entries.map { NativeDockThumbnailRecoveryPolicy.Item(id: $0.id, frame: $0.frame) }
                guard layout == currentLayout else {
                    layoutWasSuperseded = true
                    return
                }
                let union = sourceEntries.filter { $0.frame.width > 4 && $0.frame.height > 4 }
                    .reduce(CGRect.null) { $0.union($1.frame) }
                let candidates = content.windows.filter {
                    NativeDockCaptureSourcePolicy.accepts(owner: $0.owningApplication?.bundleIdentifier,
                        layer: $0.windowLayer, dockLayer: Int(CGWindowLevelForKey(.dockWindow)),
                        frame: $0.frame, itemBounds: union)
                }
                if UserDefaults.standard.bool(forKey: "thumbnailDiagnosticsEnabled") {
                    // Geometry and numeric error codes only; never window titles or pixels.
                    UserDefaults.standard.set([
                        "stage": "surface-selection",
                        "itemBounds": NSStringFromRect(union),
                        "candidates": candidates.count,
                        "dockFrames": content.windows.filter {
                            $0.owningApplication?.bundleIdentifier == "com.apple.dock"
                        }.map { "layer=\($0.windowLayer) id=\($0.windowID) frame=\(NSStringFromRect($0.frame))" }
                    ], forKey: "thumbnailDiagnostics")
                }
                // Never broaden capture to another application or guess among
                // ambiguous surfaces just to make a missing tile visible.
                guard candidates.count == 1, let source = candidates.first,
                      let display = content.displays.first(where: { $0.frame.contains(union) }),
                      let captureRegion = NativeDockCaptureSourcePolicy.captureRegion(
                        itemBounds: union, displayFrame: display.frame) else { return }
                let identity = CaptureSource(windowID: source.windowID, displayID: display.displayID,
                    displayFrame: display.frame)
                if self.captureSource != identity {
                    let discard = NativeDockThumbnailPublishPolicy.discardsImages(
                        previousDisplayID: self.lastCaptureDisplayID, newDisplayID: display.displayID)
                    self.captureSource = identity
                    self.lastCaptureDisplayID = display.displayID
                    if discard {
                        self.recovery.invalidateImages()
                        if !self.images.isEmpty {
                            self.images.removeAll()
                            self.departingImages.removeAll()
                            self.fingerprints.removeAll()
                            self.firstPublishedAt.removeAll()
                            self.pendingFingerprints.removeAll()
                            self.imageRevision &+= 1
                            self.onChange?()
                        }
                    }
                    self.updateCaptureHealth()
                }
                // Only the identified Dock window and its narrow item region.
                let filter = SCContentFilter(display: display, including: [source])
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = captureRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                configuration.width = max(1, Int(captureRegion.width * 2))
                configuration.height = max(1, Int(captureRegion.height * 2))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.scalesToFit = true
                configuration.ignoreShadowsSingleWindow = true
                configuration.shouldBeOpaque = false
                let screenshotStartedAt = ProcessInfo.processInfo.systemUptime
                let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
                let processStartedAt = ProcessInfo.processInfo.systemUptime
                screenshotMs = Int((processStartedAt - screenshotStartedAt) * 1000)
                defer { processMs = Int((ProcessInfo.processInfo.systemUptime - processStartedAt) * 1000) }
                guard !Task.isCancelled, self.generation == expectedGeneration, self.isSynchronizing else { return }
                guard self.policy.mayCapture(permissionGranted: self.screenCaptureGranted), AXIsProcessTrusted() else {
                    self.clearCapture()
                    self.updateCaptureHealth()
                    return
                }
                // Actual narrow-source capture is accepted even if a particular
                // tile cannot be cropped. Do not confuse image quality with consent.
                self.captureAuthorizationRejected = false
                self.captureAuthorizationVerified = true
                guard layout == self.entries.map({ NativeDockThumbnailRecoveryPolicy.Item(id: $0.id, frame: $0.frame) }) else {
                    layoutWasSuperseded = true
                    return
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample),
                      let image = NativeDockThumbnail.image(from: buffer) else { return }
                let scaleX = CGFloat(image.width) / captureRegion.width
                let scaleY = CGFloat(image.height) / captureRegion.height
                // While Dock opens a new slot, the item's AX frame grows from zero
                // width and the tile is only a slice of plate. Wait for full width.
                let itemWidths = self.entries.map(\.frame.width).sorted()
                let settledWidth = itemWidths.isEmpty ? 0 : itemWidths[itemWidths.count / 2]
                for entry in windows {
                    guard self.entries.contains(where: { $0.id == entry.id && $0.frame == entry.frame }) else { continue }
                    guard entry.frame.width >= settledWidth - 1 else { continue }
                    let crop = CGRect(x: (entry.frame.minX - captureRegion.minX) * scaleX,
                        y: (entry.frame.minY - captureRegion.minY) * scaleY,
                        width: entry.frame.width * scaleX, height: entry.frame.height * scaleY).integral
                    guard crop.minX >= 0, crop.minY >= 0,
                          crop.maxX <= CGFloat(image.width), crop.maxY <= CGFloat(image.height),
                          let tile = image.cropping(to: crop),
                          let artwork = NativeDockThumbnail.dockArtwork(fromTile: tile) else { continue }
                    // Transparency and geometry decide validity, never whether
                    // a window happens to contain dark or entirely black content.
                    let fingerprint = NativeDockThumbnail.Fingerprint(artwork)
                    switch NativeDockThumbnailPublishPolicy.decide(
                        hasPublishedImage: self.images[entry.id] != nil,
                        published: self.fingerprints[entry.id],
                        pending: self.pendingFingerprints[entry.id], candidate: fingerprint,
                        publishedAge: self.firstPublishedAt[entry.id].map { processStartedAt - $0 } ?? .infinity) {
                    case .keep:
                        // Settled: keep the published image and avoid UI churn.
                        self.pendingFingerprints[entry.id] = nil
                    case .confirm:
                        // A visible window's slot may be sliding or collapsing.
                        // Keep its last good image until this one repeats.
                        self.pendingFingerprints[entry.id] = fingerprint
                        unsettledIDs.insert(entry.id)
                    case .publish:
                        self.images[entry.id] = NSImage(cgImage: artwork,
                            size: CGSize(width: CGFloat(artwork.width) / scaleX,
                                         height: CGFloat(artwork.height) / scaleY))
                        self.fingerprints[entry.id] = fingerprint
                        self.pendingFingerprints[entry.id] = nil
                        if self.firstPublishedAt[entry.id] == nil { self.firstPublishedAt[entry.id] = processStartedAt }
                        publishedIDs.insert(entry.id)
                        unsettledIDs.insert(entry.id)
                    }
                    successfulIDs.insert(entry.id)
                }
                if !publishedIDs.isEmpty {
                    self.imageRevision &+= 1
                    self.onChange?()
                }
            } catch {
                guard !Task.isCancelled, self.generation == expectedGeneration else { return }
                // System errors/permission refusal keep the slower bounded
                // backoff. Fast retries are only for unsettled or missing artwork.
                allowFastRetry = false
                let error = error as NSError
                if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
                    // A successful preflight is not proof that actual capture
                    // is authorized. Stop showing retained pixels on denial.
                    self.captureAuthorizationRejected = true
                    self.captureAuthorizationVerified = false
                    self.recovery.invalidateImages()
                    if !self.images.isEmpty {
                        self.images.removeAll()
                        self.departingImages.removeAll()
                        self.fingerprints.removeAll()
                        self.firstPublishedAt.removeAll()
                        self.imageRevision &+= 1
                        self.onChange?()
                    }
                }
                if UserDefaults.standard.bool(forKey: "thumbnailDiagnosticsEnabled") {
                    UserDefaults.standard.set([
                        "stage": "capture-error", "domain": error.domain, "code": error.code
                    ], forKey: "thumbnailDiagnostics")
                }
            }
        }
    }
}
