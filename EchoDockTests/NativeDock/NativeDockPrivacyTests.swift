import AppKit
import Testing
@testable import EchoDock

@Suite @MainActor
struct NativeDockPrivacyTests {
    @Test func freshInstallIsReadyForSystemPermissionsAndRespectsAnExplicitPause() {
        let name = "DockluneTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.nativeDockSyncEnabled)
        #expect(preferences.nativeThumbnailsEnabled)
        // Permission is still required before any pixels can be captured.
        #expect(!NativeDockPrivacyPolicy(enabled: true, hasAvailableDisplay: true,
            thumbnailsEnabled: true).mayCapture(permissionGranted: false))
        preferences.nativeDockSyncEnabled = false
        preferences.nativeThumbnailsEnabled = false
        let reopened = PreferencesStore(defaults: defaults)
        #expect(!reopened.nativeDockSyncEnabled)
        #expect(!reopened.nativeThumbnailsEnabled)
        let sync = NativeDockContentSync(preferences: preferences)
        sync.setDisplayAvailability(true)
        sync.start()
        #expect(!sync.isSynchronizing)
        #expect(sync.entries.isEmpty)
        sync.stop()
    }

    @Test func sleepHiddenAndDisconnectedStatesBlockCollection() {
        let active = NativeDockPrivacyPolicy(enabled: true, panelsEnabled: true, hasAvailableDisplay: true,
            sessionActive: true, screenAwake: true, thumbnailsEnabled: true)
        #expect(active.mayCapture(permissionGranted: true))
        #expect(!active.mayCapture(permissionGranted: false))
        for key in [\NativeDockPrivacyPolicy.enabled, \.panelsEnabled, \.hasAvailableDisplay, \.sessionActive, \.screenAwake] {
            var paused = active
            paused[keyPath: key] = false
            #expect(!paused.mayRead)
            #expect(!paused.mayCapture(permissionGranted: true))
        }
        var textOnly = active
        textOnly.thumbnailsEnabled = false
        #expect(textOnly.mayRead)
        #expect(!textOnly.mayCapture(permissionGranted: true))
    }

    @Test func rejectsOtherApplicationsWallpaperAndAmbiguousLargeSurfaces() {
        let items = CGRect(x: 100, y: 1000, width: 900, height: 64)
        let dock = CGRect(x: 90, y: 990, width: 920, height: 90)
        #expect(NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 20, dockLayer: 20, frame: dock, itemBounds: items))
        #expect(!NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.finder", layer: 20, dockLayer: 20, frame: dock, itemBounds: items))
        #expect(!NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: -2147483623, dockLayer: 20, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), itemBounds: items))
        #expect(!NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 20, dockLayer: 20, frame: dock.offsetBy(dx: 300, dy: 0), itemBounds: items))
        #expect(!NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 20, dockLayer: 20, frame: dock, itemBounds: .null))
        #expect(NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 20, dockLayer: 20, frame: CGRect(x: 0, y: 20, width: 90, height: 930), itemBounds: CGRect(x: 10, y: 30, width: 64, height: 900)))
    }

    @Test func displaySizedDockCanvasUsesOnlyItsNarrowItemRegion() {
        let display = CGRect(x: 0, y: 846, width: 1280, height: 832)
        let items = CGRect(x: 111.95, y: 1593, width: 1056.1, height: 75)
        #expect(NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 20,
            dockLayer: 20, frame: display, itemBounds: items))
        let region = NativeDockCaptureSourcePolicy.captureRegion(itemBounds: items, displayFrame: display)
        #expect(region == CGRect(x: 111, y: 1593, width: 1058, height: 75))
        #expect(!NativeDockCaptureSourcePolicy.accepts(owner: "com.apple.dock", layer: 0,
            dockLayer: 20, frame: display, itemBounds: items))
        #expect(NativeDockCaptureSourcePolicy.captureRegion(itemBounds: display, displayFrame: display) == nil)
        #expect(NativeDockCaptureSourcePolicy.captureRegion(itemBounds: items.offsetBy(dx: 500, dy: 0), displayFrame: display) == nil)
    }

    @Test func disconnectAndStopClearNativeStateSynchronously() {
        let name = "DockluneTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.nativeDockSyncEnabled = true
        let sync = NativeDockContentSync(preferences: preferences)
        sync.setDisplayAvailability(true)
        sync.start()
        #expect(sync.isSynchronizing)
        sync.setDisplayAvailability(false)
        #expect(!sync.isSynchronizing)
        #expect(sync.entries.isEmpty)
        sync.stop()
        sync.setDisplayAvailability(true)
        #expect(!sync.isSynchronizing)
    }

    @Test func captureHealthRequiresActualArtworkAndDistinguishesAnEmptyDock() {
        func health(read: Bool = true, total: Int = 2, available: Int = 0,
                    permission: Bool = true, retry: Bool = false) -> NativeDockCaptureHealth {
            .evaluate(active: true, supported: true, permissionGranted: permission,
                hasReadSnapshot: read, windowCount: total, availableCount: available, retryPending: retry)
        }
        #expect(health(read: false, total: 0) == .waiting)
        #expect(health(total: 0) == .noWindows)
        // Windows with invalid frames still count as expected windows.
        #expect(health(total: 2) == .waiting)
        #expect(health(available: 1) == .partial(available: 1, total: 2))
        #expect(health(available: 2) == .ready)
        // Retained cached images do not turn an unsuccessful refresh into ready.
        #expect(health(available: 2, retry: true) == .waiting)
        #expect(health(available: 2, permission: false) == .permissionRequired)
        #expect(NativeDockCaptureHealth.evaluate(active: false, supported: true, permissionGranted: false,
            hasReadSnapshot: false, windowCount: 0, availableCount: 0, retryPending: false) == .paused)
        #expect(NativeDockCaptureHealth.evaluate(active: true, supported: false, permissionGranted: true,
            hasReadSnapshot: true, windowCount: 2, availableCount: 0, retryPending: false) == .unsupported)
    }

    @Test func systemCaptureErrorsKeepBoundedBackoffAndRetainSuccessfulArtwork() {
        let items = [NativeDockThumbnailRecoveryPolicy.Item(id: "one", frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
            NativeDockThumbnailRecoveryPolicy.Item(id: "two", frame: CGRect(x: 50, y: 0, width: 50, height: 50))]
        var recovery = NativeDockThumbnailRecoveryPolicy()
        #expect(recovery.shouldAttempt(items: items, now: 0))
        recovery.beginAttempt(items: items, now: 0)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: ["one"], now: 0, allowFastRetry: false)
        #expect(recovery.retryPending)
        #expect(!recovery.shouldAttempt(items: items, now: 1))
        #expect(recovery.shouldAttempt(items: items, now: 2))
        recovery.beginAttempt(items: items, now: 2)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: [], now: 2, allowFastRetry: false)
        #expect(recovery.nextAttemptAt == 6)
        recovery.beginAttempt(items: items, now: 6)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: [], now: 6, allowFastRetry: false)
        #expect(recovery.nextAttemptAt == 14)
        recovery.beginAttempt(items: items, now: 14)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: [], now: 14, allowFastRetry: false)
        #expect(recovery.nextAttemptAt == 29)
        recovery.beginAttempt(items: items, now: 29)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: ["one", "two"], now: 29)
        #expect(!recovery.retryPending)
        #expect(!recovery.shouldAttempt(items: items, now: 43))
        #expect(recovery.shouldAttempt(items: items, now: 44))
    }

    @Test func failedRefreshDoesNotRenewOtherWindowsAndSourceInvalidationDropsCachedImages() {
        var recovery = NativeDockThumbnailRecoveryPolicy()
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: ["one", "two"], now: 0)
        recovery.completeAttempt(expectedIDs: ["one", "two"], successfulIDs: ["two"], now: 20)
        #expect(recovery.prune(validIDs: ["one", "two"], now: 29).isEmpty)
        #expect(recovery.prune(validIDs: ["one", "two"], now: 30) == ["one"])
        #expect(recovery.successfulAt["two"] == 20)
        // A closed window disappears immediately, regardless of its image age.
        #expect(recovery.prune(validIDs: [], now: 31) == ["two"])
        recovery.completeAttempt(expectedIDs: ["one"], successfulIDs: ["one"], now: 32)
        recovery.invalidateImages()
        #expect(recovery.successfulAt.isEmpty)
    }

    @Test func newHiddenWindowTriggersCaptureWithoutWaitingForNormalRefresh() {
        let first = NativeDockThumbnailRecoveryPolicy.Item(id: "one", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let hidden = NativeDockThumbnailRecoveryPolicy.Item(id: "hidden", frame: CGRect(x: 50, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        recovery.beginAttempt(items: [first], now: 0)
        recovery.completeAttempt(expectedIDs: ["one"], successfulIDs: ["one"], now: 0)
        #expect(!recovery.shouldAttempt(items: [first, hidden], now: 0.1))
        // A new window must not wait behind the last background image refresh.
        #expect(recovery.shouldAttempt(items: [first, hidden], now: 0.25))
        #expect(recovery.shouldAttempt(items: [first, hidden], now: 1))
        #expect(recovery.shouldAttempt(items: [first, hidden], now: 2))
        #expect(!recovery.shouldAttempt(items: [], now: 20))
    }

    @Test func firstImageGetsBriefRetriesBeforePersistentFailureBackoff() {
        let first = NativeDockThumbnailRecoveryPolicy.Item(id: "one", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let hidden = NativeDockThumbnailRecoveryPolicy.Item(id: "hidden", frame: CGRect(x: 50, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        recovery.beginAttempt(items: [first, hidden], now: 0)
        recovery.completeAttempt(expectedIDs: ["one", "hidden"], successfulIDs: ["one"], now: 0)
        #expect(recovery.shouldAttempt(items: [first, hidden], now: 0.25))
        #expect(recovery.successfulAt["one"] == 0)
        recovery.beginAttempt(items: [first, hidden], now: 0.25)
        recovery.completeAttempt(expectedIDs: ["one", "hidden"], successfulIDs: [], now: 0.25)
        #expect(recovery.nextAttemptAt == 0.75)
        recovery.beginAttempt(items: [first, hidden], now: 0.75)
        recovery.completeAttempt(expectedIDs: ["one", "hidden"], successfulIDs: [], now: 0.75)
        #expect(recovery.nextAttemptAt == 1.75)
        recovery.beginAttempt(items: [first, hidden], now: 1.75)
        recovery.completeAttempt(expectedIDs: ["one", "hidden"], successfulIDs: [], now: 1.75)
        #expect(recovery.nextAttemptAt == 3.75)
        #expect(!recovery.shouldAttempt(items: [first, hidden], now: 2))
        recovery.beginAttempt(items: [first, hidden], now: 3.75)
        recovery.completeAttempt(expectedIDs: ["one", "hidden"], successfulIDs: ["one", "hidden"], now: 3.75)
        #expect(!recovery.retryPending)
        #expect(!recovery.shouldAttempt(items: [first, hidden], now: 18))
    }

    @Test func animationInvalidationDoesNotBecomeExponentialCaptureFailure() {
        let item = NativeDockThumbnailRecoveryPolicy.Item(id: "window", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        for index in 0..<4 {
            let now = Double(index) * 0.5
            recovery.beginAttempt(items: [item], now: now)
            recovery.layoutWasSuperseded(now: now + 0.1)
            #expect(recovery.shouldAttempt(items: [item], now: now + 0.4))
        }
        recovery.beginAttempt(items: [item], now: 2)
        recovery.completeAttempt(expectedIDs: ["window"], successfulIDs: [], now: 2, allowFastRetry: false)
        #expect(recovery.nextAttemptAt == 4)
    }

    @Test func newWindowDoesNotInheritAnotherWindowsLongFailureDelay() {
        let old = NativeDockThumbnailRecoveryPolicy.Item(id: "old", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let new = NativeDockThumbnailRecoveryPolicy.Item(id: "new", frame: CGRect(x: 50, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        for now: TimeInterval in [0, 2, 6, 14] {
            recovery.beginAttempt(items: [old], now: now)
            recovery.completeAttempt(expectedIDs: ["old"], successfulIDs: [], now: now, allowFastRetry: false)
        }
        #expect(recovery.nextAttemptAt == 29)
        #expect(recovery.shouldAttempt(items: [old, new], now: 14.25))
        recovery.beginAttempt(items: [old, new], now: 14.25)
        recovery.completeAttempt(expectedIDs: ["old", "new"], successfulIDs: [], now: 14.25)
        #expect(recovery.nextAttemptAt == 14.5)
    }

    @Test func frameChangesDoNotResetTheFirstImageRetryBudget() {
        var recovery = NativeDockThumbnailRecoveryPolicy()
        for index in 0..<4 {
            let item = NativeDockThumbnailRecoveryPolicy.Item(id: "window",
                frame: CGRect(x: index * 2, y: 0, width: 50, height: 50))
            recovery.beginAttempt(items: [item], now: Double(index))
            recovery.completeAttempt(expectedIDs: ["window"], successfulIDs: [], now: Double(index))
        }
        #expect(recovery.nextAttemptAt == 5)
    }

    @Test func permissionIntroductionNeverRequestsCaptureBeforeUserStarts() {
        let access = PermissionSetupAccess(accessibilityGranted: true, capturePreflightGranted: false,
            captureRejected: false, thumbnailsSupported: true)
        #expect(!access.shouldAdvanceCapture(started: false, active: true, visible: true, requested: false))
    }

    @Test func permissionSetupContinuesOnceOnlyAfterReturningToVisibleCard() {
        let access = PermissionSetupAccess(accessibilityGranted: true, capturePreflightGranted: false,
            captureRejected: false, thumbnailsSupported: true)
        #expect(access.shouldAdvanceCapture(started: true, active: true, visible: true, requested: false))
        #expect(!access.shouldAdvanceCapture(started: true, active: false, visible: true, requested: false))
        #expect(!access.shouldAdvanceCapture(started: true, active: true, visible: false, requested: false))
        #expect(!access.shouldAdvanceCapture(started: true, active: true, visible: true, requested: true))
    }

    @Test func upgradedUsersWithMissingPermissionsSeeSetupButExplicitPauseIsRespected() {
        let access = PermissionSetupAccess(accessibilityGranted: true, capturePreflightGranted: false,
            captureRejected: false, thumbnailsSupported: true)
        #expect(access.shouldPresent(hasSeenWelcome: true, pending: false, enabled: true, syncEnabled: true))
        #expect(!access.shouldPresent(hasSeenWelcome: true, pending: false, enabled: true, syncEnabled: false))
        #expect(!access.shouldPresent(hasSeenWelcome: true, pending: false, enabled: false, syncEnabled: true))
        #expect(access.shouldPresent(hasSeenWelcome: true, pending: true, enabled: true, syncEnabled: true))
    }

    @Test func actualCaptureRejectionPreventsSetupCompletionDespiteSuccessfulPreflight() {
        let rejected = PermissionSetupAccess(accessibilityGranted: true, capturePreflightGranted: true,
            captureRejected: true, thumbnailsSupported: true)
        #expect(!rejected.captureGranted)
        #expect(!rejected.complete)
        var recovered = rejected
        recovered.captureRejected = false
        #expect(recovered.complete)
        var unsupported = rejected
        unsupported.thumbnailsSupported = false
        #expect(unsupported.complete)
        unsupported.accessibilityGranted = false
        #expect(!unsupported.complete)
    }

    @Test func requestAcceptanceIsNotPermissionUntilItTakesEffect() {
        #expect(ScreenCaptureAuthorizationStatus.evaluate(preflightGranted: false,
            requestAccepted: false, captureRejected: false) == .notGranted)
        #expect(ScreenCaptureAuthorizationStatus.evaluate(preflightGranted: false,
            requestAccepted: true, captureRejected: false) == .needsRelaunch)
        #expect(ScreenCaptureAuthorizationStatus.evaluate(preflightGranted: true,
            requestAccepted: true, captureRejected: false) == .granted)
        for preflight in [false, true] {
            #expect(ScreenCaptureAuthorizationStatus.evaluate(preflightGranted: preflight,
                requestAccepted: true, captureRejected: true) == .rejected)
        }
    }

    @Test func welcomeWaitsForInitialCaptureAndNeverAutoClosesNormalSettings() {
        var access = PermissionSetupAccess(accessibilityGranted: true, capturePreflightGranted: true,
            captureRejected: false, thumbnailsSupported: true)
        #expect(!access.shouldDismissWelcome(isWelcome: true, enabled: true, visible: true, captureValidation: .pending))
        for validation: PermissionCaptureValidation in [.verified, .notNeeded, .inconclusive] {
            #expect(access.shouldDismissWelcome(isWelcome: true, enabled: true, visible: true, captureValidation: validation))
            #expect(!access.shouldDismissWelcome(isWelcome: false, enabled: true, visible: true, captureValidation: validation))
        }
        #expect(!access.shouldDismissWelcome(isWelcome: true, enabled: false, visible: true, captureValidation: .verified))
        #expect(!access.shouldDismissWelcome(isWelcome: true, enabled: true, visible: false, captureValidation: .verified))
        access.captureRejected = true
        #expect(!access.shouldDismissWelcome(isWelcome: true, enabled: true, visible: true, captureValidation: .verified))
    }

    @Test func unreadOrCapturingDockIsNotConfusedWithNoWindows() {
        func state(active: Bool = true, read: Bool = true, windows: Int = 2, capturable: Int = 2,
                   verified: Bool = false, finished: Bool = false) -> PermissionCaptureValidation {
            .evaluate(active: active, hasReadSnapshot: read, windowCount: windows,
                capturableWindowCount: capturable, verified: verified, attemptCompleted: finished)
        }
        #expect(state(read: false, windows: 0, capturable: 0) == .pending)
        #expect(state() == .pending)
        #expect(state(windows: 0, capturable: 0) == .notNeeded)
        #expect(state(active: false, read: false) == .notNeeded)
        #expect(state(verified: true) == .verified)
        // Accepted capture need not yield every crop. Inconclusive image/source
        // failures never manufacture NativeDockCaptureHealth.ready.
        #expect(state(finished: true) == .inconclusive)
        #expect(state(capturable: 0) == .inconclusive)
    }

    @Test func systemLanguageUsesChineseOrEnglishWithoutASeparatePreference() {
        for language in ["zh", "zh-Hans-CN", "zh-Hant-TW", "zh_CN"] {
            #expect(L10n.language(for: [language, "en"]) == "zh-Hans")
        }
        for language in ["en", "en-GB", "fr-FR", "ja-JP", "de-DE"] {
            #expect(L10n.language(for: [language, "zh-Hans"]) == "en")
        }
        #expect(L10n.language(for: []) == "en")
    }

    @Test func everyAppStringHasBothSupportedLanguagesIncludingWindowRestore() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("EchoDock/Resources/Localizable.xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        #expect(strings["dock.menu.restoreWindow"] != nil)
        for (key, entry) in strings {
            let translations = try #require(entry["localizations"] as? [String: [String: Any]])
            for language in ["en", "zh-Hans"] {
                let unit = try #require(translations[language]?["stringUnit"] as? [String: String])
                #expect(unit["value"]?.isEmpty == false, "Missing \(language) for \(key)")
            }
        }
    }

    @Test func changedArtworkIsRecheckedQuicklyUntilItSettles() {
        let item = NativeDockThumbnailRecoveryPolicy.Item(id: "window", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        recovery.beginAttempt(items: [item], now: 0)
        // The first image may be an in-flight minimize frame: confirm it soon.
        recovery.completeAttempt(expectedIDs: ["window"], successfulIDs: ["window"], now: 0.5, unsettledIDs: ["window"])
        #expect(recovery.settlePending)
        #expect(!recovery.retryPending)
        #expect(recovery.nextAttemptAt == 0.75)
        #expect(recovery.shouldAttempt(items: [item], now: 0.75))
        recovery.beginAttempt(items: [item], now: 0.75)
        // Two consecutive captures agree: back to the slow refresh.
        recovery.completeAttempt(expectedIDs: ["window"], successfulIDs: ["window"], now: 0.8)
        #expect(!recovery.settlePending)
        #expect(recovery.nextAttemptAt == 15.8)
        #expect(!recovery.shouldAttempt(items: [item], now: 10))
    }

    @Test func endlesslyChangingArtworkHasABoundedSettleBudget() {
        let item = NativeDockThumbnailRecoveryPolicy.Item(id: "window", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        var now: TimeInterval = 0
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            recovery.beginAttempt(items: [item], now: now)
            recovery.completeAttempt(expectedIDs: ["window"], successfulIDs: ["window"], now: now, unsettledIDs: ["window"])
            delays.append(recovery.nextAttemptAt - now)
            now = recovery.nextAttemptAt
        }
        #expect(Array(delays.prefix(6)) == NativeDockThumbnailRecoveryPolicy.settleRetryDelays)
        #expect(delays.dropFirst(6).allSatisfy { $0 == 15 })
        #expect(!recovery.settlePending)
        // A newly minimized window receives its own settle budget.
        let other = NativeDockThumbnailRecoveryPolicy.Item(id: "other", frame: CGRect(x: 50, y: 0, width: 50, height: 50))
        recovery.beginAttempt(items: [item, other], now: now)
        recovery.completeAttempt(expectedIDs: ["window", "other"], successfulIDs: ["window", "other"], now: now,
            unsettledIDs: ["other"])
        #expect(recovery.nextAttemptAt == now + 0.25)
    }

    @Test func settleRecheckDoesNotWaitBehindAnotherWindowsFailureBackoff() {
        let failing = NativeDockThumbnailRecoveryPolicy.Item(id: "failing", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let fresh = NativeDockThumbnailRecoveryPolicy.Item(id: "fresh", frame: CGRect(x: 50, y: 0, width: 50, height: 50))
        var recovery = NativeDockThumbnailRecoveryPolicy()
        recovery.beginAttempt(items: [failing, fresh], now: 0)
        recovery.completeAttempt(expectedIDs: ["failing", "fresh"], successfulIDs: ["fresh"], now: 0,
            allowFastRetry: false, unsettledIDs: ["fresh"])
        #expect(recovery.retryPending)
        #expect(recovery.nextAttemptAt == 0.25)
        // Unchanged artwork never counts as unsettled.
        recovery.beginAttempt(items: [failing, fresh], now: 0.25)
        recovery.completeAttempt(expectedIDs: ["failing", "fresh"], successfulIDs: ["fresh"], now: 0.25,
            allowFastRetry: false)
        #expect(!recovery.settlePending)
        #expect(recovery.nextAttemptAt == 4.25)
    }
}
