import CoreGraphics
import Foundation
import Testing
@testable import EchoDock

@Suite @MainActor
struct WindowReservationBehaviorTests {
    private func display(_ id: String, frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)) -> WindowReservationDisplayGeometry {
        WindowReservationDisplayGeometry(identity: DisplayIdentity(rawValue: id), frame: frame,
            visibleFrame: CGRect(x: frame.minX, y: frame.minY + 24, width: frame.width, height: frame.height - 24),
            reservedHeight: WindowReservationMetrics.reservedHeight(iconSize: 48))
    }

    private func region(for display: WindowReservationDisplayGeometry, height: CGFloat = 72) -> WindowEdgeSnapRegion {
        WindowEdgeSnapRegion(displayIdentity: display.identity,
            frame: CGRect(x: display.frame.midX - 250, y: display.frame.maxY - height - 6,
                width: 500, height: height))
    }

    @Test func reservationDefaultsOnWithoutOverwritingAnExplicitOffPreference() {
        let name = "SameDockReservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = PreferencesStore(defaults: defaults)
        #expect(fresh.reserveSpaceForWindows)
        fresh.reserveSpaceForWindows = false
        #expect(!PreferencesStore(defaults: defaults).reserveSpaceForWindows)
    }

    @Test func onlyAVisibleCompanionCanReserveSpaceRegardlessOfNativeDisplayLocation() {
        let builtIn = display("built-in")
        let externalNative = display("external-native", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let projector = display("projector", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let regions = [region(for: builtIn), region(for: projector)]
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(builtIn, regions: regions) != nil)
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(projector, regions: regions) != nil)
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(externalNative, regions: regions) == nil)
        // Hidden or suppressed panels publish no resting region.
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(builtIn, regions: []) == nil)
    }

    @Test func maximizedExternalWindowStopsAboveTheActualRestingDockBody() throws {
        let external = display("external")
        let dock = region(for: external)
        let reserved = try #require(WindowReservationGeometryPolicy.visibleCompanionGeometry(external, regions: [dock]))
        let adjustment = try #require(WindowReservationGeometryPolicy.adjustment(for: external.visibleFrame, displays: [reserved]))
        #expect(adjustment.targetFrame.minY == external.visibleFrame.minY)
        #expect(adjustment.targetFrame.width == external.visibleFrame.width)
        #expect(adjustment.targetFrame.maxY == dock.frame.minY - 1)
        #expect(reserved.reservedHeight == 79)
    }

    @Test func actualPanelHeightAndVerticallyStackedDisplayCoordinatesAreRespected() throws {
        let upper = display("upper", frame: CGRect(x: -200, y: -1080, width: 1920, height: 1080))
        let dock = region(for: upper, height: 88)
        let reserved = try #require(WindowReservationGeometryPolicy.visibleCompanionGeometry(upper, regions: [dock]))
        let adjustment = try #require(WindowReservationGeometryPolicy.adjustment(for: upper.visibleFrame, displays: [reserved]))
        #expect(reserved.reservedHeight == 95)
        #expect(adjustment.targetFrame.maxY == dock.frame.minY - 1)
        #expect(adjustment.targetFrame.minX == -200)
        #expect(adjustment.targetFrame.minY == -1056)
    }

    @Test func ordinaryFloatingWindowIsUntouchedAndBottomTileKeepsItsWidth() throws {
        let external = display("external")
        let reserved = try #require(WindowReservationGeometryPolicy.visibleCompanionGeometry(external, regions: [region(for: external)]))
        #expect(WindowReservationGeometryPolicy.adjustment(for: CGRect(x: 200, y: 150, width: 600, height: 400), displays: [reserved]) == nil)
        let tile = CGRect(x: 0, y: external.visibleFrame.midY, width: 720, height: external.visibleFrame.height / 2)
        let adjustment = try #require(WindowReservationGeometryPolicy.adjustment(for: tile, displays: [reserved]))
        #expect(adjustment.targetFrame.width == tile.width)
        #expect(adjustment.targetFrame.minY == tile.minY)
        #expect(adjustment.targetFrame.maxY == reserved.availableFrame.maxY)
    }

    @Test func nativeFullScreenWithAMenuBarIsProtectedButOrdinaryMaximizationIsNot() {
        let external = display("external")
        #expect(WindowReservationGeometryPolicy.isProtectedFullScreen(nativeFullScreen: true,
            frame: external.visibleFrame, displayFrames: [external.frame]))
        #expect(!WindowReservationGeometryPolicy.isProtectedFullScreen(nativeFullScreen: false,
            frame: external.visibleFrame, displayFrames: [external.frame]))
        #expect(WindowReservationGeometryPolicy.isProtectedFullScreen(nativeFullScreen: nil,
            frame: external.frame, displayFrames: [external.frame]))
        #expect(WindowReservationGeometryPolicy.adjustment(for: external.frame, displays: [external]) == nil)
    }

    @Test func invalidOrWrongScreenPanelRegionsCannotReserveSpace() {
        let external = display("external")
        let outside = WindowEdgeSnapRegion(displayIdentity: external.identity,
            frame: CGRect(x: 0, y: 1500, width: 500, height: 72))
        let empty = WindowEdgeSnapRegion(displayIdentity: external.identity, frame: .zero)
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(external, regions: [outside]) == nil)
        #expect(WindowReservationGeometryPolicy.visibleCompanionGeometry(external, regions: [empty]) == nil)
    }
}
