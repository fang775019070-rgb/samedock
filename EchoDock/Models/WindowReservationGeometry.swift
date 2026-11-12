import Foundation
import CoreGraphics

/// A display expressed in Accessibility's top-left-origin global coordinate space.
struct WindowReservationDisplayGeometry: Equatable {
    let identity: DisplayIdentity
    let frame: CGRect
    let visibleFrame: CGRect
    let reservedHeight: CGFloat
    var position: DockPosition = .bottom

    var canonical: Self {
        Self(identity: identity, frame: position.canonicalAccessibilityFrame(frame),
             visibleFrame: position.canonicalAccessibilityFrame(visibleFrame), reservedHeight: reservedHeight)
    }

    var availableFrame: CGRect {
        if position != .bottom {
            let frame = canonical.availableFrame
            return frame.isNull ? .null : position.physicalAccessibilityFrame(frame)
        }
        let bottomLimit = min(visibleFrame.maxY, frame.maxY - max(0, reservedHeight))
        guard bottomLimit > visibleFrame.minY else { return .null }
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: bottomLimit - visibleFrame.minY
        )
    }
}

struct WindowReservationAdjustment: Equatable {
    let displayIdentity: DisplayIdentity
    let targetFrame: CGRect
}

struct WindowEdgeSnapRegion: Equatable {
    let displayIdentity: DisplayIdentity
    /// EchoDock's resting glass body in Accessibility's top-left coordinate space.
    let frame: CGRect
    var position: DockPosition = .bottom
}

enum WindowEdgeSnapInteraction: Equatable {
    case move
    case resize
}

struct WindowEdgeSnapAdjustment: Equatable {
    let displayIdentity: DisplayIdentity
    let targetFrame: CGRect
}

enum WindowEdgeSnapInteractionPolicy {
    static func shouldDeferUntilMouseRelease(
        interaction: WindowEdgeSnapInteraction?,
        pressedMouseButtons: Int
    ) -> Bool {
        interaction != nil && pressedMouseButtons != 0
    }
}

enum WindowEdgeSnapGeometryPolicy {
    static let defaultActivationDistance: CGFloat = 12
    static let defaultGap: CGFloat = 1
    static let minimumOverlap: CGFloat = 24
    private static let minimumCorrection: CGFloat = 0.25

    static func adjustment(
        for windowFrame: CGRect,
        interaction: WindowEdgeSnapInteraction,
        regions: [WindowEdgeSnapRegion],
        activationDistance: CGFloat = defaultActivationDistance,
        gap: CGFloat = defaultGap
    ) -> WindowEdgeSnapAdjustment? {
        guard windowFrame.width > 0,
              windowFrame.height > 0,
              activationDistance >= 0 else {
            return nil
        }

        let allCandidates = regions.flatMap { region in
            candidates(
                for: windowFrame,
                interaction: interaction,
                region: region,
                activationDistance: activationDistance,
                gap: max(0, gap)
            )
        }
        guard let best = allCandidates.min(by: { lhs, rhs in
            if abs(lhs.distance - rhs.distance) > 0.000_1 {
                return lhs.distance < rhs.distance
            }
            return lhs.priority < rhs.priority
        }) else {
            return nil
        }
        return WindowEdgeSnapAdjustment(
            displayIdentity: best.displayIdentity,
            targetFrame: best.targetFrame
        )
    }

