import CoreGraphics
import Foundation

enum NativeDockCaptureHealth: Equatable {
    case paused
    case unsupported
    case permissionRequired
    case noWindows
    case waiting
    case partial(available: Int, total: Int)
    case ready

    static func evaluate(active: Bool, supported: Bool, permissionGranted: Bool,
                         hasReadSnapshot: Bool, windowCount: Int, availableCount: Int,
                         retryPending: Bool) -> Self {
        guard active else { return .paused }
        guard supported else { return .unsupported }
        guard permissionGranted else { return .permissionRequired }
        guard hasReadSnapshot else { return .waiting }
        guard windowCount > 0 else { return .noWindows }
        guard availableCount > 0 else { return .waiting }
        guard availableCount >= windowCount else {
            return .partial(available: availableCount, total: windowCount)
        }
        return retryPending ? .waiting : .ready
    }
}

extension Notification.Name {
    static let sameDockCaptureHealthDidChange = Notification.Name("SameDock.captureHealthDidChange")
}

/// Metadata only. Window images remain in memory in NativeDockContentSync.
/// Missing artwork is retried independently of whether a window is displayed.
struct NativeDockThumbnailRecoveryPolicy {
    struct Item: Equatable {
        let id: String
        let frame: CGRect
    }

    static let imageLifetime: TimeInterval = 30
    static let minimumCaptureInterval: TimeInterval = 0.25
    private static let firstImageRetryDelays: [TimeInterval] = [0.25, 0.5, 1]
    /// Dock can expose an in-flight minimize frame that still crops "validly".
    /// Recheck changed artwork briefly until two captures agree, then return
    /// to the slow refresh. Bounded so live content cannot keep capturing.
    static let settleRetryDelays: [TimeInterval] = [0.25, 0.25, 0.5, 0.5, 1, 1]
    private(set) var successfulAt: [String: TimeInterval] = [:]
    private(set) var retryPending = false
    private(set) var settlePending = false
    private var settleAttempts = 0
    private(set) var nextAttemptAt: TimeInterval = 0
    private var lastAttemptAt: TimeInterval?
    private var attemptedItems: [Item] = []
    private var consecutiveFailures = 0
    private var firstImageRetries = 0

    func shouldAttempt(items: [Item], now: TimeInterval) -> Bool {
        guard !items.isEmpty,
              lastAttemptAt.map({ now - $0 >= Self.minimumCaptureInterval }) ?? true else { return false }
        return items != attemptedItems || now >= nextAttemptAt
    }

    mutating func beginAttempt(items: [Item], now: TimeInterval) {
        if !Set(items.map(\.id)).isSubset(of: Set(attemptedItems.map(\.id))) {
            // A newly minimized window gets its own bounded first-image budget.
            firstImageRetries = 0
            consecutiveFailures = 0
        }
        // A new window or moved tile gets a fresh, still bounded settle budget.
        if items != attemptedItems { settleAttempts = 0 }
        attemptedItems = items
        lastAttemptAt = now
        nextAttemptAt = now + Self.minimumCaptureInterval
    }

    /// `unsettledIDs` are windows whose published artwork is new or differs
    /// from the previous capture; they need a quick confirmation capture.
    mutating func completeAttempt(expectedIDs: Set<String>, successfulIDs: Set<String>, now: TimeInterval,
                                  allowFastRetry: Bool = true, unsettledIDs: Set<String> = []) {
        for id in successfulIDs.intersection(expectedIDs) { successfulAt[id] = now }
        retryPending = !expectedIDs.isSubset(of: successfulIDs)
        let settleDelay: TimeInterval?
        if !unsettledIDs.intersection(successfulIDs).intersection(expectedIDs).isEmpty,
           settleAttempts < Self.settleRetryDelays.count {
            settleDelay = Self.settleRetryDelays[settleAttempts]
            settleAttempts += 1
        } else {
            settleDelay = nil
        }
        settlePending = settleDelay != nil
        defer { if let settleDelay { nextAttemptAt = min(nextAttemptAt, now + settleDelay) } }
        if retryPending {
            let missingFirstImage = !expectedIDs.isSubset(of: Set(successfulAt.keys))
            if allowFastRetry, missingFirstImage, firstImageRetries < Self.firstImageRetryDelays.count {
                nextAttemptAt = now + Self.firstImageRetryDelays[firstImageRetries]
                firstImageRetries += 1
            } else {
                consecutiveFailures = min(consecutiveFailures + 1, 4)
                nextAttemptAt = now + min(15, pow(2, Double(consecutiveFailures)))
            }
        } else {
            consecutiveFailures = 0
            nextAttemptAt = now + 15
        }
    }

