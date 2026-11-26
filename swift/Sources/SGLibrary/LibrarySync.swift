// Library sync, the conversation: one LibrarySync per connection to the other Mac. It doesn't
// know about sockets; it's given a way to send and is handed what arrives, so tests can wire two
// libraries together directly.
//
//   connect      both sides send `have` (their version vector)
//   on `have`    send every change the other side hasn't seen, oldest first, in batches
//   on changes   apply them, `ack` with the new vector, and ask for content not here yet
//   later        each local change is pushed as it happens
//
// Everything is handled one message at a time, in order.

import Foundation

public enum SyncMessage: Codable, Sendable {
    /// Everything I've seen (sent on connect).
    case have(VersionVector)
    case changes([SyncChange])
    /// Applied: what I've seen now.
    case ack(VersionVector)
    /// Content I need, by hash.
    case want([String])
    case blob(sha: String, data: Data)
}

public actor LibrarySync {
    public typealias Send = @Sendable (SyncMessage) async -> Void

    private enum Work: Sendable {
        case received(SyncMessage)
        case localChange
    }

    public let library: Library
    public let peerName: String
    private let send: Send
    private let work: AsyncStream<Work>.Continuation
    private let workStream: AsyncStream<Work>
    private var tasks: [Task<Void, Never>] = []
    /// What the other side has: its `have`, its acks, and what's been sent to it.
    private var peerHas: VersionVector = [:]
    /// What the other side has actually applied (its `have` and acks only): a change of mine it
    /// hadn't seen when it sent its own is concurrent with them.
    private var peerSeen: VersionVector = [:]
    private var ready = false
    private var requested: Set<String> = []
    private var batchSize: Int

    public init(library: Library, peerName: String, batchSize: Int = 500, send: @escaping Send) {
        self.library = library
        self.peerName = peerName
        self.send = send
        self.batchSize = batchSize
        (workStream, work) = AsyncStream.makeStream(of: Work.self)
    }

    public func start() async {
        let stream = workStream
        tasks.append(Task { [weak self] in
            for await w in stream { await self?.handle(w) }
        })
        let events = await library.events()
        let work = self.work
        tasks.append(Task {
            for await _ in events { work.yield(.localChange) }
        })
        await send(.have(await library.versionVector()))
    }

    /// Hand over a message from the other side.
    public nonisolated func receive(_ message: SyncMessage) {
        work.yield(.received(message))
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        work.finish()
    }

    /// True once the other side has said what it has.
    public var isReady: Bool { ready }

    private func handle(_ w: Work) async {
        switch w {
        case .localChange:
            await push()
        case .received(let m):
            switch m {
            case .have(let v):
                merge(v)
                merge(v, into: &peerSeen)
                ready = true
                await push()
                await requestMissing()
            case .changes(let batch):
                let seen = peerSeen[library.replica]
                do {
                    try await library.applySync(batch, peer: SyncPeer(name: peerName, seenMine: seen))
                } catch {
                    return // nothing is acked, so it all comes again on the next connect
                }
                for c in batch where peerHas[c.stamp.replica].map({ c.stamp > $0 }) ?? true { peerHas[c.stamp.replica] = c.stamp }
                await send(.ack(await library.versionVector()))
                await push()
                await requestMissing()
            case .ack(let v):
                merge(v)
                merge(v, into: &peerSeen)
            case .want(let shas):
                for sha in shas {
                    if let data = await library.content(sha: sha) { await send(.blob(sha: sha, data: data)) }
                }
            case .blob(let sha, let data):
                requested.remove(sha)
                try? await library.receiveBlob(data, sha: sha)
            }
        }
    }

    private func merge(_ v: VersionVector) { merge(v, into: &peerHas) }

    private func merge(_ v: VersionVector, into vector: inout VersionVector) {
        for (k, s) in v where vector[k].map({ s > $0 }) ?? true { vector[k] = s }
    }

    private func push() async {
        guard ready else { return }
        while true {
            let batch = await library.syncChanges(after: peerHas, limit: batchSize)
            if batch.isEmpty { return }
            for c in batch where peerHas[c.stamp.replica].map({ c.stamp > $0 }) ?? true { peerHas[c.stamp.replica] = c.stamp }
            await send(.changes(batch))
        }
    }

    private func requestMissing() async {
        let missing = await library.missingBlobs().filter { !requested.contains($0) }
        guard !missing.isEmpty else { return }
        requested.formUnion(missing)
        for i in stride(from: 0, to: missing.count, by: 50) {
            await send(.want(Array(missing[i..<min(i + 50, missing.count)])))
        }
    }
}
