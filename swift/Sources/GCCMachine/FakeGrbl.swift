// An in-process GRBL 1.1 simulator that stands in for the USB machine. Port of
// packages/agent/src/sim/fakeGrbl.ts.
//
// It models what a sender has to get right: a 128-byte serial RX buffer that overflows if the host
// over-sends, a 15-block planner, `ok` sent when a line is planned (not finished), realtime bytes
// that bypass the buffer, alarms on boot / reset-in-motion / soft limits, homing, jogging, work
// offsets, feed hold and overrides. Motion runs in simulated time (speed multiplier) so jobs can be
// watched live or fast-forwarded in tests.
//
// All state is guarded by one lock; replies go out through the event stream, never by calling
// back into the host, so the host can write from anywhere.

import Foundation
import GCCCore

public struct FakeGrblOptions: Sendable {
    /// Simulated seconds per real second.
    public var speed = 1.0
    public var rxSize = 128
    public var plannerSize = 15
    /// Boot into ALARM until $H or $X, as GRBL does with homing enabled.
    public var homingRequired = true
    /// Raise ALARM:2 for moves outside the envelope.
    public var softLimits = false
    /// Travel per axis (machine coords run from -travel to 0).
    public var travel = Vec3(800, 800, 120)
    /// G54 work offset at power-on (GRBL keeps it across restarts). Defaults to a spot on the bed
    /// below the top of Z, so programs that lift to a safe height stay inside the travel.
    public var workOffset = Vec3(-400, -400, -60)
    public var rapidRate = 5000.0
    public var tickMs = 10
    /// Report a fourth (A) axis in probe results, as FoxAlien's 4-axis GRBL does.
    public var fourAxis = false
    /// Print the banner when the port opens (false for 32-bit boards that don't reset on open).
    public var bannerOnOpen = true
    /// Delay before the welcome banner, ms (real time).
    public var bootDelayMs = 50
    /// Machine Z of the touch plate's top surface under the bit (the probe input closes when the
    /// bit reaches it). nil means no plate: probes find nothing.
    public var probeSurfaceZ: Double? = -60
    /// Built with single-axis homing (`$HX`…, "H" in `[OPT:]`). Stock GRBL 1.1 isn't: `$HX` is error:3.
    public var singleAxisHoming = true

    public init(
        speed: Double = 1, homingRequired: Bool = true, softLimits: Bool = false, workOffset: Vec3 = Vec3(-400, -400, -60),
        bootDelayMs: Int = 50, fourAxis: Bool = false, bannerOnOpen: Bool = true, probeSurfaceZ: Double? = -60
    ) {
        self.speed = speed
        self.homingRequired = homingRequired
        self.softLimits = softLimits
        self.workOffset = workOffset
        self.bootDelayMs = bootDelayMs
        self.fourAxis = fourAxis
        self.bannerOnOpen = bannerOnOpen
        self.probeSurfaceZ = probeSurfaceZ
    }
}

public enum SimState: String, Sendable {
    case idle = "Idle", run = "Run", hold = "Hold", jog = "Jog", alarm = "Alarm", home = "Home", check = "Check"
}

private struct Block {
    /// Machine-coordinate polyline still to travel.
    var points: [Vec3]
    var feed: Double
    var rapid: Bool
    var jog: Bool
    /// A probe move: report the result when it completes.
    var probe: (contact: Bool, alarmOnMiss: Bool)?
}

private let version = "1.1h.20190825"

