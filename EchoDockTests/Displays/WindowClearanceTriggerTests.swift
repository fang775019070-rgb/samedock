import CoreGraphics
import Foundation
import Testing
@testable import EchoDock

/// 1.1.9 cleared only windows within 1.5 s of being seen. Word's document
/// window was zoomed by Word itself to the full visible height
/// (335,30 1178x1050 on the T270LG, bar at 425,995) long after it appeared, so
/// its page and status bar stayed under the bar.
struct WindowClearanceTriggerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let id = DisplayIdentity(rawValue: "main")
    private var display: WindowReservationDisplayGeometry {
        WindowReservationDisplayGeometry(
            identity: id,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050),
            reservedHeight: WindowReservationMetrics.reservedHeight(iconSize: 55))
    }
    private var body: WindowEdgeSnapRegion {
        WindowEdgeSnapRegion(displayIdentity: id, frame: CGRect(x: 425, y: 995, width: 1070, height: 79))
    }

    private func trigger(first: Bool = false, changed: Bool = false, user: TimeInterval? = nil,
                         placed: Bool = false, recent: Int = 0) -> WindowClearanceTriggerPolicy.Trigger? {
        WindowClearanceTriggerPolicy.trigger(
            isFirstEvaluation: first, frameChanged: changed,
            lastUserInteraction: user.map { now.addingTimeInterval(-$0) },
            isUserPlaced: placed, recentAdjustmentCount: recent, now: now)
    }

    @Test func zoomedWordWindowIsShortenedToTheBar() throws {
        let word = CGRect(x: 335, y: 30, width: 1178, height: 1050)
        #expect(WindowReservationGeometryPolicy.adjustment(for: word, displays: [display]) == nil)
        let a = try #require(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: word, displays: [display], regions: [body]))
        #expect(a.targetFrame == CGRect(x: 335, y: 30, width: 1178, height: display.availableFrame.maxY - 30))
        #expect(a.targetFrame.maxY <= body.frame.minY)
    }

    @Test func applicationMoveOrResizeLongAfterAppearingIsCleared() {
        #expect(trigger(changed: true) == .applicationChange)
        // Mouse released well before the app changed the frame (e.g. green zoom button click).
        #expect(trigger(changed: true, user: 2) == .applicationChange)
        // Even a window the user had put over the bar, once the app moves it.
        #expect(trigger(changed: true, placed: true) == .applicationChange)
    }

    @Test func userDragIsNeverFought() {
        #expect(trigger(changed: true, user: 0) == nil)
        #expect(trigger(changed: true, user: 0.5) == nil)
        #expect(WindowClearanceTriggerPolicy.isUserDriven(lastUserInteraction: now.addingTimeInterval(-0.5), now: now))
        #expect(!WindowClearanceTriggerPolicy.isUserDriven(lastUserInteraction: nil, now: now))
    }

    @Test func existingWindowsAreSweptOnceButNotUserPlacedOnes() {
        #expect(trigger(first: true) == .firstEvaluation)
        #expect(trigger(first: true, placed: true) == nil)
        // Later focus changes or refreshes without a frame change do nothing.
        #expect(trigger() == nil)
        #expect(trigger(placed: true) == nil)
    }

    @Test func repeatedAdjustmentsAreCapped() {
        let cap = WindowClearanceTriggerPolicy.maximumAdjustmentsPerBurst
        #expect(trigger(changed: true, recent: cap - 1) == .applicationChange)
        #expect(trigger(changed: true, recent: cap) == nil)
        #expect(trigger(first: true, recent: cap) == nil)
    }
}
