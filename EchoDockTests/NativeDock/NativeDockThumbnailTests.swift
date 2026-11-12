import AppKit
import CoreVideo
import Testing
@testable import EchoDock

struct NativeDockThumbnailTests {
    private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    @Test func trimsOnlyTransparentPaddingAndKeepsBlackWindowContent() throws {
        let width = 20, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // An opaque all-black window near the bottom, not a black-color key.
        for y in 10..<20 {
            for x in 3..<17 { pixels[(y * width + x) * 4 + 3] = 255 }
        }
        let source = try image(width: width, height: height, pixels: pixels)
        #expect(NativeDockThumbnail.visibleBounds(in: source) == CGRect(x: 2, y: 9, width: 16, height: 12))
        let trimmed = try #require(NativeDockThumbnail.trimmed(source))
        #expect(trimmed.width == 16)
        #expect(trimmed.height == 12)
    }

    @Test func preservesApplicationBadgeOutsideWindowRectangle() throws {
        let width = 20, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 10..<18 {
            for x in 2..<18 { pixels[(y * width + x) * 4 + 3] = 255 }
        }
        for y in 17..<23 {
            for x in 15..<20 {
                let offset = (y * width + x) * 4
                pixels[offset] = 255; pixels[offset + 3] = 255
            }
        }
        let source = try image(width: width, height: height, pixels: pixels)
        #expect(NativeDockThumbnail.visibleBounds(in: source) == CGRect(x: 1, y: 9, width: 19, height: 15))
    }

    @Test func transparentFramesAreNotShownAsBlackTiles() throws {
        let source = try image(width: 4, height: 4, pixels: Array(repeating: 0, count: 64))
        #expect(NativeDockThumbnail.trimmed(source) == nil)
    }

    @Test func bgraConversionRetainsSurfaceAlpha() throws {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let source = try #require(buffer)
        CVPixelBufferLockBaseAddress(source, [])
        let address = try #require(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(source)
        memset(address, 0, stride * 2)
        address[3] = 0
        address[4 + 3] = 127
        address[stride + 3] = 255
        CVPixelBufferUnlockBaseAddress(source, [])
        let result = try #require(NativeDockThumbnail.image(from: source))
        #expect(result.alphaInfo == .premultipliedFirst)
        let data = try #require(result.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[3] == 0)
        #expect(bytes[7] == 127)
        #expect(bytes[stride + 3] == 255)
    }

