// G-code interpretation shared by the simulator, file analysis and the visualizer. It follows
// GRBL 1.1's modal rules closely enough to draw and time hobby CAM output: G0/G1/G2/G3,
// G17-G19, G20/G21, G90/G91, G4 dwell, and it steps over G10/G28/G30/G92 so their axis words
// are not mistaken for motion. Port of packages/shared/src/gcode.ts.

import Foundation
import simd

public typealias Vec3 = SIMD3<Double>

public enum SegmentType: String, Codable, Sendable {
    case rapid, feed
}

public struct Segment: Equatable, Sendable {
    /// 0-based index of the source line that produced this segment.
    public var line: Int
    public var type: SegmentType
    public var from: Vec3
    public var to: Vec3
    /// Feed rate in mm/min (rapids report the rapid rate used for timing).
    public var feed: Double
    /// True when the segment is part of a linearised arc.
    public var arc: Bool

    public init(line: Int, type: SegmentType, from: Vec3, to: Vec3, feed: Double, arc: Bool = false) {
        self.line = line
        self.type = type
        self.from = from
        self.to = to
        self.feed = feed
        self.arc = arc
    }

    public var length: Double { simd_length(to - from) }
}

public struct Bounds: Codable, Equatable, Sendable {
    public var min: Vec3
    public var max: Vec3
    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    mutating func grow(_ p: Vec3) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }
}

extension Optional where Wrapped == Bounds {
    mutating func grow(_ p: Vec3) {
        if self == nil { self = Bounds(min: p, max: p) } else { self!.grow(p) }
    }
}

/// Remove comments and whitespace and upper-case a line, the way it is sent to GRBL.
public func cleanLine(_ raw: some StringProtocol) -> String {
    var out = [UInt8]()
    out.reserveCapacity(raw.utf8.count)
    var inParen = false
    for c in raw.utf8 {
        if inParen {
            if c == UInt8(ascii: ")") { inParen = false }
            continue
        }
        switch c {
        case UInt8(ascii: "("): inParen = true
        case UInt8(ascii: ";"): return finish(out)
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"): continue
        case UInt8(ascii: "a")...UInt8(ascii: "z"): out.append(c - 32)
        default: out.append(c)
        }
    }
    return finish(out)

    func finish(_ b: [UInt8]) -> String {
        if b == [UInt8(ascii: "%")] { return "" }
        // Non-ASCII bytes are rare in G-code; upper-case them properly if present.
        let s = String(decoding: b, as: UTF8.self)
        return b.allSatisfy({ $0 < 0x80 }) ? s : s.uppercased()
    }
}

public struct Word: Equatable, Sendable {
    public var letter: Character
    public var value: Double
    public init(_ letter: Character, _ value: Double) {
        self.letter = letter
        self.value = value
    }
}

@inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

/// Scan `[-+]?(\d+\.?\d*|\.\d+)` at `start`. Returns the value and the index after it.
func scanNumber(_ b: [UInt8], _ start: Int) -> (Double, Int)? {
    let n = b.count
    var j = start
    if j < n && (b[j] == UInt8(ascii: "+") || b[j] == UInt8(ascii: "-")) { j += 1 }
    let digits = j
    while j < n && isDigit(b[j]) { j += 1 }
    if j > digits {
        if j < n && b[j] == UInt8(ascii: ".") {
            j += 1
            while j < n && isDigit(b[j]) { j += 1 }
        }
    } else {
        guard j + 1 < n, b[j] == UInt8(ascii: "."), isDigit(b[j + 1]) else { return nil }
        j += 1
        while j < n && isDigit(b[j]) { j += 1 }
    }
    var text = String(decoding: b[start..<j], as: UTF8.self)
    if text.hasSuffix(".") { text += "0" }
    guard let v = Double(text) else { return nil }
    return (v, j)
}

/// Every letter-and-number word in an upper-cased line (`G1X10.5` → G1, X10.5).
public func parseWords(_ clean: some StringProtocol) -> [Word] {
    let b = Array(clean.utf8)
    var words: [Word] = []
    var i = 0
    while i < b.count {
        let c = b[i]
        if c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z"), let (v, end) = scanNumber(b, i + 1) {
            words.append(Word(Character(Unicode.Scalar(c)), v))
            i = end
        } else {
            i += 1
        }
    }
    return words
}

public struct InterpreterOptions: Sendable {
    /// Rapid rate used for timing estimates, mm/min.
    public var rapidRate: Double
    /// Maximum chord error when linearising arcs, mm.
    public var arcTolerance: Double
    public init(rapidRate: Double = 5000, arcTolerance: Double = 0.02) {
        self.rapidRate = rapidRate
        self.arcTolerance = arcTolerance
    }
}

