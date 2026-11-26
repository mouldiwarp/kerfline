// A byte pipe to a GRBL controller. SerialPort talks to real USB hardware; FakeGrbl implements
// the same protocol in-process. Port of packages/agent/src/transport.ts.
//
// Bytes, not strings: realtime bytes above 0x7F (overrides, jog cancel) go over the wire as single
// bytes. Incoming bytes arrive in order on `events`, which ends when the transport closes.

import Foundation

public enum TransportEvent: Sendable {
    case data([UInt8])
    /// The link closed: nil when closed on purpose, an error for an unplug or a fault.
    case closed((any Error)?)
}

public protocol Transport: AnyObject, Sendable {
    var name: String { get }
    var simulated: Bool { get }
    /// Everything the controller sends, in order. Ask for it once, before `open()`.
    var events: AsyncStream<TransportEvent> { get }
    func open() async throws
    func close() async
    func write(_ bytes: [UInt8])
}

extension Transport {
    public func write(_ text: String) { write(Array(text.utf8)) }
}

/// An error with a message for the user.
public struct MachineError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A pair of an AsyncStream and its continuation, for transports to publish their events.
struct EventPipe: Sendable {
    let stream: AsyncStream<TransportEvent>
    let continuation: AsyncStream<TransportEvent>.Continuation
    init() {
        (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }
}

/// Latin-1 text from bytes (every byte one character), as 1.0 read the serial port.
func latin1(_ bytes: some Sequence<UInt8>) -> String {
    var s = String()
    for b in bytes { s.unicodeScalars.append(Unicode.Scalar(b)) }
    return s
}
