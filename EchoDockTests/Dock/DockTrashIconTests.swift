import AppKit
import Testing
@testable import EchoDock

struct DockTrashIconTests {
    @Test @MainActor func emptyAndFullTrashKeepDetailedNativeArtwork() throws {
        var rasterData: [Data] = []
        for full in [false, true] {
            let name = NSImage.Name(full ? "NSTrashFull" : "NSTrashEmpty")
            let catalogSize = NSImage(named: name)?.size
            // Native state must work without enumerating the user's Trash.
            let icon = try #require(DockTrashIconProvider.image(
                for: URL(fileURLWithPath: "/nonexistent-trash-fixture"), nativeFull: full))
            var rect = NSRect(origin: .zero, size: icon.size)
            let raster = try #require(icon.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            // A 128-point icon at 1.8x hover magnification and 2x Retina needs
            // 461 pixels. Test the actual raster supplied to CALayer, not size.
            #expect(raster.width >= 461)
            #expect(raster.height >= 461)
            #expect(NSImage(named: name)?.size == catalogSize)
            rasterData.append(try #require(raster.dataProvider?.data) as Data)
        }
        #expect(rasterData[0] != rasterData[1])
    }
}