/// XY (G17), ZX (G18), YZ (G19): the two arc axes and the linear axis.
private let planeAxes: [(Int, Int, Int)] = [(0, 1, 2), (2, 0, 1), (1, 2, 0)]

/// Incremental modal interpreter: feed it lines, it returns the segments each one moves.
public final class Interpreter {
    public var pos = Vec3(0, 0, 0)
    /// Which axes have a known position. A program doesn't say where the machine starts, so moves
    /// are only drawn once every axis has been set; until then they just establish the position.
    public var known = [false, false, false]
    /// 0-3, or -1 after G80.
    public var motion = 0
    public var absolute = true
    public var inches = false
    /// 0 = G17, 1 = G18, 2 = G19.
    public var plane = 0
    public var feed = 0.0
    /// Seconds of dwell (G4) accumulated.
    public var dwellSeconds = 0.0
    public let rapidRate: Double
    public let arcTolerance: Double

    public init(_ opts: InterpreterOptions = .init()) {
        rapidRate = opts.rapidRate
        arcTolerance = opts.arcTolerance
    }

    /// Start from a known position (the simulator knows where the machine is).
    public func setPosition(_ p: Vec3) {
        pos = p
        known = [true, true, true]
    }

    public func reset() {
        pos = .zero
        known = [false, false, false]
        motion = 0
        absolute = true
        inches = false
        plane = 0
        feed = 0
        dwellSeconds = 0
    }

    /// Interpret one already-cleaned line. Returns the motion segments it produces.
    public func step(_ clean: String, line lineIndex: Int = 0) -> [Segment] {
        guard let first = clean.utf8.first, first != UInt8(ascii: "$"), first != UInt8(ascii: "[") else { return [] }
        let words = parseWords(clean)
        if words.isEmpty { return [] }

        var nonModal: Double?
        var motionWord: Int?
        var axis: [Character: Double] = [:]
        var dwell = false

        for w in words {
            switch w.letter {
            case "G":
                let g = w.value
                if g == 0 || g == 1 || g == 2 || g == 3 { motionWord = Int(g) }
                else if g == 38.2 || g == 38.3 || g == 38.4 || g == 38.5 { motionWord = 1 } // probe: draw as feed
                else if g == 80 { motionWord = -1 }
                else if g == 17 { plane = 0 }
                else if g == 18 { plane = 1 }
                else if g == 19 { plane = 2 }
                else if g == 20 { inches = true }
                else if g == 21 { inches = false }
                else if g == 90 { absolute = true }
                else if g == 91 { absolute = false }
                else if g == 4 { dwell = true }
                else if [10, 28, 30, 92, 53, 28.1, 30.1, 92.1].contains(g) { nonModal = g }
            case "F":
                feed = inches ? w.value * 25.4 : w.value
            case "X", "Y", "Z", "I", "J", "K", "R", "P":
                axis[w.letter] = w.value
            default:
                break
            }
        }

        if dwell {
            if let p = axis["P"] { dwellSeconds += p }
            return []
        }
        if let m = motionWord { motion = m }
        // Axis words belong to the non-modal command (G10/G28/G30/G92/G53): no drawn motion.
        if nonModal != nil { return [] }
        let vals = [axis["X"], axis["Y"], axis["Z"]]
        if vals.allSatisfy({ $0 == nil }) || motion < 0 { return [] }

        let scale = inches ? 25.4 : 1
        let from = pos
        var to = pos
        let startKnown = known[0] && known[1] && known[2]
        for i in 0..<3 {
            guard let v = vals[i] else { continue }
            to[i] = absolute ? v * scale : from[i] + v * scale
            if absolute { known[i] = true }
        }
        if !startKnown {
            pos = to
            return []
        }

        let segments: [Segment]
        switch motion {
        case 0: segments = [Segment(line: lineIndex, type: .rapid, from: from, to: to, feed: rapidRate)]
        case 1: segments = [Segment(line: lineIndex, type: .feed, from: from, to: to, feed: feed)]
        default: segments = arc(from: from, to: to, words: axis, scale: scale, line: lineIndex)
        }
        pos = to
        return segments
    }

