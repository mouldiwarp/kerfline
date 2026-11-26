// Resuming a program part way through: work out the modal state at a line (units, distance mode,
// plane, work offset, spindle, coolant, feed) and where the tool is when that line starts, so a
// preamble can put the machine back in that state. Port of packages/shared/src/resume.ts.

import Foundation

public struct ProgramState: Equatable, Sendable {
    public var inches = false
    public var absolute = true
    /// 17, 18 or 19.
    public var plane = 17
    /// 0-3 (G0-G3), or -1 after G80.
    public var motion = 0
    /// 54-59.
    public var wcs = 54
    /// 93 or 94.
    public var feedMode = 94
    /// Feed in program units per minute (or inverse time).
    public var feed = 0.0
    /// "M3", "M4" or "M5".
    public var spindle = "M5"
    public var speed = 0.0
    public var mist = false
    public var flood = false
    /// Where the tool is (work coordinates, mm); nil for an axis no line has set yet.
    public var pos: [Double?] = [nil, nil, nil]
    /// Things the preamble can't restore.
    public var warnings: [String] = []
}

/// The program's state just before stream line `index` (0-based, as streamableLines numbers them).
public func stateAt(_ text: String, _ index: Int) -> ProgramState {
    var st = ProgramState()
    for sl in streamableLines(text).prefix(max(0, index)) { st.apply(sl.text) }
    return st
}

extension ProgramState {
    /// Applies one streamed (cleaned) line.
    mutating func apply(_ line: String) {
        func warn(_ w: String) {
            if !warnings.contains(w) { warnings.append(w) }
        }
        if line.hasPrefix("$") || line.hasPrefix("[") { return }
        var nonModal: Double?
        var motionWord: Int?
        var axis: [Double?] = [nil, nil, nil]
        for w in parseWords(line) {
            switch w.letter {
            case "G":
                let g = w.value
                if [0, 1, 2, 3].contains(g) { motionWord = Int(g) }
                else if g == 80 { motionWord = -1 }
                else if [38.2, 38.3, 38.4, 38.5].contains(g) {
                    motionWord = nil
                    nonModal = 38
                    warn("The program probes before this line; the resume uses the work offset as it is now")
                } else if g == 17 || g == 18 || g == 19 { self.plane = Int(g) }
                else if g == 20 { self.inches = true }
                else if g == 21 { self.inches = false }
                else if g == 90 { self.absolute = true }
                else if g == 91 { self.absolute = false }
                else if g == 93 || g == 94 { self.feedMode = Int(g) }
                else if g >= 54 && g <= 59 { self.wcs = Int(g.rounded()) }
                else if g == 92 {
                    nonModal = 92
                    warn("The program sets G92 offsets before this line, which a resume cannot restore")
                } else if [10, 28, 30, 53, 4, 28.1, 30.1, 92.1].contains(g) { nonModal = g }
            case "M":
                switch w.value {
                case 3: self.spindle = "M3"
                case 4: self.spindle = "M4"
                case 5: self.spindle = "M5"
                case 7: self.mist = true
                case 8: self.flood = true
                case 9:
                    self.mist = false
                    self.flood = false
                case 6: warn("The program changes tools (M6) before this line: check the right bit is fitted")
                default: break
                }
            case "S": self.speed = w.value
            case "F": self.feed = w.value
            case "X": axis[0] = w.value
            case "Y": axis[1] = w.value
            case "Z": axis[2] = w.value
            default: break
            }
        }
        if let m = motionWord { self.motion = m }
        if nonModal == 28 || nonModal == 30 {
            warn("The program returns to G28/G30 before this line; the start position may be unknown")
            self.pos = [nil, nil, nil]
            return
        }
        if nonModal == 53 && axis.contains(where: { $0 != nil }) {
            warn("The program makes machine-coordinate (G53) moves before this line")
            self.pos = [nil, nil, nil]
            return
        }
        if nonModal != nil || self.motion < 0 { return }
        let scale = self.inches ? 25.4 : 1
        for i in 0..<3 {
            guard let v = axis[i] else { continue }
            if self.absolute { self.pos[i] = v * scale } else if let p = self.pos[i] { self.pos[i] = p + v * scale }
        }
    }
}

