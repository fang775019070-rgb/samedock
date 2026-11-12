import Foundation

enum ScreenCaptureAuthorizationStatus: Equatable {
    case notGranted
    case needsRelaunch
    case rejected
    case granted

    static func evaluate(preflightGranted: Bool, requestAccepted: Bool, captureRejected: Bool) -> Self {
        // An actual refusal outranks preflight and survives unrelated source resets.
        if captureRejected { return .rejected }
        if preflightGranted { return .granted }
        return requestAccepted ? .needsRelaunch : .notGranted
    }
}

enum PermissionCaptureValidation: Equatable {
    case notNeeded
    case pending
    case verified
    case inconclusive

    static func evaluate(active: Bool, hasReadSnapshot: Bool, windowCount: Int,
                         capturableWindowCount: Int, verified: Bool, attemptCompleted: Bool) -> Self {
        guard active else { return .notNeeded }
        if verified { return .verified }
        guard hasReadSnapshot else { return .pending }
        if windowCount == 0 { return .notNeeded }
        if attemptCompleted || capturableWindowCount == 0 { return .inconclusive }
        return .pending
    }
}

struct PermissionSetupAccess: Equatable {
    var accessibilityGranted: Bool
    var capturePreflightGranted: Bool
    var captureRejected: Bool
    var thumbnailsSupported: Bool

    var captureGranted: Bool { capturePreflightGranted && !captureRejected }
    var complete: Bool { accessibilityGranted && (captureGranted || !thumbnailsSupported) }

    func shouldPresent(hasSeenWelcome: Bool, pending: Bool, enabled: Bool, syncEnabled: Bool) -> Bool {
        !hasSeenWelcome || pending || (enabled && syncEnabled && !complete)
    }

    func shouldAdvanceCapture(started: Bool, active: Bool, visible: Bool, requested: Bool) -> Bool {
        started && active && visible && !requested && accessibilityGranted
            && thumbnailsSupported && !captureGranted
    }

    func shouldDismissWelcome(isWelcome: Bool, enabled: Bool, visible: Bool,
                              captureValidation: PermissionCaptureValidation) -> Bool {
        // Complete the permission introduction, not every thumbnail. A completed
        // but inconclusive capture leaves the separate sync status truthful.
        isWelcome && enabled && visible && complete
            && (!thumbnailsSupported || captureValidation != .pending)
    }
}
