import AppKit

struct DockRecycleResult: Equatable, Sendable {
    let recycledURLs: [URL: URL]
    let errorDescription: String?
    var ejectedURLs: [URL] = []
}

@MainActor
final class DockFileOperator {
    typealias Recycle = ([URL], @escaping ([URL: URL], Error?) -> Void) -> Void
    typealias Eject = (URL, @escaping (Error?) -> Void) -> Void
    private let isVolume: (URL) throws -> Bool
    private let recycleFiles: Recycle
    private let ejectVolume: Eject

    init(workspace: NSWorkspace = .shared,
         isVolume: @escaping (URL) throws -> Bool = {
             try $0.resourceValues(forKeys: [.isVolumeKey]).isVolume == true
         }, recycleFiles: Recycle? = nil, ejectVolume: Eject? = nil) {
        self.isVolume = isVolume
        self.recycleFiles = recycleFiles ?? { urls, done in workspace.recycle(urls, completionHandler: done) }
        self.ejectVolume = ejectVolume ?? { url, done in
            // Unmount can wait for the OS; never block the Dock's main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
                catch { failure = error }
                let result = failure
                DispatchQueue.main.async { done(result) }
            }
        }
    }

    func recycle(_ fileURLs: [URL], completion: @escaping (DockRecycleResult) -> Void) {
        var seen = Set<String>()
        let urls = fileURLs.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        var files: [URL] = [], volumes: [URL] = [], failures: [String] = []
        for url in urls {
            do {
                if try isVolume(url) { volumes.append(url) } else { files.append(url) }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        // A dropped volume must never be passed to the file recycling operation.
        // Files inside the same volume are left untouched if it is also being ejected.
        files.removeAll { file in volumes.contains { volume in file.path.hasPrefix(volume.path + "/") } }
        var ejected: [URL] = []
        func finish(_ mappings: [URL: URL], _ error: Error?) {
            if let error { failures.append(error.localizedDescription) }
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            completion(DockRecycleResult(recycledURLs: mappings,
                errorDescription: failures.isEmpty ? nil : failures.joined(separator: "\n"), ejectedURLs: ejected))
        }
        func ejectNext(_ index: Int) {
            guard index < volumes.count else {
                guard !files.isEmpty else { finish([:], nil); return }
                recycleFiles(files) { mappings, error in
                    DispatchQueue.main.async { finish(mappings, error) }
                }
                return
            }
            let url = volumes[index]
            ejectVolume(url) { error in
                if let error { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                else { ejected.append(url) }
                ejectNext(index + 1)
            }
        }
        ejectNext(0)
    }
}
