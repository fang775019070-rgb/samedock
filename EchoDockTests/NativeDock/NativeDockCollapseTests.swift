import AppKit
import Testing
@testable import EchoDock

/// Closing a minimized window or quitting an app collapses its Dock slot and
/// slides every neighbour. Native Dock never blanks or shows in-between frames.
@Suite @MainActor
struct NativeDockCollapseTests {
    typealias Policy = NativeDockThumbnailPublishPolicy

    /// A window thumbnail: light body with a coloured block, optionally slid
    /// sideways with a dark gap (what a crop sees while the slot is moving).
    private func tile(shift: Int = 0, block: (UInt8, UInt8, UInt8) = (0, 220, 240),
                      width: Int = 96, height: Int = 64) -> NativeDockThumbnail.Fingerprint {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let source = x - shift
            let inside = source >= 0 && source < width
            let isBlock = inside && source > width / 4 && source < width * 3 / 4 && y > height / 4 && y < height * 3 / 4
            let c: (UInt8, UInt8, UInt8) = !inside ? (12, 12, 14) : isBlock ? block : (236, 236, 236)
            pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
        } }
        let image = pixels.withUnsafeMutableBytes { storage -> CGImage in
            CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        return NativeDockThumbnail.Fingerprint(image)!
    }

    /// Replays captures of one visible tile through the policy and returns
    /// which fingerprints were shown, in order.
    private func replay(_ captures: [NativeDockThumbnail.Fingerprint], initial: NativeDockThumbnail.Fingerprint)
        -> (shown: [NativeDockThumbnail.Fingerprint], published: Int) {
        var published = initial
        var pending: NativeDockThumbnail.Fingerprint?
        var shown = [initial], count = 0
        for capture in captures {
            switch Policy.decide(hasPublishedImage: true, published: published, pending: pending, candidate: capture) {
            case .keep: pending = nil
            case .confirm: pending = capture
            case .publish: published = capture; pending = nil; count += 1
            }
            shown.append(published)
        }
        return (shown, count)
    }

    @Test func slidingNeighbourKeepsItsLastGoodImageThroughTheWholeCollapse() {
        let settled = tile()
        // Mid-slide crops: progressively shifted with a dark edge, then settled.
        let collapse = [tile(shift: 30), tile(shift: 22), tile(shift: 12), tile(shift: 4), settled, settled]
        let result = replay(collapse, initial: settled)
        #expect(result.published == 0)
        #expect(result.shown.allSatisfy { $0.matches(settled) })
    }

    @Test func aSingleOddFrameNeverReplacesAVisibleThumbnail() {
        let settled = tile()
        let result = replay([tile(shift: 40), settled, tile(shift: 18), settled], initial: settled)
        #expect(result.published == 0)
    }

    @Test func genuinelyChangedArtworkIsShownOnceItRepeats() {
        let old = tile(block: (255, 0, 255))
        let new = tile(block: (255, 220, 0))
        let result = replay([tile(shift: 25), new, new, new], initial: old)
        #expect(result.published == 1)
        #expect(result.shown[1].matches(old))   // in-flight frame not shown
        #expect(result.shown[2].matches(old))   // first sighting only remembered
        #expect(result.shown[3].matches(new))   // confirmed by a second capture
    }

    @Test func windowsWithoutArtworkAndYoungFirstImagesStayFast() {
        // Minimize speed: a new tile publishes on its first valid capture, and
        // its in-flight first image is corrected without waiting for a repeat.
        #expect(Policy.decide(hasPublishedImage: false, published: nil, pending: nil, candidate: tile()) == .publish)
        #expect(Policy.decide(hasPublishedImage: true, published: tile(shift: 30), pending: nil,
                              candidate: tile(), publishedAge: 0.4) == .publish)
        #expect(Policy.decide(hasPublishedImage: true, published: tile(shift: 30), pending: nil,
                              candidate: tile(), publishedAge: 5) == .confirm)
        #expect(Policy.decide(hasPublishedImage: true, published: tile(), pending: nil,
                              candidate: tile(), publishedAge: 0.4) == .keep)
    }

    @Test func unreadableCaptureKeepsThePublishedImage() {
        #expect(Policy.decide(hasPublishedImage: true, published: tile(), pending: nil, candidate: nil) == .keep)
    }

    @Test func screenParameterChurnDoesNotDiscardThumbnails() {
        // App launch/quit resizes Dock and posts a screen-parameter change; the
        // re-identified surface on the same display keeps every image.
        #expect(!Policy.discardsImages(previousDisplayID: nil, newDisplayID: 1))
        #expect(!Policy.discardsImages(previousDisplayID: 1, newDisplayID: 1))
        #expect(Policy.discardsImages(previousDisplayID: 1, newDisplayID: 2))
    }

    @Test func removedWindowLeavesTheProjectionWhileNeighboursKeepTheirPlace() {
        let app = NativeDockEntry(id: "a", title: "App", subrole: "AXApplicationDockItem",
            url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), badge: nil, running: true,
            frame: CGRect(x: 0, y: 0, width: 59, height: 59))
        func window(_ id: String, _ x: CGFloat) -> NativeDockEntry {
            NativeDockEntry(id: id, title: id, subrole: "AXMinimizedWindowDockItem", url: nil, badge: nil,
                running: false, frame: CGRect(x: x, y: 0, width: 59, height: 59))
        }
        let after = [app, window("w2", 70), window("w3", 129)]   // w1 closed, neighbours slid left
        let items = NativeDockContentSync.project(fallback: [], entries: after, trashFull: false,
            imageRevision: 2, availableWindowIDs: ["w1", "w2", "w3"])
        let ids = items.compactMap { item -> String? in
            if case .nativeDockItem(let id, true) = item.kind { return id }; return nil
        }
        #expect(ids == ["w2", "w3"])
    }

    @Test func closedWindowTileCollapsesWithAnimationInsteadOfJumping() {
        let app = NativeDockEntry(id: "a", title: "App", subrole: "AXApplicationDockItem",
            url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), badge: nil, running: true,
            frame: CGRect(x: 0, y: 0, width: 59, height: 59))
        func window(_ id: String) -> NativeDockEntry {
            NativeDockEntry(id: id, title: id, subrole: "AXMinimizedWindowDockItem", url: nil, badge: nil,
                running: false, frame: CGRect(x: 70, y: 0, width: 59, height: 59))
        }
        func snapshot(_ entries: [NativeDockEntry], _ revision: UInt64) -> DockSnapshot {
            let items = NativeDockContentSync.project(fallback: [], entries: entries, trashFull: false,
                imageRevision: revision, availableWindowIDs: ["w1", "w2"])
            return DockSnapshot(revision: revision, items: items, pinnedItemCount: 0, syncStatus: .normal)
        }
        let before = snapshot([app, window("w1"), window("w2")], 1)
        let after = snapshot([app, window("w2")], 2)
        let removed = DockNativeWindowRemovalPolicy.removedIdentities(previous: before, next: after, animationsEnabled: true)
        #expect(removed == [ApplicationIdentity(rawValue: "w1")])
        #expect(DockNativeWindowRemovalPolicy.removedIdentities(previous: before, next: after, animationsEnabled: false).isEmpty)
        #expect(DockNativeWindowRemovalPolicy.removedIdentities(previous: before, next: before, animationsEnabled: true).isEmpty)
    }

    @Test func closingTileKeepsItsArtworkOnlyWhileItsSlotCollapses() {
        let art = NSImage(size: CGSize(width: 10, height: 10))
        var departing = NativeDockContentSync.departing(images: ["w1": art, "w2": art], previous: [:],
            validIDs: ["w2"], now: 10)
        #expect(Set(departing.keys) == ["w1"])          // closed window keeps its last image
        departing = NativeDockContentSync.departing(images: ["w2": art], previous: departing, validIDs: ["w2"], now: 10.6)
        #expect(Set(departing.keys) == ["w1"])          // still collapsing
        departing = NativeDockContentSync.departing(images: ["w2": art], previous: departing, validIDs: ["w2"], now: 11.1)
        #expect(departing.isEmpty)                       // gone after the collapse
        // A restored window that reappears is live again, not departing.
        departing = NativeDockContentSync.departing(images: [:], previous: ["w1": (art, 10)], validIDs: ["w1"], now: 10.2)
        #expect(departing.isEmpty)
    }
}
