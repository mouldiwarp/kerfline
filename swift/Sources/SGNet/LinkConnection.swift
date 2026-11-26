// One instance link: LinkMessages as JSON text over a WebSocket. The same on both ends (the hub
// accepting on /link, the agent dialling it). Messages are handled one at a time, in order.

import Foundation
import HummingbirdWebSocket
import NIOCore

/// Big enough for a library blob (base64 in JSON) in one message.
let linkMaxMessage = 256 << 20
/// Frames are split at this size; messages are reassembled up to linkMaxMessage.
let linkMaxFrame = 1 << 20

public final class LinkConnection: Sendable {
    public let id = UUID()
    private let out: AsyncStream<LinkMessage>.Continuation
    private let outgoing: AsyncStream<LinkMessage>

    init() {
        (outgoing, out) = AsyncStream.makeStream(of: LinkMessage.self)
    }

    /// Queue a message (sent in order; dropped once the link has closed).
    public func send(_ m: LinkMessage) { out.yield(m) }

    /// Close the link.
    public func close() { out.finish() }

    /// Run the link until either side closes it.
    func run(
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, onMessage: @escaping @Sendable (LinkMessage) async -> Void
    ) async {
        let outgoing = self.outgoing
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let encoder = JSONEncoder()
                for await m in outgoing {
                    guard let data = try? encoder.encode(m) else { continue }
                    do {
                        try await outbound.writeTextMessage(String(decoding: data, as: UTF8.self))
                    } catch {
                        return
                    }
                }
                try? await outbound.close(.normalClosure, reason: nil)
            }
            group.addTask {
                let decoder = JSONDecoder()
                do {
                    for try await message in inbound.messages(maxSize: linkMaxMessage) {
                        guard case .text(let text) = message, let m = try? decoder.decode(LinkMessage.self, from: Data(text.utf8)) else {
                            continue
                        }
                        await onMessage(m)
                    }
                } catch {}
            }
            await group.next()
            group.cancelAll()
        }
        out.finish()
    }
}
