import AppKit
import CoreVideo

enum NativeDockThumbnail {
    /// Read the BGRA surface directly, retaining its alpha bytes through cropping
    /// and explicitly marking the resulting image as premultiplied.
    static func image(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: address, count: stride * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Trim alpha padding only. RGB values never decide which pixels survive:
    /// black windows, dark title bars and the application badge remain intact.
    static func visibleBounds(in image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = storage.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 3 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            // Preserve a small antialiasing fringe around the actual artwork.
            return CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                width: min(width, maxX + 2) - max(0, minX - 1),
                height: min(height, maxY + 2) - max(0, minY - 1))
        }
    }

    static func trimmed(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(in: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// Dock's backdrop material can arrive as an opaque dark plate even in a
    /// transparent window capture. Remove only the plate outside the artwork's
    /// window rectangle and badge outline; never color-key pixels inside them.
    static func removingDockBackdrop(_ image: CGImage) -> CGImage {
        separatingDockBackdrop(image).image
    }

    /// The published artwork for one Dock tile, or nil while the tile shows the
    /// Dock plate without a separable window, e.g. a slot that is still opening
    /// after a minimize. Showing such a frame produced a brief dark block.
    static func dockArtwork(fromTile tile: CGImage) -> CGImage? {
        guard tile.width >= 12, tile.height >= 12, let alphaTrimmed = trimmed(tile) else { return nil }
        let separated = separatingDockBackdrop(alphaTrimmed)
        guard !separated.unresolved else { return nil }
        return trimmed(separated.image)
    }

    /// `unresolved` means a Dock plate was found but no window could be
    /// separated from it; the image is then returned unchanged.
    private static func separatingDockBackdrop(_ image: CGImage) -> (image: CGImage, unresolved: Bool) {
        let w = image.width, h = image.height
        guard w >= 12, h >= 12 else { return (image, false) }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return (image, false) }
        // Headroom varies by app. Sampling at a fixed 20% can land inside a
        // short Word title bar and mistake the matte for window content.
        // Find a uniform dark row near the top, then require separate side
        // gutters around the artwork before removing anything.
        let uniformRows = (1..<max(2, h / 4)).filter { y in
            let middle = (y * w + w / 2) * 4
            let sample = (0..<4).map { Int(pixels[middle + $0]) }
            guard sample[3] > 32, sample.prefix(3).max()! <= 48,
                  sample.prefix(3).max()! - sample.prefix(3).min()! <= 8 else { return false }
            return (3..<w - 3).allSatisfy { x in
                let i = (y * w + x) * 4
                return (0..<4).allSatisfy { abs(Int(pixels[i + $0]) - sample[$0]) <= 8 }
            }
        }
        // The top-edge shadow can be uniform too. Use the recurring matte
        // signature, then its earliest row, instead of the first dark fringe.
        var plateRow: Int?
        var strongestMatch = 0
        for candidate in uniformRows {
            let i = (candidate * w + w / 2) * 4
            let matches = uniformRows.filter { y in
                let j = (y * w + w / 2) * 4
                return (0..<4).allSatisfy { abs(Int(pixels[i + $0]) - Int(pixels[j + $0])) <= 4 }
            }.count
            if matches > strongestMatch {
                strongestMatch = matches
                plateRow = candidate
            }
        }
        guard let plateRow else { return (image, false) }
        let sampleIndex = (plateRow * w + w / 2) * 4
        let background = Array(pixels[sampleIndex..<sampleIndex + 4]).map(Int.init)
        if UserDefaults.standard.bool(forKey: "thumbnailDiagnosticsEnabled") {
            UserDefaults.standard.set(background, forKey: "thumbnailMatteSample")
        }
        // The Dock material may itself be translucent. Its alpha is part of
        // the matte signature, distinct from an opaque black window.
        guard background[3] > 32, background.prefix(3).max()! <= 48,
              background.prefix(3).max()! - background.prefix(3).min()! <= 8 else { return (image, false) }
        func isPlate(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            if Int(pixels[i + 3]) < background[3] - 10 { return true }
            return (0..<4).allSatisfy { abs(Int(pixels[i + $0]) - background[$0]) <= 8 }
        }
        guard (3..<w - 3).allSatisfy({ isPlate($0, plateRow) }) else { return (image, false) }
        var spans = Array(repeating: (left: w, right: -1), count: h)
        var firstArtworkRow = h
        for y in plateRow..<h {
            var left = w, right = -1
            for x in 1..<w - 1 where pixels[(y * w + x) * 4 + 3] > 3 && !isPlate(x, y) {
                left = min(left, x); right = max(right, x)
            }
            if right >= left {
                firstArtworkRow = min(firstArtworkRow, y)
                spans[y] = (left, right)
            }
        }
        // Require substantial blank headroom; ambiguous images remain intact.
        guard firstArtworkRow - plateRow >= 2, firstArtworkRow < h else { return (image, true) }
        let widest = spans.map { $0.right - $0.left + 1 }.max() ?? 0
        let windowRows = (firstArtworkRow..<h).filter {
            CGFloat(spans[$0].right - spans[$0].left + 1) >= CGFloat(widest) * 0.65
        }
        guard let windowTop = windowRows.first else { return (image, true) }
        // The window's width comes from its own top edge (title bar). Later wide
        // rows can be the badge beside a dark, plate-coloured body; letting them
        // widen the rectangle left a dark block above the badge.
        let topBand = windowRows.filter { $0 <= windowTop + 3 }
        let windowLeft = topBand.map { spans[$0].left }.min()!
        let windowRight = topBand.map { spans[$0].right }.max()!
        // Rows that still show the window's own left edge. Badge-only rows start
        // further right, so they never extend the window downward.
        guard var windowBottom = (windowTop..<h).last(where: {
            spans[$0].right >= spans[$0].left && spans[$0].left <= windowLeft + 2
        }), windowBottom > windowTop else { return (image, true) }
        // A full-width dark title bar is legitimate window content. A Dock
        // matte needs visible gutters on both sides of the inset window.
        guard windowLeft >= 2, windowRight <= w - 3 else { return (image, true) }
        // Ignore rounding-level disagreement; only recover a clearly hidden edge
        // so a visible light-window bottom never gains a row of matte.
        let mirroredBottom = Self.centredWindowBottom(spans: spans, firstArtworkRow: firstArtworkRow,
            windowTop: windowTop, width: w, height: h)
        if mirroredBottom - windowBottom >= 2 { windowBottom = mirroredBottom }
        // Preserve the complete rectangular window, including areas matching
        // the matte color. Below it, follow the badge's own scanline silhouette
        // so a diagonal bridge of background cannot remain beside the badge.
        for y in 0..<h {
            // No dilation into neighbouring rows or columns: those extra pixels
            // were plate, i.e. a thin dark outline around every thumbnail.
            // Antialiased edge pixels differ from the plate and are in the spans.
            var left = spans[y].left
            var right = spans[y].right
            if y >= windowTop && y <= windowBottom {
                left = min(left, windowLeft)
                right = max(right, windowRight)
            }
            for x in 0..<w where x < left || x > right {
                let i = (y * w + x) * 4
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return (image, false) }
        return (result, false)
    }

    /// Dark window bodies (dark mode, terminals, dark web pages) can be within
    /// a few levels of the Dock plate, so rows near the window's bottom carry
    /// no visible edge and would be erased as matte. Dock centres the window
    /// in a square artwork box whose bottom-right corner holds the application
    /// badge, and the tile is horizontally centred on that box. Mirror the
    /// detected top edge across the box centre to recover the hidden bottom.
    /// Visible bottoms (light windows) already agree to within a pixel and are
    /// left unchanged, so this can only keep window pixels, never add matte
    /// outside the window's own rectangle.
    static func centredWindowBottom(spans: [(left: Int, right: Int)], firstArtworkRow: Int,
                                    windowTop: Int, width: Int, height: Int) -> Int {
        let artworkRows = (firstArtworkRow..<height).filter { spans[$0].right >= spans[$0].left }
        guard let lastArtworkRow = artworkRows.last,
              let boxRight = artworkRows.map({ spans[$0].right }).max() else { return windowTop }
        let boxLeft = (width - 1) - boxRight
        let side = boxRight - boxLeft + 1
        guard side >= 8, boxLeft >= 0 else { return windowTop }
        // The badge sits a hair above the box bottom (about 2% of its side).
        let inset = max(1, Int((Double(side) * 0.02).rounded()))
        let boxBottom = min(height - 1, lastArtworkRow + inset)
        return min(boxBottom, 2 * boxBottom - (side - 1) - windowTop)
    }

    /// A coarse, content-only signature used to tell whether Dock's artwork
    /// has stopped changing. It is kept in memory and never logged.
    struct Fingerprint: Equatable {
        let width: Int
        let height: Int
        let samples: [UInt8]

        init?(_ image: CGImage) {
            let side = 16
            var buffer = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = buffer.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return nil }
            width = image.width
            height = image.height
            samples = buffer
        }

        /// Same visible geometry and nearly identical pixels. Animation frames
        /// differ in size or by large amounts; encoder noise does not.
        func matches(_ other: Fingerprint) -> Bool {
            guard abs(width - other.width) <= 1, abs(height - other.height) <= 1,
                  samples.count == other.samples.count else { return false }
            var total = 0
            for index in samples.indices { total += abs(Int(samples[index]) - Int(other.samples[index])) }
            return Double(total) / Double(samples.count) <= 3
        }
    }

    static func fittedSize(imageSize: CGSize, iconSize: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: iconSize, height: iconSize)
        }
        let scale = iconSize / max(imageSize.width, imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
