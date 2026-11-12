import Foundation

enum NativeDockPlacementPolicy {
    // Wait for a real observation (or reserved Dock edge) on first launch.
    // A primary-screen guess can put a duplicate over the MacBook's Dock.
    static func mayShowCompanion(on display: UInt32, nativeDisplay: UInt32?) -> Bool {
        guard let nativeDisplay else { return false }
        return display != nativeDisplay
    }

    static func excludedDisplay(observed: UInt32?, previous: UInt32?, inferred: UInt32?, available: Set<UInt32>) -> UInt32? {
        [observed, previous, inferred].compactMap { $0 }.first { available.contains($0) }
    }
}