    private func arc(from: Vec3, to: Vec3, words w: [Character: Double], scale: Double, line lineIndex: Int) -> [Segment] {
        let (a0, a1, lin) = planeAxes[plane]
        let cw = motion == 2
        let offsets = Vec3((w["I"] ?? 0) * scale, (w["J"] ?? 0) * scale, (w["K"] ?? 0) * scale)
        var c0: Double
        var c1: Double

        if let rWord = w["R"] {
            var r = rWord * scale
            let x = to[a0] - from[a0]
            let y = to[a1] - from[a1]
            let d2 = x * x + y * y
            if d2 < 1e-12 { return [Segment(line: lineIndex, type: .feed, from: from, to: to, feed: feed)] }
            let disc = Swift.max(0, 4 * r * r - d2)
            var h = -disc.squareRoot() / d2.squareRoot()
            if !cw { h = -h }
            if r < 0 {
                h = -h
                r = -r
            }
            c0 = from[a0] + 0.5 * (x - y * h)
            c1 = from[a1] + 0.5 * (y + x * h)
        } else {
            c0 = from[a0] + offsets[a0]
            c1 = from[a1] + offsets[a1]
        }

        let radius = hypot(from[a0] - c0, from[a1] - c1)
        let startAng = atan2(from[a1] - c1, from[a0] - c0)
        let endAng = atan2(to[a1] - c1, to[a0] - c0)
        var sweep = cw ? startAng - endAng : endAng - startAng
        if sweep <= 1e-9 { sweep += .pi * 2 }

        var steps = 1
        if radius > arcTolerance {
            let maxStep = 2 * acos(Swift.max(-1, 1 - arcTolerance / radius))
            steps = Int((sweep / maxStep).rounded(.up))
        }
        steps = Swift.min(Swift.max(steps, 2), 720)

        var out: [Segment] = []
        out.reserveCapacity(steps)
        var prev = from
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            var p: Vec3
            if i == steps {
                p = to
            } else {
                let ang = startAng + (cw ? -1 : 1) * sweep * t
                p = .zero
                p[a0] = c0 + radius * cos(ang)
                p[a1] = c1 + radius * sin(ang)
                p[lin] = from[lin] + (to[lin] - from[lin]) * t
            }
            out.append(Segment(line: lineIndex, type: .feed, from: prev, to: p, feed: feed, arc: true))
            prev = p
        }
        return out
    }
}

public struct ProgramAnalysis: Sendable {
    /// Number of source lines in the file.
    public var sourceLines: Int
    /// Number of lines that will actually be sent to the controller.
    public var streamLines: Int
    public var segments: [Segment]
    /// Bounds of every move (rapids included). Nil if the file has no motion.
    public var bounds: Bounds?
    /// Bounds of feed moves only (what the cutter cuts).
    public var cutBounds: Bounds?
    /// Rough run time in seconds (no acceleration).
    public var estSeconds: Double
    /// Total cutting distance, mm.
    public var feedDistance: Double
    /// Total rapid distance, mm.
    public var rapidDistance: Double
    /// The program starts the spindle (M3/M4).
    public var usesSpindle: Bool
    /// 0-based source line of the first feed move made with the spindle off (never started, M5, or S0), if any.
    /// GRBL runs such a move: the cutter is driven into the work standing still. Probe moves don't count.
    public var spindleOffCut: Int?
    /// Where the header says Z zero is taken, if it says (`zZeroReference`).
    public var zZero: ZZeroReference?
}

/// Split on \r\n, \r or \n, keeping empty lines (so indexes match the file's lines).
public func splitLines(_ text: String) -> [String] {
    var out: [String] = []
    var cur = [UInt8]()
    var lastCR = false
    for c in text.utf8 {
        if c == 10 {
            if lastCR { lastCR = false; continue }
            out.append(String(decoding: cur, as: UTF8.self))
            cur.removeAll(keepingCapacity: true)
        } else if c == 13 {
            out.append(String(decoding: cur, as: UTF8.self))
            cur.removeAll(keepingCapacity: true)
            lastCR = true
            continue
        } else {
            cur.append(c)
        }
        lastCR = false
    }
    out.append(String(decoding: cur, as: UTF8.self))
    return out
}

/// The program starts the spindle: an M3/M03/M4/M04 word.
func startsSpindle(_ clean: String) -> Bool {
    parseWords(clean).contains { $0.letter == "M" && ($0.value == 3 || $0.value == 4) }
}

