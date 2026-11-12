import AppKit
import Testing
@testable import EchoDock

struct DockWindowLevelTests {
    @Test func ordinaryWindowsStayBehindDockAndPopupSurfacesStayAboveIt() {
        let dock = EchoDockWindowLevel.dock.rawValue
        let receiver = EchoDockWindowLevel.dragReceiver.rawValue
        #expect(NSWindow.Level.normal.rawValue < dock)
        #expect(dock < receiver)
        // Verify against platform levels, not a hardcoded numerical snapshot.
        for popup in [NSWindow.Level.floating, .modalPanel, .popUpMenu] {
            #expect(receiver < popup.rawValue)
        }
    }

    @Test func floatingInputCandidatesDoNotHideDockAtItsActualLevel() {
        let frame = CGRect(x: 0, y: 800, width: 600, height: 70)
        let region = InputCandidateDockRegion(
            displayIdentity: DisplayIdentity(rawValue: "test-display"), frame: frame)
        let candidate = InputCandidateWindowSnapshot(bounds: frame,
            layer: NSWindow.Level.floating.rawValue, ownerProcessIdentifier: 123,
            isRegularApplication: false, ownerBundleIdentifier: "test.inputmethod",
            alpha: 1, isOnScreen: true)
        // This same overlapping candidate required avoidance with the old
        // system Dock band. The current layer already leaves it unobstructed.
        #expect(!InputCandidateAvoidancePolicy.occludedDisplayIdentities(
            regions: [region], windows: [candidate], excludingProcessIdentifier: 42,
            dockWindowLevel: Int(CGWindowLevelForKey(.dockWindow))).isEmpty)
        #expect(InputCandidateAvoidancePolicy.occludedDisplayIdentities(
            regions: [region], windows: [candidate], excludingProcessIdentifier: 42).isEmpty)
    }
}