    mutating func layoutWasSuperseded(now: TimeInterval) {
        // Dock animation invalidates crop coordinates, not capture permission.
        // Re-read the layout without spending a failed-capture retry.
        nextAttemptAt = now + Self.minimumCaptureInterval
    }

    /// A failed refresh never extends the lifetime of an older image.
    mutating func prune(validIDs: Set<String>, now: TimeInterval) -> Set<String> {
        let removed = Set(successfulAt.compactMap { id, timestamp in
            !validIDs.contains(id) || now - timestamp >= Self.imageLifetime ? id : nil
        })
        for id in removed { successfulAt.removeValue(forKey: id) }
        return removed
    }

    mutating func invalidateImages() { successfulAt.removeAll() }
}

/// Decides whether a fresh tile capture replaces the published thumbnail.
/// Native Dock never blanks or shows an in-between frame for a window that is
/// already on screen: when its slot slides (another tile or app icon removed,
/// collapsed or added), the old artwork stays until a different image has been
/// seen twice in a row. Only a window without any image publishes immediately.
enum NativeDockThumbnailPublishPolicy {
    enum Decision: Equatable {
        /// Show this capture now.
        case publish
        /// Published artwork is still current.
        case keep
        /// Keep the published artwork; remember this capture and confirm it.
        case confirm
    }

    /// A just-minimized window's first image may be an in-flight frame; while
    /// it is this young, a differing capture corrects it at once (1.1.6 speed).
    static let firstImageCorrectionWindow: TimeInterval = 1.5

    static func decide(hasPublishedImage: Bool, published: NativeDockThumbnail.Fingerprint?,
                       pending: NativeDockThumbnail.Fingerprint?,
                       candidate: NativeDockThumbnail.Fingerprint?,
                       publishedAge: TimeInterval = .infinity) -> Decision {
        guard hasPublishedImage else { return .publish }
        guard let candidate else { return .keep }
        if let published, published.matches(candidate) { return .keep }
        if publishedAge < firstImageCorrectionWindow { return .publish }
        if let pending, pending.matches(candidate) { return .publish }
        return .confirm
    }

    /// A capture source change only discards artwork when Dock moved to another
    /// display. Screen-parameter churn (an app launching or quitting, Dock
    /// resizing) re-identifies the same Dock surface and keeps every image.
    static func discardsImages(previousDisplayID: CGDirectDisplayID?, newDisplayID: CGDirectDisplayID) -> Bool {
        guard let previousDisplayID else { return false }
        return previousDisplayID != newDisplayID
    }
}

/// Fail closed whenever no visible, enabled display needs native Dock content.
struct NativeDockPrivacyPolicy {
    var enabled = false
    var panelsEnabled = true
    var hasAvailableDisplay = false
    var sessionActive = true
    var screenAwake = true
    var thumbnailsEnabled = false

    var mayRead: Bool {
        enabled && panelsEnabled && hasAvailableDisplay && sessionActive && screenAwake
    }

    func mayCapture(permissionGranted: Bool) -> Bool {
        mayRead && thumbnailsEnabled && permissionGranted
    }
}

enum NativeDockCaptureSourcePolicy {
    /// Dock may expose a display-sized rendering canvas. Identify its layer,
    /// then require a separate, narrow capture region before reading pixels.
    static func accepts(owner: String?, layer: Int, dockLayer: Int, frame: CGRect, itemBounds: CGRect) -> Bool {
        guard owner == "com.apple.dock", layer == dockLayer,
              valid(frame), valid(itemBounds),
              frame.insetBy(dx: -2, dy: -2).contains(itemBounds),
              min(itemBounds.width, itemBounds.height) <= 256,
              itemBounds.width * itemBounds.height <= 2_000_000 else { return false }
        return true
    }

    static func captureRegion(itemBounds: CGRect, displayFrame: CGRect) -> CGRect? {
        guard valid(itemBounds), valid(displayFrame),
              min(itemBounds.width, itemBounds.height) <= 256,
              itemBounds.width * itemBounds.height <= 2_000_000,
              displayFrame.contains(itemBounds) else { return nil }
        let region = itemBounds.integral.intersection(displayFrame)
        return valid(region) ? region : nil
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 4 && frame.height > 4
    }
}
