import AppKit
import Testing
@testable import EchoDock

/// Closing or restoring a minimized window shrinks the Dock content at once,
/// while the window is resized on a later run-loop turn. Installed 1.1.7
/// committed one frame in between with the whole Dock shifted by half the
/// width change (60 fps capture: 20-24 of 40 panel blocks flashed).
@MainActor
struct DockPanelContentAnchorTests {
    private let display = NSRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test(arguments: [DockPosition.bottom, .top, .left, .right])
    func shrunkContentKeepsItsFinalScreenPlaceBeforeTheWindowResizes(position: DockPosition) {
        let oldSize = position.layoutSize(for: NSSize(width: 1070, height: 79))
        let newSize = position.layoutSize(for: NSSize(width: 1010, height: 79))
        let current = position.panelFrame(size: oldSize, display: display)
        let target = position.panelFrame(size: newSize, display: display)
        let origin = DockPanelContentAnchorPolicy.contentOrigin(panelFrame: current, targetPanelFrame: target)
        // On screen, content = window origin + content origin = final frame.
        #expect(current.minX + origin.x == target.minX)
        #expect(current.minY + origin.y == target.minY)
        #expect(origin != .zero)
    }

    @Test(arguments: [DockPosition.bottom, .top, .left, .right])
    func grownContentIsAlsoPlacedAtItsFinalScreenPlace(position: DockPosition) {
        let oldSize = position.layoutSize(for: NSSize(width: 1010, height: 79))
        let newSize = position.layoutSize(for: NSSize(width: 1070, height: 79))
        let current = position.panelFrame(size: oldSize, display: display)
        let target = position.panelFrame(size: newSize, display: display)
        let origin = DockPanelContentAnchorPolicy.contentOrigin(panelFrame: current, targetPanelFrame: target)
        #expect(current.minX + origin.x == target.minX)
        #expect(current.minY + origin.y == target.minY)
    }

    @Test
    func bottomDockShrinkOffsetsByHalfTheWidthChange() {
        let current = DockPosition.bottom.panelFrame(size: NSSize(width: 1070, height: 79), display: display)
        let target = DockPosition.bottom.panelFrame(size: NSSize(width: 1010, height: 79), display: display)
        #expect(DockPanelContentAnchorPolicy.contentOrigin(panelFrame: current, targetPanelFrame: target) == NSPoint(x: 30, y: 0))
        #expect(DockPanelContentAnchorPolicy.contentOrigin(panelFrame: target, targetPanelFrame: target) == .zero)
    }

    @Test
    func presentedContentStaysPutAcrossTheDeferredWindowResize() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1070, height: 79))
        let presentation = DockPanelPresentationView(presentedView: content)
        let oldFrame = DockPosition.bottom.panelFrame(size: content.frame.size, display: display)
        presentation.frame = NSRect(origin: .zero, size: oldFrame.size)

        // Removal finished: the content shrinks first ...
        content.setFrameSize(NSSize(width: 1010, height: 79))
        let target = DockPosition.bottom.panelFrame(size: content.frame.size, display: display)
        presentation.setPresentedOrigin(DockPanelContentAnchorPolicy.contentOrigin(panelFrame: oldFrame, targetPanelFrame: target))
        let beforeResize = content.frame.offsetBy(dx: oldFrame.minX, dy: oldFrame.minY)

        // ... and the window follows on a later turn.
        presentation.frame = NSRect(origin: .zero, size: target.size)
        presentation.setPresentedOrigin(.zero)
        let afterResize = content.frame.offsetBy(dx: target.minX, dy: target.minY)

        #expect(beforeResize == afterResize)
        #expect(afterResize == target)
        #expect(content.frame.origin == .zero)
    }
}