/// How to get the tool to where a program (or a resume) starts.
public struct ResumeOptions: Sendable {
    /// Work Z of the top of the travel, less a margin, when the machine is homed (so it's known); nil if not.
    public var topZ: Double?
    /// Where the tool is now, work Z; nil if not known.
    public var currentZ: Double?
    /// The app's safe Z: the travel height when neither the top of travel nor the program's own heights are known.
    public var safeZ: Double
    /// Seconds to let the spindle reach speed.
    public var spinup: Double
    /// Feed for lowering onto the resume point, mm/min.
    public var plungeFeed: Double
    public init(topZ: Double?, currentZ: Double?, safeZ: Double = 5, spinup: Double, plungeFeed: Double) {
        self.topZ = topZ
        self.currentZ = currentZ
        self.safeZ = safeZ
        self.spinup = spinup
        self.plungeFeed = plungeFeed
    }

    /// The options for a machine as it is now: homed, it travels just under the top of Z (1 mm margin).
    public init(machine: MachineState, config: MachineConfig, spinup: Double = 4) {
        let homed = machine.homed == true
        self.init(
            topZ: homed ? config.envelope.max[2] - 1 - machine.wco[2] : nil, currentZ: machine.wpos[2], safeZ: config.safeZ,
            spinup: spinup, plungeFeed: min(300, config.jogFeedZ))
    }

    /// Work Z to cross the work at: the top of travel when that's known, else the program's own highest Z (going higher
    /// could hit the top of travel, wherever that is), else safe Z. Never lower than the tool is now.
    func travelZ(programTop: Double?) -> Double {
        let up = topZ ?? programTop ?? safeZ
        return max(up, currentZ ?? up)
    }
}

/// What a program does with Z: its highest point, and where it first has both X and Y.
struct ProgramShape {
    var topZ: Double?
    /// The first point (work XY, mm) the program goes to, and the state when it gets there.
    var first: (x: Double, y: Double, state: ProgramState)?

    init(_ text: String) {
        var st = ProgramState()
        for sl in streamableLines(text) {
            st.apply(sl.text)
            if let z = st.pos[2] { topZ = max(topZ ?? z, z) }
            if first == nil, let x = st.pos[0], let y = st.pos[1] { first = (x, y, st) }
        }
    }
}

public struct ResumePlan: Sendable {
    /// Lines to send before the program's own lines.
    public var preamble: [String]
    public var state: ProgramState
    /// Where the program resumes (work coordinates, mm).
    public var start: Vec3
    /// The Z it crosses the work at, and the Z it rapids down to before feeding onto the start point.
    public var travelZ: Double
    public var clearZ: Double
}

public struct ResumeError: Error, CustomStringConvertible {
    public var description: String
}

