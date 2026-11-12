import AppKit
import Testing
@testable import EchoDock

@MainActor
struct NativeDockContentSyncTests {
    private func application(_ name: String, section: DockItemSection = .running) -> DockItem {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        return DockItem(identity: ApplicationIdentity(bundleIdentifier: nil, applicationURL: url),
            bundleIdentifier: nil, applicationURL: url, displayName: name, section: section,
            isRunning: true, isActive: false, isHidden: false, transientState: .normal)
    }
    private func entry(_ id: String, _ title: String, _ role: String, url: URL? = nil, badge: String? = nil) -> NativeDockEntry {
        NativeDockEntry(id: id, title: title, subrole: role, url: url, badge: badge,
            running: true, frame: CGRect(x: 10, y: 10, width: 55, height: 55))
    }
    private var trash: DockItem {
        DockItem(identity: ApplicationIdentity(rawValue: "system:trash"), bundleIdentifier: nil,
            applicationURL: URL(fileURLWithPath: "/tmp/Trash"), displayName: "Trash", section: .files,
            kind: .trash, isRunning: false, isActive: false, isHidden: false, transientState: .normal)
    }
    @Test func mirrorsOrderAndBadgesAndKeepsSameTitleWindowsDistinct() {
        let a = application("A", section: .pinned), b = application("B")
        let native = [entry("b", "B", "AXApplicationDockItem", url: b.applicationURL, badge: "12"),
            entry("a", "A", "AXApplicationDockItem", url: a.applicationURL),
            entry("w1", "Same title", "AXMinimizedWindowDockItem"),
            entry("w2", "Same title", "AXMinimizedWindowDockItem")]
        let items = NativeDockContentSync.project(fallback: [a, b, trash], entries: native,
            trashFull: true, imageRevision: 7, availableWindowIDs: ["w1", "w2"])
        #expect(items.map(\.displayName) == ["B", "A", "Same title", "Same title", "Trash"])
        #expect(items[0].badgeLabel == "12")
        #expect(items[1].section == .pinned)
        #expect(items[2].identity != items[3].identity)
        #expect(items[2].nativeImageRevision == 7)
        #expect(items.last?.nativeTrashFull == true)
        #expect(!items[2].isRunning)
    }
    @Test func missingPermissionsOrIncompleteNativeListRetainsWorkingFallback() {
        let fallback = [application("A"), trash]
        #expect(NativeDockContentSync.project(fallback: fallback, entries: [], trashFull: true, imageRevision: 0) == fallback)
        #expect(NativeDockContentSync.project(fallback: fallback,
            entries: [entry("a", "A", "AXApplicationDockItem")], trashFull: true, imageRevision: 0) == fallback)
    }
    @Test func restoredWindowsAndClearedBadgesDisappearOnNextSnapshot() {
        let a = application("A")
        let native = [entry("a", "A", "AXApplicationDockItem", url: a.applicationURL)]
        let items = NativeDockContentSync.project(fallback: [a, trash], entries: native, trashFull: false, imageRevision: 1)
        #expect(items.count == 2)
        #expect(items[0].badgeLabel == nil)
        #expect(items.last?.nativeTrashFull == false)
    }
    @Test func windowContextMenuOnlyRestoresTheSelectedWindow() {
        let a = application("A")
        let native = [entry("a", "A", "AXApplicationDockItem", url: a.applicationURL),
                      entry("w", "Window", "AXMinimizedWindowDockItem")]
        let items = NativeDockContentSync.project(fallback: [a, trash], entries: native,
            trashFull: false, imageRevision: 0, availableWindowIDs: ["w"])
        let menu = DockItemContextMenuBuilder.make(for: items[1])
        #expect(menu.options.isEmpty)
        #expect(menu.commands.map(\.action) == [.open])
        #expect(menu.commands[0].isEnabled)
    }

    @Test func missingArtworkHidesOnlyThatWindowAndRecoveryKeepsTheCompleteSourceList() {
        let a = application("A")
        let native = [entry("a", "A", "AXApplicationDockItem", url: a.applicationURL),
            entry("w1", "First window", "AXMinimizedWindowDockItem"),
            entry("file", "Document", "AXFileDockItem", url: URL(fileURLWithPath: "/tmp/document.pdf")),
            entry("w2", "Second window", "AXMinimizedWindowDockItem")]
        let partial = NativeDockContentSync.project(fallback: [a, trash], entries: native,
            trashFull: true, imageRevision: 1, availableWindowIDs: ["w2"])
        #expect(partial.map(\.displayName) == ["A", "Document", "Second window", "Trash"])
        #expect(partial.last?.nativeTrashFull == true)
        let recovered = NativeDockContentSync.project(fallback: [a, trash], entries: native,
            trashFull: true, imageRevision: 2, availableWindowIDs: ["w1", "w2"])
        #expect(recovered.map(\.displayName) == ["A", "First window", "Document", "Second window", "Trash"])
        // Presentation filtering must never consume or mutate the raw capture source.
        #expect(native.filter(\.isWindow).map(\.id) == ["w1", "w2"])
        let noArtwork = NativeDockContentSync.project(fallback: [a, trash], entries: native,
            trashFull: true, imageRevision: 3)
        #expect(noArtwork.map(\.displayName) == ["A", "Document", "Trash"])
    }
}
