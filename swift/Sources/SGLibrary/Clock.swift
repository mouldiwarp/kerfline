// Version stamps for library changes: a hybrid logical clock (wall time in ms plus a counter, so
// stamps from one Mac always increase even if its clock steps back) and the replica that made the
// change. Stamps from two Macs order the same way on both, which is what sync needs to agree.

import Foundation

public struct Stamp: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var ms: Int64
    public var counter: Int
    public var replica: String

    public init(ms: Int64, counter: Int, replica: String) {
        self.ms = ms
        self.counter = counter
        self.replica = replica
    }

    /// "0001763471234567-0003-<replica>": sorts as text in the same order as the stamps.
    public var description: String {
        String(format: "%016lld-%04d-", ms, counter) + replica
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, let ms = Int64(parts[0]), let c = Int(parts[1]) else { return nil }
        self.init(ms: ms, counter: c, replica: String(parts[2]))
    }

    public static func < (a: Stamp, b: Stamp) -> Bool {
        (a.ms, a.counter, a.replica) < (b.ms, b.counter, b.replica)
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = Stamp(s) else { throw LibraryError("Bad version stamp \(s)") }
        self = v
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

struct HybridClock {
    let replica: String
    var last: Stamp

    init(replica: String, last: Stamp?) {
        self.replica = replica
        self.last = last ?? Stamp(ms: 0, counter: 0, replica: replica)
    }

    /// A stamp later than every stamp this clock has made or seen.
    mutating func tick(wall: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Stamp {
        last = wall > last.ms
            ? Stamp(ms: wall, counter: 0, replica: replica)
            : last.counter < 9999
                ? Stamp(ms: last.ms, counter: last.counter + 1, replica: replica)
                : Stamp(ms: last.ms + 1, counter: 0, replica: replica) // keeps the text form fixed-width
        return last
    }

    /// Move past a stamp from another replica (sync).
    mutating func observe(_ s: Stamp) {
        if s.ms > last.ms || (s.ms == last.ms && s.counter > last.counter) {
            last = Stamp(ms: s.ms, counter: s.counter, replica: replica)
        }
    }
}