/// Interpret a whole program: segments, bounds and a time estimate.
public func analyzeProgram(_ text: String, options: InterpreterOptions = .init(), keepSegments: Bool = true) -> ProgramAnalysis {
    let lines = splitLines(text)
    let interp = Interpreter(options)
    var segments: [Segment] = []
    var bounds: Bounds?
    var cutBounds: Bounds?
    var est = 0.0
    var feedDistance = 0.0
    var rapidDistance = 0.0
    var streamLines = 0
    var usesSpindle = false
    var spindle = SpindleTracker()
    var spindleOffCut: Int?

    for (i, raw) in lines.enumerated() {
        let clean = cleanLine(raw)
        if clean.isEmpty { continue }
        streamLines += 1
        if !usesSpindle && startsSpindle(clean) { usesSpindle = true }
        if spindle.cutsWithSpindleOff(clean), spindleOffCut == nil { spindleOffCut = i }
        for s in interp.step(clean, line: i) {
            let len = s.length
            if s.type == .rapid {
                rapidDistance += len
                est += len / interp.rapidRate * 60
            } else {
                feedDistance += len
                if s.feed > 0 { est += len / s.feed * 60 }
                cutBounds.grow(s.from)
                cutBounds.grow(s.to)
            }
            bounds.grow(s.from)
            bounds.grow(s.to)
            if keepSegments { segments.append(s) }
        }
    }
    est += interp.dwellSeconds
    return ProgramAnalysis(
        sourceLines: lines.count, streamLines: streamLines, segments: segments, bounds: bounds, cutBounds: cutBounds,
        estSeconds: est, feedDistance: feedDistance, rapidDistance: rapidDistance, usesSpindle: usesSpindle,
        spindleOffCut: spindleOffCut, zZero: zZeroReference(text))
}

/// 0-based source line of the first feed move at or after source line `from` made with the spindle off: the
/// spindle never started, stopped with M5 or M2/M30, or set to S0. Probe moves (G38.x) don't count.
public func spindleOffCut(_ text: String, from: Int = 0) -> Int? {
    spindleOffCuts(text).first { $0 >= from }
}

/// Every source line (0-based, ascending) with a feed move made with the spindle off; see `spindleOffCut`.
public func spindleOffCuts(_ text: String) -> [Int] {
    var spindle = SpindleTracker()
    var out: [Int] = []
    for (i, raw) in splitLines(text).enumerated() {
        let clean = cleanLine(raw)
        if !clean.isEmpty, spindle.cutsWithSpindleOff(clean) { out.append(i) }
    }
    return out
}

/// Why a start was refused: `line` is 0-based, from `spindleOffCut`.
public func spindleOffMessage(_ fileName: String, _ line: Int) -> String {
    "\(fileName) cuts with the spindle off: line \(line + 1) is a cutting move, and the program hasn't started the spindle "
        + "(M3 with an S speed) by then. Add M3 S… to the file, or confirm in the Start dialog that the spindle is run by hand"
}

/// Whether the spindle is turning as a program runs, line by line. Works from the words alone, not from drawn moves:
/// the interpreter draws nothing until every axis has a position, and a cut before that still cuts.
struct SpindleTracker {
    var direction = 5.0
    var speed = 0.0
    /// Modal motion: 0-3 for G0-G3, -1 after G80 or G38.x.
    var motion = 0.0
    var on: Bool { direction != 5 && speed > 0 }

    /// Applies a cleaned line, and says whether it makes a feed move (G1/G2/G3) with the spindle off. GRBL starts the
    /// spindle before it runs a block's motion, so an M3 on the same line counts. Probing (G38.x) and the axis words
    /// of non-motion commands (G10, G28, G30, G92) aren't cuts.
    mutating func cutsWithSpindleOff(_ clean: String) -> Bool {
        var moves = false, arcWords = false, nonMotion = false
        var stopAfter = false
        for w in parseWords(clean) {
            switch w.letter {
            case "M" where w.value == 3 || w.value == 4 || w.value == 5: direction = w.value
            case "M" where w.value == 2 || w.value == 30: stopAfter = true   // program end stops the spindle
            case "S": speed = w.value
            case "G" where [0, 1, 2, 3].contains(w.value): motion = w.value
            case "G" where w.value == 80: motion = -1
            case "G" where w.value >= 38 && w.value < 39: motion = -1   // probing is modal too
            case "G" where [10, 28, 30, 92, 28.1, 30.1, 92.1].contains(w.value): nonMotion = true
            case "X", "Y", "Z": moves = true
            case "I", "J", "K", "R": arcWords = true
            default: break
            }
        }
        let feed = motion == 1 || motion == 2 || motion == 3
        let cuts = feed && !nonMotion && (moves || (motion != 1 && arcWords)) && !on
        if stopAfter { direction = 5 }
        return cuts
    }
}

public struct StreamLine: Equatable, Sendable {
    public var text: String
    /// 0-based source line it came from.
    public var source: Int
    public init(text: String, source: Int) {
        self.text = text
        self.source = source
    }
}

/// The lines a sender actually streams, with the source line each came from.
public func streamableLines(_ text: String) -> [StreamLine] {
    var out: [StreamLine] = []
    for (i, raw) in splitLines(text).enumerated() {
        let clean = cleanLine(raw)
        if !clean.isEmpty { out.append(StreamLine(text: clean, source: i)) }
    }
    return out
}