    static func accessibilityFrame(
        forCocoaFrame cocoaFrame: CGRect,
        cocoaDisplayFrame: CGRect,
        accessibilityDisplayFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: accessibilityDisplayFrame.minX
                + cocoaFrame.minX
                - cocoaDisplayFrame.minX,
            y: accessibilityDisplayFrame.maxY
                - (cocoaFrame.minY - cocoaDisplayFrame.minY)
                - cocoaFrame.height,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    private struct Candidate {
        let displayIdentity: DisplayIdentity
        let targetFrame: CGRect
        let distance: CGFloat
        let priority: Int
    }

    private static func candidates(
        for windowFrame: CGRect,
        interaction: WindowEdgeSnapInteraction,
        region: WindowEdgeSnapRegion,
        activationDistance: CGFloat,
        gap: CGFloat
    ) -> [Candidate] {
        if region.position != .bottom {
            return candidates(
                for: region.position.canonicalAccessibilityFrame(windowFrame), interaction: interaction,
                region: WindowEdgeSnapRegion(displayIdentity: region.displayIdentity,
                    frame: region.position.canonicalAccessibilityFrame(region.frame)),
                activationDistance: activationDistance, gap: gap
            ).map { candidate in
                Candidate(displayIdentity: candidate.displayIdentity,
                          targetFrame: region.position.physicalAccessibilityFrame(candidate.targetFrame),
                          distance: candidate.distance, priority: candidate.priority)
            }
        }
        let dockFrame = region.frame
        guard dockFrame.width > 0, dockFrame.height > 0 else { return [] }

        var candidates: [Candidate] = []
        let verticalOverlap = overlap(
            windowFrame.minY...windowFrame.maxY,
            dockFrame.minY...dockFrame.maxY
        )
        if verticalOverlap >= minimumOverlap {
            let targetLeft = dockFrame.maxX + gap
            appendHorizontalCandidate(
                windowFrame: windowFrame,
                targetEdge: targetLeft,
                currentEdge: windowFrame.minX,
                keepsMaximumEdge: true,
                interaction: interaction,
                displayIdentity: region.displayIdentity,
                activationDistance: activationDistance,
                priority: 0,
                to: &candidates
            )

            let targetRight = dockFrame.minX - gap
            appendHorizontalCandidate(
                windowFrame: windowFrame,
                targetEdge: targetRight,
                currentEdge: windowFrame.maxX,
                keepsMaximumEdge: false,
                interaction: interaction,
                displayIdentity: region.displayIdentity,
                activationDistance: activationDistance,
                priority: 1,
                to: &candidates
            )
        }

        let horizontalOverlap = overlap(
            windowFrame.minX...windowFrame.maxX,
            dockFrame.minX...dockFrame.maxX
        )
        let targetBottom = dockFrame.minY - gap
        let bottomDistance = abs(windowFrame.maxY - targetBottom)
        if horizontalOverlap >= minimumOverlap,
           windowFrame.minY < dockFrame.minY,
           bottomDistance > minimumCorrection,
           bottomDistance <= activationDistance {
            let targetFrame: CGRect
            switch interaction {
            case .move:
                targetFrame = CGRect(
                    x: windowFrame.minX,
                    y: targetBottom - windowFrame.height,
                    width: windowFrame.width,
                    height: windowFrame.height
                )
            case .resize:
                targetFrame = CGRect(
                    x: windowFrame.minX,
                    y: windowFrame.minY,
                    width: windowFrame.width,
                    height: targetBottom - windowFrame.minY
                )
            }
            if targetFrame.height > 0 {
                candidates.append(Candidate(
                    displayIdentity: region.displayIdentity,
                    targetFrame: targetFrame,
                    distance: bottomDistance,
                    priority: 2
                ))
            }
        }
        return candidates
    }

    private static func appendHorizontalCandidate(
        windowFrame: CGRect,
        targetEdge: CGFloat,
        currentEdge: CGFloat,
        keepsMaximumEdge: Bool,
        interaction: WindowEdgeSnapInteraction,
        displayIdentity: DisplayIdentity,
        activationDistance: CGFloat,
        priority: Int,
        to candidates: inout [Candidate]
    ) {
        let distance = abs(currentEdge - targetEdge)
        guard distance > minimumCorrection,
              distance <= activationDistance else {
            return
        }

        let targetFrame: CGRect
        switch interaction {
        case .move:
            targetFrame = CGRect(
                x: keepsMaximumEdge ? targetEdge : targetEdge - windowFrame.width,
                y: windowFrame.minY,
                width: windowFrame.width,
                height: windowFrame.height
            )
        case .resize:
            if keepsMaximumEdge {
                targetFrame = CGRect(
                    x: targetEdge,
                    y: windowFrame.minY,
                    width: windowFrame.maxX - targetEdge,
                    height: windowFrame.height
                )
            } else {
                targetFrame = CGRect(
                    x: windowFrame.minX,
                    y: windowFrame.minY,
                    width: targetEdge - windowFrame.minX,
                    height: windowFrame.height
                )
            }
        }
        guard targetFrame.width > 0 else { return }
        candidates.append(Candidate(
            displayIdentity: displayIdentity,
            targetFrame: targetFrame,
            distance: distance,
            priority: priority
        ))
    }

    private static func overlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }
}

