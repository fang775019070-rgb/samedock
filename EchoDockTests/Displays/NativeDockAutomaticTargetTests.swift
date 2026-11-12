import AppKit
import Testing
@testable import EchoDock
@Suite struct NativeDockAutomaticTargetTests {
    func screen(_ id: UInt32, builtIn: Bool = false, main: Bool = false, mirror: Bool = false) -> DisplayDescriptor {
        DisplayDescriptor(identity: DisplayIdentity(rawValue: "s\(id)"), displayID: id, localizedName: "Fixture", frame: .zero, isMain: main, isBuiltIn: builtIn, mirroredDisplayID: mirror ? 1 : nil)
    }
    @Test func laptopWinsOverProjectorAndReturnsAfterClamshell() {
        let internalScreen = screen(1, builtIn: true), external = screen(2, main: true), projector = screen(3)
        #expect(NativeDockTargetPolicy.target(strategy: .automatic, selected: nil, displays: [external, projector, internalScreen], current: 3, previous: nil)?.displayID == 1)
        #expect(NativeDockTargetPolicy.target(strategy: .automatic, selected: nil, displays: [external], current: 1, previous: internalScreen.identity)?.displayID == 2)
        #expect(NativeDockTargetPolicy.target(strategy: .automatic, selected: nil, displays: [external, internalScreen], current: 2, previous: external.identity)?.displayID == 1)
    }
    @Test func explicitChoiceAndSystemManagedModeAreRespected() {
        let a = screen(1, builtIn: true), b = screen(2, main: true)
        #expect(NativeDockTargetPolicy.target(strategy: .fixedToSelectedDisplay, selected: b.identity, displays: [a,b], current: 1, previous: nil) == b)
        #expect(NativeDockTargetPolicy.target(strategy: .fixedToSelectedDisplay, selected: b.identity, displays: [a], current: 1, previous: nil) == nil)
        #expect(NativeDockTargetPolicy.target(strategy: .systemManaged, selected: nil, displays: [a,b], current: 1, previous: nil) == nil)
        #expect(NativeDockTargetPolicy.target(strategy: .automatic, selected: nil, displays: [screen(1, builtIn:true, mirror:true),b], current: 1, previous: nil) == b)
    }
    @Test @MainActor func newDefaultsAreAutomaticButSavedChoiceSurvives() {
        let name = "DockluneAutomaticTests.\(UUID())"
        // Use a separate, disposable preferences domain.
        let isolated = UserDefaults(suiteName:name)!
        defer { isolated.removePersistentDomain(forName:name) }
        let p = PreferencesStore(defaults:isolated)
        #expect(p.nativeDockStrategy == .automatic)
        p.nativeDockStrategy = .systemManaged
        #expect(PreferencesStore(defaults:isolated).nativeDockStrategy == .systemManaged)
    }
}