    @Test func nativeThumbnailKeepsItsAspectRatio() {
        let landscape = NativeDockThumbnail.fittedSize(imageSize: CGSize(width: 100, height: 60), iconSize: 55)
        #expect(abs(landscape.width - 55) < 0.000001)
        #expect(abs(landscape.height - 33) < 0.000001)
        #expect(NativeDockThumbnail.fittedSize(imageSize: CGSize(width: 40, height: 80), iconSize: 55)
            == CGSize(width: 27.5, height: 55))
    }

    @Test func removesCapturedDockPlateButPreservesDarkWindowAndBadge() throws {
        let w = 80, h = 100
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        func fill(_ rect: CGRect, _ rgb: UInt8) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let i = (y * w + x) * 4
                    pixels[i] = rgb; pixels[i + 1] = rgb; pixels[i + 2] = rgb; pixels[i + 3] = 255
                }
            }
        }
        fill(CGRect(x: 0, y: 1, width: 80, height: 98), 16)
        fill(CGRect(x: 4, y: 35, width: 72, height: 44), 64)
        // The interior deliberately matches the backdrop. It must stay opaque.
        fill(CGRect(x: 5, y: 36, width: 70, height: 42), 16)
        fill(CGRect(x: 59, y: 73, width: 19, height: 20), 200)
        let source = try image(width: w, height: h, pixels: pixels)
        let result = NativeDockThumbnail.removingDockBackdrop(source)
        let data = try #require(result.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[(10 * w + 20) * 4 + 3] == 0)
        #expect(bytes[(50 * w + 20) * 4 + 3] == 255)
        #expect(bytes[(50 * w + 20) * 4] == 16)
        #expect(bytes[(85 * w + 68) * 4 + 3] == 255)
        #expect(bytes[(90 * w + 5) * 4 + 3] == 0)
        #expect(bytes[(85 * w + 40) * 4 + 3] == 0)
        let trimmed = try #require(NativeDockThumbnail.trimmed(result))
        #expect(trimmed.height < 65)
    }

    @Test func topEdgeShadowIsNotMistakenForTheMatte() throws {
        let w = 80, h = 100
        var pixels = [UInt8](repeating: 17, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let shade: UInt8 = y < 3 ? 41 : (y < 5 ? 29 : 17)
            for c in 0..<3 { pixels[i + c] = shade }
            pixels[i + 3] = 255
        } }
        for y in 18..<83 { for x in 6..<74 {
            let i = (y * w + x) * 4
            let border = y == 18 || y == 82 || x == 6 || x == 73
            for c in 0..<3 { pixels[i + c] = border ? 75 : 17 }
        } }
        let result = NativeDockThumbnail.removingDockBackdrop(try image(width: w, height: h, pixels: pixels))
        let data = try #require(result.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[(2 * w + 20) * 4 + 3] == 0)
        #expect(bytes[(10 * w + 20) * 4 + 3] == 0)
        #expect(bytes[(40 * w + 20) * 4 + 3] == 255)
        #expect(bytes[(40 * w + 20) * 4] == 17)
    }

    @Test func ambiguousSolidBlackImageRemainsIntact() throws {
        var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let source = try image(width: 40, height: 40, pixels: pixels)
        #expect(NativeDockThumbnail.removingDockBackdrop(source) === source)
    }

    @Test func shortMatteHeadroomKeepsDarkWordWindowInterior() throws {
        let w = 80, h = 100
        var pixels = [UInt8](repeating: 15, count: w * h * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        for y in 13..<80 {
            for x in 6..<74 {
                let i = (y * w + x) * 4
                let border = y == 13 || y == 79 || x == 6 || x == 73
                for c in 0..<3 { pixels[i + c] = border ? 70 : 15 }
            }
        }
        for y in 73..<94 { for x in 55..<75 {
            let i = (y * w + x) * 4
            pixels[i] = 40; pixels[i + 1] = 90; pixels[i + 2] = 220
        } }
        let source = try image(width: w, height: h, pixels: pixels)
        let result = NativeDockThumbnail.removingDockBackdrop(source)
        let data = try #require(result.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[(5 * w + 20) * 4 + 3] == 0)
        #expect(bytes[(40 * w + 20) * 4 + 3] == 255)
        #expect(bytes[(40 * w + 20) * 4] == 15)
        #expect(bytes[(85 * w + 65) * 4 + 3] == 255)
        #expect(bytes[(40 * w + 1) * 4 + 3] == 0)
    }

    @Test func translucentBlackPlateIsDistinctFromOpaqueBlackWindow() throws {
        let w = 80, h = 100
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 220 }
        for y in 35..<85 {
            for x in 4..<76 { pixels[(y * w + x) * 4 + 3] = 255 }
        }
        let source = try image(width: w, height: h, pixels: pixels)
        let result = NativeDockThumbnail.removingDockBackdrop(source)
        let data = try #require(result.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[(10 * w + 20) * 4 + 3] == 0)
        #expect(bytes[(50 * w + 20) * 4 + 3] == 255)
        #expect(bytes[(50 * w + 20) * 4] == 0)
    }

    @Test func fingerprintDetectsSettledArtworkButNotAnimationFrames() throws {
        let w = 60, h = 40
        var settled = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            settled[i] = x < 30 ? 20 : 230; settled[i + 1] = 30; settled[i + 2] = 200; settled[i + 3] = 255
        } }
        let first = try #require(NativeDockThumbnail.Fingerprint(image(width: w, height: h, pixels: settled)))
        let same = try #require(NativeDockThumbnail.Fingerprint(image(width: w, height: h, pixels: settled)))
        #expect(first.matches(same))
        // A dark matte still covering part of the tile is a different frame.
        var inFlight = settled
        for y in 0..<h { for x in 0..<w where y < 20 {
            let i = (y * w + x) * 4
            inFlight[i] = 8; inFlight[i + 1] = 8; inFlight[i + 2] = 8
        } }
        let animated = try #require(NativeDockThumbnail.Fingerprint(image(width: w, height: h, pixels: inFlight)))
        #expect(!first.matches(animated))
        // Geometry changes during minimize are never treated as settled.
        let taller = try #require(NativeDockThumbnail.Fingerprint(image(width: w, height: h + 6,
            pixels: settled + [UInt8](repeating: 255, count: w * 6 * 4))))
        #expect(!first.matches(taller))
    }

    // MARK: Dock tile geometry measured on this Mac (94 x 107 after alpha trim):
    // uniform plate 16, two highlight rows, a square artwork box x 5...88 whose
    // bottom-right corner holds the badge, and the window centred in that box.

    private struct DockTile {
        static let width = 94, height = 107
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        init() {
            fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height), 16)
            fill(CGRect(x: 0, y: 0, width: Self.width, height: 2), 41)
        }
        mutating func fill(_ rect: CGRect, _ rgb: UInt8) {
            for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * Self.width + x) * 4
                pixels[i] = rgb; pixels[i + 1] = rgb; pixels[i + 2] = rgb; pixels[i + 3] = 255
            } }
        }
        /// Window rectangle with a title bar, then the app badge with its own outline.
        mutating func window(_ rect: CGRect, title: UInt8 = 45, body: UInt8) {
            fill(rect, body)
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 5), title)
        }
        mutating func badge() {
            fill(CGRect(x: 64, y: 74, width: 25, height: 25), 70)
            fill(CGRect(x: 66, y: 76, width: 21, height: 21), 200)
        }
    }

    private func processed(_ tile: DockTile) throws -> (alpha: (Int, Int) -> UInt8, red: (Int, Int) -> UInt8) {
        let result = NativeDockThumbnail.removingDockBackdrop(
            try image(width: DockTile.width, height: DockTile.height, pixels: tile.pixels))
        let data = try #require(result.dataProvider?.data)
        let bytes = Array(UnsafeBufferPointer(start: try #require(CFDataGetBytePtr(data)), count: CFDataGetLength(data)))
        let w = result.width
        return ({ x, y in bytes[(y * w + x) * 4 + 3] }, { x, y in bytes[(y * w + x) * 4] })
    }

    @Test func darkWindowBodyMatchingThePlateKeepsItsWholeRectangle() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 5, y: 29, width: 84, height: 60), body: 17)
        tile.badge()
        let p = try processed(tile)
        #expect(p.alpha(20, 60) == 255)
        #expect(p.alpha(20, 86) == 255)
        #expect(p.red(20, 86) == 17)
        #expect(p.alpha(20, 93) == 0)
        #expect(p.alpha(20, 15) == 0)
        #expect(p.alpha(1, 60) == 0)
        #expect(p.alpha(92, 60) == 0)
        #expect(p.alpha(75, 95) == 255)
    }

    @Test func blackBordersOnAllSidesOfALightWindowAreRemovedCompletely() throws {
        var tile = DockTile()
        let window = CGRect(x: 5, y: 29, width: 84, height: 60)
        let badge = CGRect(x: 64, y: 74, width: 25, height: 25)
        tile.window(window, title: 200, body: 235)
        tile.badge()
        let p = try processed(tile)
        for y in 0..<DockTile.height { for x in 0..<DockTile.width {
            let keep = window.contains(CGPoint(x: x, y: y))
                || badge.contains(CGPoint(x: x, y: y))
            if !keep { #expect(p.alpha(x, y) == 0, "matte left at \(x),\(y)") }
        } }
        #expect(p.alpha(5, 29) == 255)
        #expect(p.alpha(20, 88) == 255)
        // No dark row is added under a visible light window bottom.
        #expect(p.alpha(20, 90) == 0)
        let trimmed = try #require(NativeDockThumbnail.trimmed(
            NativeDockThumbnail.removingDockBackdrop(try image(width: DockTile.width, height: DockTile.height, pixels: tile.pixels))))
        #expect(trimmed.width <= 86 && trimmed.height <= 72)
    }

    @Test func pureBlackWindowIsKeptAndItsBordersRemoved() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 5, y: 29, width: 84, height: 60), title: 30, body: 0)
        tile.badge()
        let p = try processed(tile)
        #expect(p.alpha(20, 86) == 255)
        #expect(p.red(20, 86) == 0)
        #expect(p.alpha(20, 93) == 0)
        #expect(p.alpha(20, 20) == 0)
        #expect(p.alpha(2, 60) == 0)
    }

    @Test func portraitDarkWindowKeepsBodyWithMatteOnlyAtTheSides() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 30, y: 17, width: 33, height: 84), body: 17)
        tile.badge()
        let p = try processed(tile)
        #expect(p.alpha(40, 99) == 255)
        #expect(p.alpha(40, 60) == 255)
        #expect(p.alpha(15, 60) == 0)
        #expect(p.alpha(75, 50) == 0)
        #expect(p.alpha(40, 10) == 0)
    }

    @Test func wideDarkWindowKeepsBodyWithMatteAboveAndBelow() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 5, y: 49, width: 84, height: 20), body: 17)
        tile.badge()
        let p = try processed(tile)
        #expect(p.alpha(20, 67) == 255)
        #expect(p.alpha(20, 73) == 0)
        #expect(p.alpha(20, 40) == 0)
        #expect(p.alpha(75, 95) == 255)
    }

    @Test func darkWindowWithContentAboveAnEmptyBottomKeepsTheEmptyArea() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 5, y: 29, width: 84, height: 60), body: 17)
        tile.fill(CGRect(x: 10, y: 40, width: 70, height: 2), 120)
        tile.fill(CGRect(x: 10, y: 46, width: 50, height: 2), 120)
        tile.badge()
        let p = try processed(tile)
        #expect(p.alpha(20, 80) == 255)
        #expect(p.alpha(85, 87) == 255)
        #expect(p.alpha(20, 94) == 0)
    }

    @Test func openingDockSlotIsNotPublishedButTheSettledTileIs() throws {
        var tile = DockTile()
        tile.window(CGRect(x: 5, y: 29, width: 84, height: 60), title: 200, body: 235)
        tile.badge()
        let full = try image(width: DockTile.width, height: DockTile.height, pixels: tile.pixels)
        let settled = try #require(NativeDockThumbnail.dockArtwork(fromTile: full))
        #expect(settled.width <= 86)
        // While Dock opens the slot, its AX frame (and so the tile) is a narrow
        // slice of plate and partial window. It must not become a dark block.
        for width in [2, 20, 40, 60] {
            let slice = try #require(full.cropping(to: CGRect(x: 0, y: 0, width: width, height: DockTile.height)))
            #expect(NativeDockThumbnail.dockArtwork(fromTile: slice) == nil, "slice \(width)")
        }
    }
}