enum WindowReservationMetrics {
    /// EchoDock's body is `iconSize + 24` points and is positioned 6 points
    /// above the display edge. Keep the same clearance used by interactive
    /// snapping above the resting glass body. Magnification is intentionally
    /// allowed to float over windows, matching the native Dock's behavior.
    static func reservedHeight(iconSize: CGFloat) -> CGFloat {
        max(0, iconSize) + 30 + WindowEdgeSnapGeometryPolicy.defaultGap
    }
}

/// Side-effect-free policy used by the AX service and by geometry unit tests.
enum WindowReservationGeometryPolicy {
    static let defaultEdgeTolerance: CGFloat = 12
    static let defaultFrameTolerance: CGFloat = 2

    /// Use the same resting body that is actually displayed. No region means
    /// no companion here, including an external display hosting the native Dock.
    static func visibleCompanionGeometry(
        _ display: WindowReservationDisplayGeometry,
        regions: [WindowEdgeSnapRegion]
    ) -> WindowReservationDisplayGeometry? {
        guard let region = regions.first(where: {
            $0.displayIdentity == display.identity && $0.position == display.position
        }), region.frame.width > 0, region.frame.height > 0,
              display.frame.contains(region.frame) else { return nil }
        let canonicalDisplay = display.position.canonicalAccessibilityFrame(display.frame)
        let canonicalBody = display.position.canonicalAccessibilityFrame(region.frame)
        let actualHeight = canonicalDisplay.maxY - canonicalBody.minY + WindowEdgeSnapGeometryPolicy.defaultGap
        guard actualHeight.isFinite, actualHeight > 0, actualHeight < canonicalDisplay.height else { return nil }
        return WindowReservationDisplayGeometry(identity: display.identity, frame: display.frame,
            visibleFrame: display.visibleFrame, reservedHeight: max(display.reservedHeight, actualHeight),
            position: display.position)
    }

    static func isProtectedFullScreen(nativeFullScreen: Bool?, frame: CGRect, displayFrames: [CGRect]) -> Bool {
        nativeFullScreen == true || displayFrames.contains { framesApproximatelyEqual(frame, $0) }
    }

