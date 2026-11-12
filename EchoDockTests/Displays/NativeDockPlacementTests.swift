import Testing
@testable import EchoDock

@Suite struct NativeDockPlacementTests {
    @Test func neverPlacesACompanionUntilTheNativeScreenIsKnown() {
        #expect(!NativeDockPlacementPolicy.mayShowCompanion(on: 1, nativeDisplay: nil))
        #expect(!NativeDockPlacementPolicy.mayShowCompanion(on: 2, nativeDisplay: 2))
        #expect(NativeDockPlacementPolicy.mayShowCompanion(on: 1, nativeDisplay: 2))
    }
    @Test func followsNativeDockInsteadOfMainScreenAndKeepsOtherScreens() {
        let screens: Set<UInt32> = [1, 2, 3]
        let first = NativeDockPlacementPolicy.excludedDisplay(observed: 2, previous: nil, inferred: 1, available: screens)
        #expect(first == 2)
        #expect(screens.filter { $0 != first } == Set([1, 3]))
        #expect(NativeDockPlacementPolicy.excludedDisplay(observed: 3, previous: first, inferred: 1, available: screens) == 3)
    }
    @Test func retainsObservationAcrossTransitionsButDropsDisconnectedScreen() {
        #expect(NativeDockPlacementPolicy.excludedDisplay(observed: nil, previous: 2, inferred: 1, available: [1, 2]) == 2)
        #expect(NativeDockPlacementPolicy.excludedDisplay(observed: nil, previous: 2, inferred: 1, available: [1]) == 1)
        #expect(NativeDockPlacementPolicy.excludedDisplay(observed: nil, previous: nil, inferred: nil, available: [1, 2]) == nil)
    }
}
