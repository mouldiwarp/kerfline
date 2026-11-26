// Job progress by estimated time rather than lines. GRBL's "ok" only means a line went into its
// planner queue (up to 35 moves ahead on the FoxAlien's board), and one surfacing pass can be a
// single line that takes a minute, so counting lines says little. This model gives each stream
// line its estimated start time and duration, so progress is the time the machine has actually
// reached: the line it's cutting, plus how far along that line the tool is.
// Port of packages/shared/src/progress.ts.

import Foundation
import simd

public struct ProgressModel: Sendable {
    /// Estimated seconds from the start of the program to the start of each stream line.
    public var start: [Double]
    /// Estimated seconds each stream line takes.
    public var dur: [Double]
    /// Where each stream line's motion starts and ends (work mm). Nil if it doesn't move.
    public var from: [Vec3?]
    public var to: [Vec3?]
    /// Estimated seconds for the whole program.
    public var total: Double

    public var count: Int { start.count }
}

/// `from`: where the tool is when the program starts (work mm), so its first moves can be timed.
public func progressModel(_ text: String, options: InterpreterOptions = .init(), from: Vec3? = nil) -> ProgressModel {
    let lines = streamableLines(text)
    let n = lines.count
    var m = ProgressModel(
        start: .init(repeating: 0, count: n), dur: .init(repeating: 0, count: n),
        from: .init(repeating: nil, count: n), to: .init(repeating: nil, count: n), total: 0)
    let interp = Interpreter(options)
    if let from { interp.setPosition(from) }
    var t = 0.0
    for (k, sl) in lines.enumerated() {
        m.start[k] = t
        let dwellBefore = interp.dwellSeconds
        let segs = interp.step(sl.text, line: sl.source)
        var d = interp.dwellSeconds - dwellBefore
        for s in segs {
            let rate = s.type == .rapid ? interp.rapidRate : s.feed
            if rate > 0 { d += s.length / rate * 60 }
        }
        if let first = segs.first, let last = segs.last {
            m.from[k] = first.from
            m.to[k] = last.to
        }
        m.dur[k] = d
        t += d
    }
    m.total = t
    return m
}

/// Fraction (0-1) of the way from `a` to `b` that `p`'s projection lies.
private func along(_ a: Vec3, _ b: Vec3, _ p: Vec3) -> Double? {
    let d = b - a
    let len2 = simd_length_squared(d)
    return len2 > 1e-9 ? min(1, max(0, simd_dot(p - a, d) / len2)) : nil
}

/// Estimated seconds of the program done when the machine is working on stream line `line` with
/// the tool at `wpos`. Within a line it goes by how far the tool is from the line's start towards
/// its end (exact for straight moves, close enough for arcs).
public func secondsDone(_ m: ProgressModel, _ line: Int, _ wpos: Vec3? = nil) -> Double {
    let n = m.count
    if n == 0 { return 0 }
    if line >= n { return m.total }
    let k = max(0, line)
    var frac = 0.0
    if let wpos, m.dur[k] > 0, let a = m.from[k], let b = m.to[k], let f = along(a, b, wpos) { frac = f }
    return m.start[k] + frac * m.dur[k]
}

/// How far the tool at `wpos` is from stream line `k`'s path (as a straight move), mm. Infinity if it doesn't move.
public func distanceToLine(_ m: ProgressModel, _ k: Int, _ wpos: Vec3) -> Double {
    guard k >= 0, k < m.count, let a = m.from[k], let b = m.to[k] else { return .infinity }
    let d = b - a
    let len2 = simd_length_squared(d)
    let t = len2 > 1e-12 ? min(1, max(0, simd_dot(wpos - a, d) / len2)) : 0
    return simd_length(wpos - (a + t * d))
}

/// The line the tool is on: the first line from `lowest` (a safe lower bound, from counting
/// GRBL's queue) up to `highest` (the last line GRBL has taken) whose path passes through the
/// tool's position. Falls back to `lowest`.
public func lineAtPosition(_ m: ProgressModel, _ lowest: Int, _ highest: Int, _ wpos: Vec3, tolerance: Double = 0.05) -> Int {
    let end = min(highest, m.count - 1)
    var k = max(0, lowest)
    while k <= end {
        if m.dur[k] > 0 && distanceToLine(m, k, wpos) <= tolerance { return k }
        k += 1
    }
    return lowest
}
