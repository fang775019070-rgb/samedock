import AppKit
import Testing
@testable import EchoDock

@Suite @MainActor struct DockFileOperatorTests {
    let disk = URL(fileURLWithPath: "/Volumes/DockluneFixture")
    let file = URL(fileURLWithPath: "/tmp/fixture.dmg")
    @Test func installerVolumeIsEjectedAndNeverRecycled() async {
        var recycled: [URL] = [], ejected: [URL] = []
        let op = DockFileOperator(isVolume: { $0 == disk }, recycleFiles: { urls, done in
            recycled += urls; done([:], nil)
        }, ejectVolume: { url, done in ejected.append(url); done(nil) })
        let result = await withCheckedContinuation { c in op.recycle([disk, disk]) { c.resume(returning: $0) } }
        #expect(recycled.isEmpty)
        #expect(ejected == [disk])
        #expect(result.ejectedURLs == [disk])
        #expect(result.errorDescription == nil)
    }
    @Test func mixedDropRecyclesInstallerFileButNotMountedContents() async {
        var recycled: [URL] = []
        let op = DockFileOperator(isVolume: { $0 == disk }, recycleFiles: { urls, done in
            recycled = urls; done([file: URL(fileURLWithPath: "/tmp/trash/fixture.dmg")], nil)
        }, ejectVolume: { _, done in done(nil) })
        let result = await withCheckedContinuation { c in
            op.recycle([disk, disk.appendingPathComponent("App.app"), file, file]) { c.resume(returning: $0) }
        }
        #expect(recycled == [file])
        #expect(result.recycledURLs.count == 1)
        #expect(result.ejectedURLs == [disk])
    }
    @Test func busyVolumeReportsFailureWithoutTryingToDeleteIt() async {
        var recycled = false
        let op = DockFileOperator(isVolume: { _ in true }, recycleFiles: { _, done in
            recycled = true; done([:], nil)
        }, ejectVolume: { _, done in done(NSError(domain: NSPOSIXErrorDomain, code: 16)) })
        let result = await withCheckedContinuation { c in op.recycle([disk]) { c.resume(returning: $0) } }
        #expect(!recycled)
        #expect(result.ejectedURLs.isEmpty)
        #expect(result.errorDescription != nil)
    }
    @Test func unreadableItemNeverFallsThroughToDelete() async {
        var recycled = false
        let op = DockFileOperator(isVolume: { _ in throw CocoaError(.fileReadNoPermission) }, recycleFiles: { _, done in recycled = true; done([:], nil) })
        let result = await withCheckedContinuation { c in op.recycle([file]) { c.resume(returning: $0) } }
        #expect(!recycled)
        #expect(result.errorDescription != nil)
    }
}