/// Lines that put the machine where line `index` expects it, in this order so the cutter never crosses the work low
/// or reaches it standing still: restore the modes, lift straight up to the travel height (the top of Z when homed),
/// start the spindle and let it reach speed, move along X, then along Y, rapid down to the program's own highest Z,
/// feed down onto the start point, then restore the program's units, distance mode, motion and feed. Throws if the
/// start point isn't known.
public func planResume(_ text: String, _ index: Int, _ opts: ResumeOptions) throws -> ResumePlan {
    var state = stateAt(text, index)
    guard let x = state.pos[0], let y = state.pos[1], let z = state.pos[2] else {
        throw ResumeError(description: "The tool's position before that line isn't known (the program hasn't set X, Y and Z yet). Pick a later line")
    }
    let f = gnum
    let shape = ProgramShape(text)
    // Preamble moves in mm, absolute, units-per-minute feed; the program's own modes come back after.
    var pre = ["G21G90G\(state.plane)G94G\(state.wcs)"]
    let travel = max(opts.travelZ(programTop: shape.topZ), z)
    pre.append("G0Z\(f(travel))")
    if state.spindle != "M5" {
        pre.append("\(state.spindle)S\(f(state.speed))")
        if opts.spinup > 0 { pre.append("G4P\(f(opts.spinup))") }
    }
    if state.mist { pre.append("M7") }
    if state.flood { pre.append("M8") }
    pre.append("G0X\(f(x))")
    pre.append("G0Y\(f(y))")
    // Rapid down to where the program itself travels (at least 5 mm above the start point), then feed the rest.
    let clear = min(travel, max(shape.topZ ?? z, z + 5))
    if clear < travel { pre.append("G0Z\(f(clear))") }
    if z < clear { pre.append("G1Z\(f(z))F\(f(opts.plungeFeed))") }
    // Back to the program's own modes for the lines that follow, with the feed on the same line: GRBL refuses G1
    // (error:22) while no feed is set, which is the case after a reset if no plunge was needed.
    var modes = [state.inches ? "G20" : "G21", state.absolute ? "G90" : "G91"]
    if state.feedMode == 93 { modes.append("G93") }
    if state.motion == 0 || state.motion == 1 { modes.append("G\(state.motion)") } else if state.motion == -1 { modes.append("G80") }
    if state.feedMode == 94 {
        if state.feed > 0 { modes.append("F\(f(state.feed))") } else { modes.append("F\(f(opts.plungeFeed))") }
    }
    pre.append(modes.joined())
    if state.motion == 2 || state.motion == 3 {
        state.warnings.append("The program is mid-arc at this line; arcs restart from the resume point, so check the preview")
    }
    return ResumePlan(preamble: pre, state: state, start: Vec3(x, y, z), travelZ: travel, clearZ: clear)
}

/// Lines to send before a program run from the start, so it never moves the cutter down before it's over the work: lift
/// straight up to the travel height (the top of Z when homed), move along X, then along Y, to the first point the
/// program goes to. The program then lowers there itself. Empty if the program never sets X and Y.
public func planStart(_ text: String, _ opts: ResumeOptions) -> [String] {
    let shape = ProgramShape(text)
    guard let first = shape.first else { return [] }
    let f = gnum
    return [
        "G21G90G94G\(first.state.wcs)", "G0Z\(f(opts.travelZ(programTop: shape.topZ)))", "G0X\(f(first.x))", "G0Y\(f(first.y))",
    ]
}

/// Whether a streamed line makes the machine move (and so takes a planner block): it has an axis
/// word and isn't a dwell (G4/G04), G10 or G92.
public func isMotionLine(_ clean: String) -> Bool {
    let b = Array(clean.uppercased().utf8)
    guard b.contains(where: { $0 == UInt8(ascii: "X") || $0 == UInt8(ascii: "Y") || $0 == UInt8(ascii: "Z") }) else { return false }
    func at(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
    func endsCode(_ i: Int) -> Bool { at(i).map { !isDigit($0) && $0 != UInt8(ascii: ".") } ?? true }
    for i in b.indices where b[i] == UInt8(ascii: "G") {
        let d1 = at(i + 1), d2 = at(i + 2)
        if d1 == UInt8(ascii: "4") && endsCode(i + 2) { return false }
        if d1 == UInt8(ascii: "0") && d2 == UInt8(ascii: "4") && endsCode(i + 3) { return false }
        if d1 == UInt8(ascii: "1") && d2 == UInt8(ascii: "0") && endsCode(i + 3) { return false }
        if d1 == UInt8(ascii: "9") && d2 == UInt8(ascii: "2") { return false }
    }
    return true
}

/// The source text of a stream line, for showing the user where a resume starts.
public func sourceLineText(_ text: String, _ index: Int) -> StreamLine? {
    let sl = streamableLines(text)
    guard index >= 0, index < sl.count else { return nil }
    let raw = splitLines(text)[sl[index].source]
    return StreamLine(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), source: sl[index].source)
}