    static func adjustment(
        for windowFrame: CGRect,
        displays: [WindowReservationDisplayGeometry],
        edgeTolerance: CGFloat = defaultEdgeTolerance
    ) -> WindowReservationAdjustment? {
        guard let display = bestDisplay(for: windowFrame, displays: displays) else { return nil }
        if display.position != .bottom {
            return adjustment(for: display.position.canonicalAccessibilityFrame(windowFrame),
                              displays: [display.canonical], edgeTolerance: edgeTolerance).map {
                WindowReservationAdjustment(displayIdentity: $0.displayIdentity,
                    targetFrame: display.position.physicalAccessibilityFrame($0.targetFrame))
            }
        }
        guard !isLikelyFullScreen(
                windowFrame,
                in: display,
                edgeTolerance: defaultEdgeTolerance
              ),
              isMaximizedOrBottomTiled(
                windowFrame,
                in: display,
                edgeTolerance: edgeTolerance
              ) else {
            return nil
        }

        let availableFrame = display.availableFrame
        guard !availableFrame.isNull else { return nil }
        let targetBottom = availableFrame.maxY
        let targetFrame = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: targetBottom - windowFrame.minY
        )
        guard targetFrame.height > 0,
              windowFrame.maxY > targetBottom + defaultFrameTolerance,
              !framesApproximatelyEqual(windowFrame, targetFrame) else {
            return nil
        }
        return WindowReservationAdjustment(
            displayIdentity: display.identity,
            targetFrame: targetFrame
        )
    }

    /// Smallest window height an appearing window is shrunk to; below this it is left alone.
    static let minimumAppearingWindowHeight: CGFloat = 160

    /// A window (just appeared, swept, or moved/resized by its app; see
    /// WindowClearanceTriggerPolicy for when) with its bottom
    /// under the companion Dock. macOS only keeps windows clear of the native
    /// Dock, and on a display without it the system visible frame reaches the
    /// screen bottom, so apps such as Excel open document windows that run under
    /// the companion. Like AppKit does for the native Dock, keep the window
    /// clear: move it up if it fits, otherwise keep its top and shorten it.
    static func appearingWindowAdjustment(
        for windowFrame: CGRect,
        displays: [WindowReservationDisplayGeometry],
        regions: [WindowEdgeSnapRegion]
    ) -> WindowReservationAdjustment? {
        guard windowFrame.width > 0, windowFrame.height > 0,
              let display = bestDisplay(for: windowFrame, displays: displays) else { return nil }
        if display.position != .bottom {
            return appearingWindowAdjustment(
                for: display.position.canonicalAccessibilityFrame(windowFrame),
                displays: [display.canonical],
                regions: regions.filter { $0.displayIdentity == display.identity }.map {
                    WindowEdgeSnapRegion(displayIdentity: $0.displayIdentity,
                                         frame: display.position.canonicalAccessibilityFrame($0.frame))
                }
            ).map {
                WindowReservationAdjustment(displayIdentity: $0.displayIdentity,
                    targetFrame: display.position.physicalAccessibilityFrame($0.targetFrame))
            }
        }
        guard !isLikelyFullScreen(windowFrame, in: display) else { return nil }
        let available = display.availableFrame
        guard !available.isNull,
              windowFrame.maxY > available.maxY + defaultFrameTolerance,
              windowFrame.minY < available.maxY else { return nil }
        // Only windows the Dock bar actually covers.
        let bodies = regions.filter { $0.displayIdentity == display.identity }.map(\.frame)
        guard bodies.contains(where: { body in
            min(windowFrame.maxX, body.maxX) - max(windowFrame.minX, body.minX)
                >= WindowEdgeSnapGeometryPolicy.minimumOverlap
                && windowFrame.maxY > body.minY
        }) else { return nil }

        let overflow = windowFrame.maxY - available.maxY
        let target: CGRect
        if windowFrame.minY - overflow >= available.minY - defaultFrameTolerance {
            target = windowFrame.offsetBy(dx: 0, dy: -overflow)
        } else {
            let top = max(windowFrame.minY, available.minY)
            target = CGRect(x: windowFrame.minX, y: top,
                            width: windowFrame.width, height: available.maxY - top)
            guard target.height >= minimumAppearingWindowHeight else { return nil }
        }
        guard !framesApproximatelyEqual(windowFrame, target) else { return nil }
        return WindowReservationAdjustment(displayIdentity: display.identity, targetFrame: target)
    }

    static func bestDisplay(
        for windowFrame: CGRect,
        displays: [WindowReservationDisplayGeometry]
    ) -> WindowReservationDisplayGeometry? {
        displays
            .compactMap { display -> (WindowReservationDisplayGeometry, CGFloat)? in
                let intersection = windowFrame.intersection(display.frame)
                guard !intersection.isNull, !intersection.isEmpty else { return nil }
                return (display, intersection.width * intersection.height)
            }
            .max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsContainsCenter = lhs.0.frame.contains(windowFrame.center)
                let rhsContainsCenter = rhs.0.frame.contains(windowFrame.center)
                if lhsContainsCenter != rhsContainsCenter {
                    return !lhsContainsCenter
                }
                return lhs.0.identity.rawValue > rhs.0.identity.rawValue
            }?
            .0
    }

    static func isMaximizedOrBottomTiled(
        _ windowFrame: CGRect,
        in display: WindowReservationDisplayGeometry,
        edgeTolerance: CGFloat = defaultEdgeTolerance
    ) -> Bool {
        if display.position != .bottom {
            return isMaximizedOrBottomTiled(display.position.canonicalAccessibilityFrame(windowFrame),
                                           in: display.canonical, edgeTolerance: edgeTolerance)
        }
        let visible = display.visibleFrame
        guard windowFrame.width > 0,
              windowFrame.height > 0,
              visible.width > 0,
              visible.height > 0 else {
            return false
        }

        let isHorizontallyContained = windowFrame.minX >= visible.minX - edgeTolerance
            && windowFrame.maxX <= visible.maxX + edgeTolerance
        let isVerticallyContained = windowFrame.minY >= visible.minY - edgeTolerance
            && windowFrame.maxY <= visible.maxY + edgeTolerance
        let touchesBottom = abs(windowFrame.maxY - visible.maxY) <= edgeTolerance
        let startsAtTop = abs(windowFrame.minY - visible.minY) <= edgeTolerance
        let startsAtMiddle = abs(windowFrame.minY - visible.midY) <= edgeTolerance
        let usesHorizontalTileGrid = horizontalEdgesUseTileGrid(
            windowFrame,
            visibleFrame: visible,
            edgeTolerance: edgeTolerance
        )

        return isHorizontallyContained
            && isVerticallyContained
            && touchesBottom
            && usesHorizontalTileGrid
            && (startsAtTop || startsAtMiddle)
    }

    private static func horizontalEdgesUseTileGrid(
        _ windowFrame: CGRect,
        visibleFrame: CGRect,
        edgeTolerance: CGFloat
    ) -> Bool {
        let fractions: [CGFloat] = [0, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1]
        let gridEdges = fractions.map { visibleFrame.minX + visibleFrame.width * $0 }
        let leadingMatches = gridEdges.contains {
            abs(windowFrame.minX - $0) <= edgeTolerance
        }
        let trailingMatches = gridEdges.contains {
            abs(windowFrame.maxX - $0) <= edgeTolerance
        }
        return leadingMatches && trailingMatches
    }

    /// Accessibility does not publish a documented full-screen state
    /// attribute. A window matching the physical display bounds is therefore
    /// treated conservatively as full-screen and is never resized.
    static func isLikelyFullScreen(
        _ windowFrame: CGRect,
        in display: WindowReservationDisplayGeometry,
        edgeTolerance: CGFloat = defaultFrameTolerance
    ) -> Bool {
        framesApproximatelyEqual(
            windowFrame,
            display.frame,
            tolerance: edgeTolerance
        )
    }

    static func framesApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = defaultFrameTolerance
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

