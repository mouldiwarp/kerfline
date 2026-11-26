// FSEvents on the library folder: each batch of changes is a nudge to rescan. The scan itself
// works out what changed (and ignores the library's own writes), so events carry no detail.

import CoreServices
import Foundation

final class FolderWatcher: @unchecked Sendable {
    let nudges: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "swarfgrbl.library.fsevents")
    private var ref: FSEventStreamRef?

    init(path: String) {
        (nudges, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // The stream owns its own reference to a box holding the continuation (FSEvents retains it
        // and releases it with the stream), not an unretained pointer to the watcher: a callback
        // already running on the queue when stop() is called must not touch a freed watcher.
        let box = Box(continuation)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // Hidden paths are the library's temporary files and Finder's .DS_Store: not changes.
            let real = list.prefix(count).contains { p in !p.split(separator: "/").contains { $0.hasPrefix(".") } }
            if real || list.isEmpty { me.continuation.yield() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ref = withExtendedLifetime(box) {
            FSEventStreamCreate(
                nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        }
    }

    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ c: AsyncStream<Void>.Continuation) { continuation = c }
    }

    func start() {
        guard let ref else { return }
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
    }

    func stop() {
        if let ref {
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
        ref = nil
        continuation.finish()
    }

    deinit { if ref != nil { stop() } }
}
