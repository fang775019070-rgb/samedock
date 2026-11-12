import CoreGraphics
import Testing
@testable import EchoDock

/// T270LG main display at 1920x1080 points with the native Dock on another
/// screen: the system visible frame reaches the bottom, so Excel opened its
/// workbook window under the companion Dock (installed 1.1.8 left it there
/// because the window was not exactly maximized or tiled).
struct WindowAppearingReservationTests {
    private let id = DisplayIdentity(rawValue: "main")
    private var display: WindowReservationDisplayGeometry {
        WindowReservationDisplayGeometry(
            identity: id,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050),
            reservedHeight: WindowReservationMetrics.reservedHeight(iconSize: 55))
    }
    // SameDock body (resting glass) in AX coordinates, as on this Mac.
    private var body: WindowEdgeSnapRegion {
        WindowEdgeSnapRegion(displayIdentity: id, frame: CGRect(x: 365, y: 995, width: 1190, height: 79))
    }

    @Test func largeFreeFormWindowUnderTheDockIsShortenedKeepingItsTop() throws {
        // Not on the tile grid, so the maximized/tiled rule ignores it.
        let excel = CGRect(x: 37, y: 52, width: 1810, height: 1028)
        #expect(WindowReservationGeometryPolicy.adjustment(for: excel, displays: [display]) == nil)
        let a = try #require(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: excel, displays: [display], regions: [body]))
        #expect(a.targetFrame.minY == 52)
        #expect(a.targetFrame.minX == 37 && a.targetFrame.width == 1810)
        #expect(a.targetFrame.maxY == display.availableFrame.maxY)
        #expect(a.targetFrame.maxY <= body.frame.minY)
    }

    @Test func windowThatFitsAboveTheDockIsMovedUpNotResized() throws {
        let w = CGRect(x: 500, y: 500, width: 800, height: 560)
        let a = try #require(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: w, displays: [display], regions: [body]))
        #expect(a.targetFrame.size == w.size)
        #expect(a.targetFrame.maxY == display.availableFrame.maxY)
    }

    @Test func windowsTheDockDoesNotCoverAreLeftAlone() {
        // Beside the Dock bar, above it, or full screen.
        #expect(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: CGRect(x: 0, y: 600, width: 340, height: 480), displays: [display], regions: [body]) == nil)
        #expect(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: CGRect(x: 400, y: 100, width: 900, height: 700), displays: [display], regions: [body]) == nil)
        #expect(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: CGRect(x: 0, y: 0, width: 1920, height: 1080), displays: [display], regions: [body]) == nil)
    }

    @Test func windowsOnAScreenWithoutTheCompanionAreLeftAlone() {
        // e.g. the built-in display hosting the native Dock.
        #expect(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: CGRect(x: 300, y: 1200, width: 1000, height: 836), displays: [display], regions: [body]) == nil)
    }

    @Test func tinyLeftoverHeightIsNotForced() {
        let w = CGRect(x: 500, y: 960, width: 600, height: 120)
        // Moving up fits, so it moves rather than shrinks.
        let moved = WindowReservationGeometryPolicy.appearingWindowAdjustment(for: w, displays: [display], regions: [body])
        #expect(moved?.targetFrame.height == 120)
        // A display too short to keep 160 pt above the Dock: leave it.
        let short = WindowReservationDisplayGeometry(identity: id, frame: CGRect(x: 0, y: 0, width: 1920, height: 300),
            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 270), reservedHeight: 116)
        let shortBody = WindowEdgeSnapRegion(displayIdentity: id, frame: CGRect(x: 365, y: 215, width: 1190, height: 79))
        #expect(WindowReservationGeometryPolicy.appearingWindowAdjustment(
            for: CGRect(x: 100, y: 30, width: 1700, height: 270), displays: [short], regions: [shortBody]) == nil)
    }
}