/// Decides when a window covered by the companion Dock is kept clear of it.
/// macOS keeps windows clear of the native Dock only; on a display without it
/// apps open, restore, or zoom windows to the full screen height under the
/// companion. A window is cleared when it is first seen (created, already open
/// when reservation starts, or seen again after the observers were re-armed),
/// and whenever the app itself moves or resizes it (zoom, saved frame restored
/// late, the app's own layout). A change made while a mouse button is held is
/// the user's: that window is left where the user put it and not swept again
/// until the app moves it. Repeated adjustments are capped so SameDock never
/// fights an app that insists on its frame.
enum WindowClearanceTriggerPolicy {
    enum Trigger: Equatable {
        case firstEvaluation
        case applicationChange
    }

    /// A frame change within this time of a mouse-down frame change is the user's.
    static let userInteractionWindow: TimeInterval = 0.75
    static let burstInterval: TimeInterval = 5
    static let maximumAdjustmentsPerBurst = 3

    static func isUserDriven(lastUserInteraction: Date?, now: Date) -> Bool {
        guard let lastUserInteraction else { return false }
        return now.timeIntervalSince(lastUserInteraction) <= userInteractionWindow
    }

    static func trigger(
        isFirstEvaluation: Bool,
        frameChanged: Bool,
        lastUserInteraction: Date?,
        isUserPlaced: Bool,
        recentAdjustmentCount: Int,
        now: Date
    ) -> Trigger? {
        guard recentAdjustmentCount < maximumAdjustmentsPerBurst else { return nil }
        if frameChanged {
            if isUserDriven(lastUserInteraction: lastUserInteraction, now: now) { return nil }
            return .applicationChange
        }
        if isFirstEvaluation && !isUserPlaced { return .firstEvaluation }
        return nil
    }
}