nonisolated(unsafe) private let syncRegex = try! Regex(#"G10|G92|G28|G30|G38|G0?4(?![\d.])|M0?[0125](?!\d)|M30"#)
nonisolated(unsafe) private let wordsRegex = try! Regex(#"^(?:[A-Z][-+]?(?:\d+\.?\d*|\.\d+))+$"#).ignoresCase()
nonisolated(unsafe) private let settingRegex = try! Regex(#"^\$(\d+)=(-?[\d.]+)$"#)

public final class FakeGrbl: Transport, @unchecked Sendable {
    public let name = "simulator"
    public let simulated = true

    private let lock = NSLock()
    private let pipe = EventPipe()
    private let queue = DispatchQueue(label: "FakeGrbl")
    private var timer: DispatchSourceTimer?
    private var isOpen = false
    private var opts: FakeGrblOptions

    // Serial
    private var rx: [UInt8] = []
    private var _overflowed = false
    private var _received: [String] = []

    // Machine
    private var _state = SimState.idle
    private var holdComplete = false
    private var _mpos = Vec3.zero
    private var _wco = Vec3.zero
    private var planner: [Block] = []
    private let interp: Interpreter
    private var spindleOn = false
    private var _spindleStopped = false
    private var spindleSpeed = 0.0
    private var feedOv = 100.0
    private var rapidOv = 100.0
    private var spindleOv = 100.0
    private var reportCount = 0
    private var lastWco = ""
    private var lastOv = ""
    private var homingRemaining = 0.0
    /// The axes the homing cycle in progress homes.
    private var homingAxes: [Int] = [0, 1, 2]
    private var probing = false
    private var pendingOkAfterHome = false
    private var dropOks = 0
    /// Opened but not booted yet: like GRBL resetting as the port opens, nothing is read until the
    /// banner. (Reading first let a late boot reset the state under a move that had already started.)
    private var booting = false
    private var settings: [Int: Double]

    public init(_ opts: FakeGrblOptions = .init()) {
        self.opts = opts
        _wco = opts.workOffset
        interp = Interpreter(.init(rapidRate: opts.rapidRate))
        settings = [
            0: 10, 1: 25, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 10: 3, 11: 0.01, 12: 0.002, 13: 0,
            20: opts.softLimits ? 1 : 0, 21: 0, 22: 1, 23: 0, 24: 100, 25: 1000, 26: 250, 27: 2,
            30: 1000, 31: 0, 32: 0, 100: 400, 101: 400, 102: 400, 110: 5000, 111: 5000, 112: 2000,
            120: 500, 121: 500, 122: 200,
            130: opts.travel[0], 131: opts.travel[1], 132: opts.travel[2],
        ]
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    // MARK: For tests and the CLI

    public var state: SimState { locked { _state } }
    public var mpos: Vec3 { locked { _mpos } }
    public var wco: Vec3 { locked { _wco } }
    /// Set if the host ever sent more than the RX buffer holds.
    public var overflowed: Bool { locked { _overflowed } }
    /// Every line GRBL processed, in order.
    public var received: [String] { locked { _received } }
    public func clearReceived() { locked { _received.removeAll() } }
    /// Spindle stopped by the spindle-stop override during a hold.
    public var spindleStopped: Bool { locked { _spindleStopped } }

    // MARK: Transport

    public var events: AsyncStream<TransportEvent> { pipe.stream }

    public func open() async throws {
        locked {
            isOpen = true
            booting = opts.bannerOnOpen
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(opts.tickMs))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
        if opts.bannerOnOpen {
            queue.asyncAfter(deadline: .now() + .milliseconds(opts.bootDelayMs)) { [weak self] in
                guard let self else { return }
                self.locked { self.boot() }
            }
        }
    }

    public func close() async {
        locked {
            isOpen = false
            timer?.cancel()
            timer = nil
        }
        pipe.continuation.yield(.closed(nil))
        pipe.continuation.finish()
    }

    public func write(_ bytes: [UInt8]) {
        locked {
            guard isOpen else { return }
            for b in bytes {
                if handleRealtime(b) { continue }
                if rx.count >= opts.rxSize {
                    _overflowed = true // real GRBL silently drops the byte
                    continue
                }
                rx.append(b)
            }
        }
    }

    // MARK: Fault injection

    /// Simulate a USB unplug.
    public func unplug() {
        locked {
            isOpen = false
            timer?.cancel()
            timer = nil
        }
        pipe.continuation.yield(.closed(MachineError("Simulated USB disconnect")))
        pipe.continuation.finish()
    }

    /// Raise an alarm as if a limit switch tripped.
    public func injectAlarm(_ code: Int = 1) {
        locked {
            planner = []
            _state = .alarm
            send("ALARM:\(code)")
        }
    }

    /// Lose the next reply, as a glitch on the USB link might.
    public func dropNextOk() { locked { dropOks += 1 } }

    // MARK: Internals (called with the lock held)

    private func send(_ line: String) {
        if line == "ok" && dropOks > 0 {
            dropOks -= 1
            return
        }
        pipe.continuation.yield(.data(Array((line + "\r\n").utf8)))
    }

    private func boot() {
        guard isOpen else { return }
        booting = false
        send("")
        send("Grbl 1.1h ['$' for help]")
        if opts.homingRequired {
            _state = .alarm
            send("[MSG:'$H'|'$X' to unlock]")
        } else {
            _state = .idle
        }
    }

    private func plannedEnd() -> Vec3 { planner.last?.points.last ?? _mpos }

    private func handleRealtime(_ code: UInt8) -> Bool {
        switch code {
        case RT.status:
            report()
        case RT.feedHold:
            if _state == .jog {
                planner = []
                _state = .idle
            } else if _state == .run {
                _state = .hold
                holdComplete = true
            }
        case RT.cycleStart:
            if _state == .hold {
                _spindleStopped = false // the spindle comes back on before motion resumes
                _state = planner.isEmpty ? .idle : .run
                holdComplete = false
            }
        case RT.softReset:
            softReset()
        case RT.jogCancel:
            if _state == .jog {
                planner.removeAll { $0.jog }
                let lines = rx.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                rx = Array(lines.filter { !$0.starts(with: Array("$J=".utf8)) }.joined(separator: [UInt8(ascii: "\n")]))
                _state = .idle
            }
        default:
            guard code >= 0x80 else { return false }
            override(code)
        }
        return true
    }

    private func override(_ code: UInt8) {
        func clamp(_ v: Double) -> Double { min(200, max(10, v)) }
        switch code {
        case RT.spindleStop: if _state == .hold && holdComplete { _spindleStopped.toggle() }
        case RT.feedOvReset: feedOv = 100
        case RT.feedOvPlus10: feedOv = clamp(feedOv + 10)
        case RT.feedOvMinus10: feedOv = clamp(feedOv - 10)
        case RT.feedOvPlus1: feedOv = clamp(feedOv + 1)
        case RT.feedOvMinus1: feedOv = clamp(feedOv - 1)
        case RT.rapidOv100: rapidOv = 100
        case RT.rapidOv50: rapidOv = 50
        case RT.rapidOv25: rapidOv = 25
        case RT.spindleOvReset: spindleOv = 100
        case RT.spindleOvPlus10: spindleOv = clamp(spindleOv + 10)
        case RT.spindleOvMinus10: spindleOv = clamp(spindleOv - 10)
        case RT.spindleOvPlus1: spindleOv = clamp(spindleOv + 1)
        case RT.spindleOvMinus1: spindleOv = clamp(spindleOv - 1)
        default: break
        }
    }

    private func softReset() {
        let moving = (_state == .run || _state == .jog || _state == .home) && !holdComplete
        rx = []
        planner = []
        interp.reset()
        spindleOn = false
        _spindleStopped = false
        holdComplete = false
        pendingOkAfterHome = false
        homingRemaining = 0
        probing = false
        if moving {
            _state = .alarm
            send("ALARM:3")
        } else if _state != .alarm {
            _state = .idle
        }
        send("")
        send("Grbl 1.1h ['$' for help]")
        if _state == .alarm { send("[MSG:'$H'|'$X' to unlock]") }
    }

    private func f3(_ v: Vec3) -> String { (0..<3).map { fixed(v[$0], 3) }.joined(separator: ",") }

    private func report() {
        var state = _state.rawValue
        if _state == .hold { state = holdComplete ? "Hold:0" : "Hold:1" }
        let feed = planner.first.map { _state == .run || _state == .jog ? effectiveFeed($0) : 0 } ?? 0
        let spinning = spindleOn && !_spindleStopped
        let speed = spinning ? (spindleSpeed * spindleOv / 100).rounded() : 0
        var s = "<\(state)|MPos:\(f3(_mpos))|Bf:\(opts.plannerSize - planner.count),\(opts.rxSize - rx.count)|FS:\(jsNumber(feed.rounded())),\(jsNumber(speed))"
        if probeTouching() { s += "|Pn:P" }
        if spinning { s += "|A:S" }
        let wco = f3(_wco)
        let ov = "\(jsNumber(feedOv)),\(jsNumber(rapidOv)),\(jsNumber(spindleOv))"
        reportCount += 1
        if wco != lastWco || reportCount % 10 == 0 {
            s += "|WCO:\(wco)"
            lastWco = wco
        } else if ov != lastOv || reportCount % 10 == 5 {
            s += "|Ov:\(ov)"
            lastOv = ov
        }
        send(s + ">")
    }

    /// The probe input: closed while the bit rests on the plate.
    private func probeTouching() -> Bool {
        guard let surface = opts.probeSurfaceZ else { return false }
        return _mpos[2] <= surface + 1e-6
    }

    private func effectiveFeed(_ b: Block) -> Double {
        if b.rapid { return opts.rapidRate * rapidOv / 100 }
        if b.jog { return b.feed }
        return b.feed * feedOv / 100
    }

    private func tick() {
        locked {
            guard isOpen, !booting else { return }
            processRx()
            move(Double(opts.tickMs) / 1000 * opts.speed)
        }
    }

    private func move(_ dt: Double) {
        if _state == .home {
            homingRemaining -= dt
            // Travel toward the homing corner while homing.
            for i in homingAxes { _mpos[i] += (0 - _mpos[i]) * min(1, dt * 2) }
            if homingRemaining <= 0 {
                for i in homingAxes { _mpos[i] = 0 }
                _state = .idle
                if pendingOkAfterHome { send("ok") }
                pendingOkAfterHome = false
            }
            return
        }
        guard _state == .run || _state == .jog else { return }
        var remaining = dt
        while remaining > 0, !planner.isEmpty {
            let mmPerSec = max(effectiveFeed(planner[0]), 1) / 60
            var travel = mmPerSec * remaining
            while travel > 0, let target = planner[0].points.first {
                let d = simd_length_(target - _mpos)
                if d <= travel {
                    _mpos = target
                    planner[0].points.removeFirst()
                    travel -= d
                } else {
                    _mpos += (target - _mpos) * (travel / d)
                    travel = 0
                }
            }
            remaining = travel / mmPerSec
            if planner[0].points.isEmpty {
                let b = planner.removeFirst()
                if let p = b.probe { finishProbe(p) }
            }
            if travel <= 0 { break }
        }
        if planner.isEmpty && (_state == .run || _state == .jog) { _state = .idle }
    }

    private func finishProbe(_ p: (contact: Bool, alarmOnMiss: Bool)) {
        probing = false
        if !p.contact && p.alarmOnMiss {
            planner = []
            _state = .alarm
            send("ALARM:5")
            return
        }
        var prb = f3(_mpos)
        if opts.fourAxis { prb += ",0.000" }
        send("[PRB:\(prb):\(p.contact ? 1 : 0)]")
        send("ok")
    }

    private func processRx() {
        while isOpen {
            // GRBL's parser blocks until a probe cycle finishes.
            if probing { return }
            guard let nl = rx.firstIndex(of: UInt8(ascii: "\n")) else { return }
            var raw = rx[..<nl]
            if raw.last == UInt8(ascii: "\r") { raw = raw.dropLast() }
            let line = cleanLine(latin1(raw))
            // Lines that need the planner empty first wait (GRBL syncs these).
            if needsSync(line) && (!planner.isEmpty || _state == .home) { return }
            if isMotion(line) && planner.count >= opts.plannerSize { return }
            if _state == .home { return }
            rx.removeSubrange(...nl)
            _received.append(line)
            execute(line)
        }
    }

    private func isMotion(_ line: String) -> Bool {
        line.hasPrefix("$J=") || (!line.hasPrefix("$") && line.contains { $0 == "X" || $0 == "Y" || $0 == "Z" })
    }

    private func needsSync(_ line: String) -> Bool {
        if line.hasPrefix("$J=") { return false }
        if line.hasPrefix("$") { return true }
        return line.contains(syncRegex)
    }

    private func execute(_ line: String) {
        if line.isEmpty { return send("ok") }
        if line.hasPrefix("$") { return system(line) }
        if _state == .alarm || _state == .jog { return send("error:9") }
        // Like GRBL: every word must start with a letter (error:1, "letter not found").
        if line.wholeMatch(of: wordsRegex) == nil { return send("error:1") }
        gcode(line)
    }

    private func system(_ line: String) {
        switch line {
        case "$$":
            for k in settings.keys.sorted() { send("$\(k)=\(jsNumber(settings[k]!))") }
            return send("ok")
        case "$#":
            send("[G54:\(f3(_wco))]")
            for g in ["G55", "G56", "G57", "G58", "G59"] { send("[\(g):0.000,0.000,0.000]") }
            send("[G28:0.000,0.000,0.000]")
            send("[G30:0.000,0.000,0.000]")
            send("[G92:0.000,0.000,0.000]")
            send("[TLO:0.000]")
            send("[PRB:0.000,0.000,0.000:0]")
            return send("ok")
        case "$G":
            let i = interp
            send("[GC:G\(i.motion) G54 G\(17 + i.plane) G\(i.inches ? 20 : 21) G\(i.absolute ? 90 : 91) G94 M\(spindleOn ? 3 : 5) M9 T0 F\(jsNumber(i.feed)) S\(jsNumber(spindleSpeed))]")
            return send("ok")
        case "$I":
            send("[VER:\(version):]")
            send("[OPT:V\(opts.singleAxisHoming ? "H" : ""),\(opts.plannerSize),\(opts.rxSize)]")
            return send("ok")
        case "$X":
            if _state == .alarm {
                _state = .idle
                send("[MSG:Caution: Unlocked]")
            }
            return send("ok")
        case "$H":
            if _state != .idle && _state != .alarm { return send("error:8") }
            _state = .home
            homingAxes = [0, 1, 2]
            homingRemaining = 2 // simulated seconds
            pendingOkAfterHome = true
            return
        case "$HX", "$HY", "$HZ":
            guard opts.singleAxisHoming else { return send("error:3") }
            if _state != .idle && _state != .alarm { return send("error:8") }
            _state = .home
            homingAxes = [["$HX": 0, "$HY": 1, "$HZ": 2][line]!]
            homingRemaining = 1
            pendingOkAfterHome = true
            return
        case "$C", "$SLP", "$N", "$RST=*", "$RST=$", "$RST=#":
            return send("ok")
        default:
            break
        }
        if line.hasPrefix("$J=") { return jog(String(line.dropFirst(3))) }
        if let m = line.wholeMatch(of: settingRegex), let k = Int(m.output[1].substring ?? ""), let v = Double(m.output[2].substring ?? "") {
            if _state != .idle && _state != .alarm { return send("error:8") }
            settings[k] = v
            if k == 20 { opts.softLimits = v == 1 }
            return send("ok")
        }
        send("error:3")
    }

    private func jog(_ body: String) {
        if _state != .idle && _state != .jog { return send("error:8") }
        let words = parseWords(body)
        let g = words.filter { $0.letter == "G" }.map(\.value)
        if !words.contains(where: { $0.letter == "F" }) { return send("error:22") }
        let incremental = g.contains(91)
        let machine = g.contains(53)
        let scale = g.contains(20) ? 25.4 : 1
        let start = plannedEnd()
        var target = start
        var feed = 0.0
        for w in words {
            if w.letter == "F" { feed = w.value * scale }
            guard let i = axisIndex(w.letter) else { continue }
            let v = w.value * scale
            if incremental { target[i] = start[i] + v } else if machine { target[i] = v } else { target[i] = v + _wco[i] }
        }
        if !allowed([target]) { return send("error:15") }
        planner.append(Block(points: [target], feed: feed, rapid: false, jog: true))
        _state = .jog
        send("ok")
    }

    /// Soft limits when enabled; otherwise only the top of Z, which is always enforced so the
    /// simulator can't end up above the travel (a real machine would hit its Z limit switch).
    private func allowed(_ points: [Vec3]) -> Bool {
        if opts.softLimits { return points.allSatisfy(inEnvelope) }
        return points.allSatisfy { $0[2] <= 0.001 }
    }

    private func inEnvelope(_ p: Vec3) -> Bool {
        (0..<3).allSatisfy { p[$0] <= 0.001 && p[$0] >= -opts.travel[$0] - 0.001 }
    }

    private func gcode(_ line: String) {
        let words = parseWords(line)
        let gs = words.filter { $0.letter == "G" }.map(\.value)
        let axisWords = words.filter { axisIndex($0.letter) != nil }

        // Spindle
        for w in words {
            if w.letter == "S" { spindleSpeed = w.value }
            if w.letter == "M" {
                if w.value == 3 || w.value == 4 { spindleOn = true }
                if w.value == 5 || w.value == 2 || w.value == 30 { spindleOn = false }
            }
        }

        // Work offsets
        if gs.contains(10) {
            let l = words.first { $0.letter == "L" }?.value
            let scale = interp.inches ? 25.4 : 1
            for w in axisWords {
                let i = axisIndex(w.letter)!
                if l == 20 { _wco[i] = _mpos[i] - w.value * scale } else if l == 2 { _wco[i] = w.value * scale }
            }
            return send("ok")
        }
        if gs.contains(92) || gs.contains(28) || gs.contains(30) { return send("ok") }

        // Machine-coordinate move
        if gs.contains(53) {
            var target = plannedEnd()
            for w in axisWords { target[axisIndex(w.letter)!] = w.value }
            return plan([target], feed: gs.contains(1) ? interp.feed : 0, rapid: !gs.contains(1))
        }

        if let probeG = gs.first(where: { [38.2, 38.3, 38.4, 38.5].contains($0) }) { return probe(line, probeG) }

        // Normal motion, interpreted in work coordinates.
        interp.setPosition(plannedEnd() - _wco)
        let motionBefore = interp.motion
        let segs = interp.step(line)
        guard let first = segs.first else { return send("ok") }
        let feedMove = first.type == .feed
        if feedMove && !(first.feed > 0) {
            interp.motion = motionBefore
            return send("error:22")
        }
        plan(segs.map { $0.to + _wco }, feed: first.feed, rapid: !feedMove)
    }

    /// G38.2 / G38.3 toward the plate (G38.4 / G38.5, probing away, are treated as misses).
    private func probe(_ line: String, _ g: Double) {
        let start = _mpos
        interp.setPosition(start - _wco)
        let motionBefore = interp.motion
        let segs = interp.step(line)
        interp.motion = motionBefore // G38 is not a modal motion GRBL keeps
        guard let first = segs.first else { return send("error:26") } // no axis words
        if !(first.feed > 0) { return send("error:22") }
        let towards = g == 38.2 || g == 38.3
        let alarmOnMiss = g == 38.2 || g == 38.4
        if towards && probeTouching() {
            // Already touching before the move: GRBL raises "probe fail, initial state".
            _state = .alarm
            send("ALARM:4")
            return
        }
        let target = first.to + _wco
        var end = target
        var contact = false
        if towards, let surface = opts.probeSurfaceZ, start[2] > surface, target[2] <= surface {
            let k = (start[2] - surface) / (start[2] - target[2])
            end = Vec3(start[0] + (target[0] - start[0]) * k, start[1] + (target[1] - start[1]) * k, surface)
            contact = true
        }
        planner.append(Block(points: [end], feed: first.feed, rapid: false, jog: false, probe: (contact, alarmOnMiss)))
        probing = true
        _state = .run
    }

    private func plan(_ points: [Vec3], feed: Double, rapid: Bool) {
        if !allowed(points) {
            planner = []
            _state = .alarm
            send("ALARM:2")
            return
        }
        planner.append(Block(points: points, feed: feed, rapid: rapid, jog: false))
        if _state == .idle { _state = .run }
        send("ok")
    }
}

private func axisIndex(_ letter: Character) -> Int? {
    switch letter {
    case "X": 0
    case "Y": 1
    case "Z": 2
    default: nil
    }
}

private func simd_length_(_ v: Vec3) -> Double { (v * v).sum().squareRoot() }
