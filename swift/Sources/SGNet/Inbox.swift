// The inbox (default ~/GCode Inbox): any app that can save a file can send G-code by saving it
// there. Once a file has stopped growing it's imported and moved to Inbox/imported. Port of
// packages/hub/src/inbox.ts.

import Foundation
import SGLibrary

public actor Inbox {
    public let dir: URL
    private let onFile: @Sendable (String, Data) async throws -> Void
    private let onError: @Sendable (String, Error) async -> Void
    private var sizes: [String: Int] = [:]
    private var task: Task<Void, Never>?

    public init(
        _ dir: URL, onFile: @escaping @Sendable (String, Data) async throws -> Void,
        onError: @escaping @Sendable (String, Error) async -> Void = { _, _ in }
    ) {
        self.dir = dir
        self.onFile = onFile
        self.onError = onError
    }

    public func start(interval: Double = 1.5) {
        try? FileManager.default.createDirectory(at: dir.appending(path: "imported"), withIntermediateDirectories: true)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.scan()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func scan() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where !name.hasPrefix(".") && isGcodeName(name) {
            let url = dir.appending(path: name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                let size = (attrs[.size] as? NSNumber)?.intValue
            else { continue }
            // Import only once the size has held steady for one scan.
            if sizes[name] != size {
                sizes[name] = size
                continue
            }
            sizes[name] = nil
            do {
                try await onFile(name, try Data(contentsOf: url))
            } catch {
                await onError(name, error)
            }
            moveToImported(name)
        }
    }

    private func moveToImported(_ name: String) {
        let fm = FileManager.default
        let imported = dir.appending(path: "imported")
        let target = uniqueName(name) { fm.fileExists(atPath: imported.appending(path: $0).path) }
        // If it can't be moved it's imported again next scan, which the library ignores (same content).
        try? fm.moveItem(at: dir.appending(path: name), to: imported.appending(path: target))
    }
}
