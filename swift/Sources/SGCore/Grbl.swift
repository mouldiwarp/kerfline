// GRBL 1.1 serial protocol: realtime bytes, response classification, status report parsing and
// the error / alarm / setting reference tables. Port of packages/shared/src/grbl.ts.

import Foundation

/// Realtime command bytes: GRBL acts on these immediately instead of queueing them.
public enum RT {
    public static let status: UInt8 = 0x3F // ?
    public static let feedHold: UInt8 = 0x21 // !
    public static let cycleStart: UInt8 = 0x7E // ~
    public static let softReset: UInt8 = 0x18
    public static let safetyDoor: UInt8 = 0x84
    public static let jogCancel: UInt8 = 0x85
    public static let feedOvReset: UInt8 = 0x90
    public static let feedOvPlus10: UInt8 = 0x91
    public static let feedOvMinus10: UInt8 = 0x92
    public static let feedOvPlus1: UInt8 = 0x93
    public static let feedOvMinus1: UInt8 = 0x94
    public static let rapidOv100: UInt8 = 0x95
    public static let rapidOv50: UInt8 = 0x96
    public static let rapidOv25: UInt8 = 0x97
    public static let spindleOvReset: UInt8 = 0x99
    public static let spindleOvPlus10: UInt8 = 0x9A
    public static let spindleOvMinus10: UInt8 = 0x9B
    public static let spindleOvPlus1: UInt8 = 0x9C
    public static let spindleOvMinus1: UInt8 = 0x9D
    public static let spindleStop: UInt8 = 0x9E
    public static let floodToggle: UInt8 = 0xA0
    public static let mistToggle: UInt8 = 0xA1
}

/// Bytes GRBL handles immediately instead of putting them in the line buffer.
public func isRealtimeByte(_ code: UInt8) -> Bool {
    code == 0x3F || code == 0x21 || code == 0x7E || code == 0x18 || code >= 0x80
}

public enum GrblState: String, Codable, Sendable, CaseIterable {
    case idle = "Idle", run = "Run", hold = "Hold", jog = "Jog", alarm = "Alarm", door = "Door"
    case check = "Check", home = "Home", sleep = "Sleep", unknown = "Unknown"
}

public struct Overrides: Codable, Equatable, Sendable {
    public var feed: Double
    public var rapid: Double
    public var spindle: Double
    public init(feed: Double = 100, rapid: Double = 100, spindle: Double = 100) {
        self.feed = feed
        self.rapid = rapid
        self.spindle = spindle
    }
}

public struct BufferState: Codable, Equatable, Sendable {
    /// Planner blocks available.
    public var planner: Int
    /// RX bytes available.
    public var rx: Int
    public init(planner: Int, rx: Int) {
        self.planner = planner
        self.rx = rx
    }
}

public struct StatusReport: Equatable, Sendable {
    public var state: GrblState
    public var subState: Int?
    public var mpos: Vec3?
    public var wpos: Vec3?
    public var wco: Vec3?
    public var feed: Double?
    public var spindle: Double?
    public var buffer: BufferState?
    public var overrides: Overrides?
    public var lineNumber: Int?
    public var pins: String?
    public var accessories: String?
    public init(state: GrblState) { self.state = state }
}

private func numbers(_ s: Substring) -> [Double] {
    s.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
}

private func vec(_ s: Substring) -> Vec3 {
    let p = numbers(s)
    return Vec3(p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 0, p.count > 2 ? p[2] : 0)
}

/// Parse `<Idle|MPos:0.000,0.000,0.000|FS:0,0|WCO:0,0,0>`. Returns nil if not a status report.
public func parseStatus(_ line: String) -> StatusReport? {
    guard line.hasPrefix("<"), line.hasSuffix(">"), line.count >= 2 else { return nil }
    let fields = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
    let head = fields[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var r = StatusReport(state: GrblState(rawValue: String(head[0])).flatMap { $0 == .unknown ? nil : $0 } ?? .unknown)
    if head.count > 1 { r.subState = Int(head[1]) ?? 0 }
    for f in fields.dropFirst() {
        guard let idx = f.firstIndex(of: ":") else { continue }
        let key = f[..<idx]
        let val = f[f.index(after: idx)...]
        switch key {
        case "MPos": r.mpos = vec(val)
        case "WPos": r.wpos = vec(val)
        case "WCO": r.wco = vec(val)
        case "FS":
            let v = numbers(val)
            r.feed = v.first
            r.spindle = v.count > 1 ? v[1] : nil
        case "F": r.feed = Double(val) ?? 0
        case "Bf":
            let v = numbers(val)
            r.buffer = BufferState(planner: Int(v.first ?? 0), rx: Int(v.count > 1 ? v[1] : 0))
        case "Ov":
            let v = numbers(val)
            if v.count >= 3 { r.overrides = Overrides(feed: v[0], rapid: v[1], spindle: v[2]) }
        case "Ln": r.lineNumber = Int(val)
        case "Pn": r.pins = String(val)
        case "A": r.accessories = String(val)
        default: break
        }
    }
    return r
}

public enum ResponseKind: String, Sendable {
    case ok, error, alarm, status, welcome, msg, feedback, setting, other
}

public struct Response: Equatable, Sendable {
    public var kind: ResponseKind
    public var raw: String
    public var code: Int?
    public var status: StatusReport?
}

public func classifyResponse(_ raw: String) -> Response {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if line == "ok" { return Response(kind: .ok, raw: line) }
    if line.hasPrefix("error:") { return Response(kind: .error, raw: line, code: Int(line.dropFirst(6)) ?? 0) }
    if line.hasPrefix("ALARM:") { return Response(kind: .alarm, raw: line, code: Int(line.dropFirst(6)) ?? 0) }
    if line.hasPrefix("<"), let status = parseStatus(line) { return Response(kind: .status, raw: line, status: status) }
    if isWelcome(line) { return Response(kind: .welcome, raw: line) }
    if line.hasPrefix("[MSG:") { return Response(kind: .msg, raw: line) }
    if line.hasPrefix("[") { return Response(kind: .feedback, raw: line) }
    if isSettingLine(line) { return Response(kind: .setting, raw: line) }
    return Response(kind: .other, raw: line)
}

/// `Grbl 1.1h ['$' for help]` or `GrblHAL ...`.
private func isWelcome(_ line: String) -> Bool {
    let lower = line.lowercased()
    for prefix in ["grblhal", "grbl"] where lower.hasPrefix(prefix) {
        let rest = lower.dropFirst(prefix.count)
        if let c = rest.first, c.isWhitespace { return true }
    }
    return false
}

/// `$110=5000.000`.
private func isSettingLine(_ line: String) -> Bool {
    guard line.hasPrefix("$") else { return false }
    let rest = line.dropFirst()
    let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
    return !digits.isEmpty && rest.dropFirst(digits.count).first == "="
}

public let grblErrors: [Int: String] = [
    1: "G-code words consist of a letter and a value. Letter was not found.",
    2: "Numeric value format is not valid or missing an expected value.",
    3: "Grbl '$' system command was not recognized or supported.",
    4: "Negative value received for an expected positive value.",
    5: "Homing cycle is not enabled via settings.",
    6: "Minimum step pulse time must be greater than 3usec.",
    7: "EEPROM read failed. Reset and restored to default values.",
    8: "Grbl '$' command cannot be used unless Grbl is IDLE.",
    9: "G-code locked out during alarm or jog state.",
    10: "Soft limits cannot be enabled without homing also enabled.",
    11: "Max characters per line exceeded. Line was not processed and executed.",
    12: "Grbl '$' setting value exceeds the maximum step rate supported.",
    13: "Safety door detected as opened and door state initiated.",
    14: "Build info or startup line exceeded EEPROM line length limit.",
    15: "Jog target exceeds machine travel. Command ignored.",
    16: "Jog command with no '=' or contains prohibited g-code.",
    17: "Laser mode requires PWM output.",
    20: "Unsupported or invalid g-code command found in block.",
    21: "More than one g-code command from same modal group found in block.",
    22: "Feed rate has not yet been set or is undefined.",
    23: "G-code command in block requires an integer value.",
    24: "Two G-code commands that both require the use of the XYZ axis words were detected in the block.",
    25: "A G-code word was repeated in the block.",
    26: "A G-code command implicitly or explicitly requires XYZ axis words in the block, but none were detected.",
    27: "N line number value is not within the valid range of 1 - 9,999,999.",
    28: "A G-code command was sent, but is missing some required P or L value words in the line.",
    29: "Grbl supports six work coordinate systems G54-G59. G59.1, G59.2, and G59.3 are not supported.",
    30: "The G53 G-code command requires either a G0 seek or G1 feed motion mode to be active.",
    31: "There are unused axis words in the block and G80 motion mode cancel is active.",
    32: "A G2 or G3 arc was commanded but there are no XYZ axis words in the selected plane to trace the arc.",
    33: "The motion command has an invalid target. G2, G3, and G38.2 generates this error.",
    34: "A G2 or G3 arc, traced with the radius definition, had a mathematical error when computing the arc geometry.",
    35: "A G2 or G3 arc, traced with the offset definition, is missing the IJK offset word in the selected plane.",
    36: "There are unused, leftover G-code words that aren't used by any command in the block.",
    37: "The G43.1 dynamic tool length offset command cannot apply an offset to an axis other than its configured axis.",
    38: "Tool number greater than max supported value.",
]

public let grblAlarms: [Int: String] = [
    1: "Hard limit triggered. Machine position is likely lost due to sudden and immediate halt. Re-homing is highly recommended.",
    2: "G-code motion target exceeds machine travel. Machine position safely retained. Alarm may be unlocked.",
    3: "Reset while in motion. Grbl cannot guarantee position. Lost steps are likely. Re-homing is highly recommended.",
    4: "Probe fail. The probe is not in the expected initial state before starting probe cycle.",
    5: "Probe fail. Probe did not contact the workpiece within the programmed travel.",
    6: "Homing fail. Reset during active homing cycle.",
    7: "Homing fail. Safety door was opened during active homing cycle.",
    8: "Homing fail. Cycle failed to clear limit switch when pulling off. Try increasing pull-off setting or check wiring.",
    9: "Homing fail. Could not find limit switch within search distance.",
    10: "Homing fail. On dual axis machines, could not find the second limit switch for self-squaring.",
]

public struct SettingInfo: Sendable {
    public var name: String
    public var unit: String?
}

public let grblSettings: [Int: SettingInfo] = [
    0: .init(name: "Step pulse time", unit: "µs"),
    1: .init(name: "Step idle delay", unit: "ms"),
    2: .init(name: "Step pulse invert", unit: "mask"),
    3: .init(name: "Step direction invert", unit: "mask"),
    4: .init(name: "Invert step enable pin", unit: "bool"),
    5: .init(name: "Invert limit pins", unit: "bool"),
    6: .init(name: "Invert probe pin", unit: "bool"),
    10: .init(name: "Status report options", unit: "mask"),
    11: .init(name: "Junction deviation", unit: "mm"),
    12: .init(name: "Arc tolerance", unit: "mm"),
    13: .init(name: "Report in inches", unit: "bool"),
    20: .init(name: "Soft limits enable", unit: "bool"),
    21: .init(name: "Hard limits enable", unit: "bool"),
    22: .init(name: "Homing cycle enable", unit: "bool"),
    23: .init(name: "Homing direction invert", unit: "mask"),
    24: .init(name: "Homing locate feed rate", unit: "mm/min"),
    25: .init(name: "Homing search seek rate", unit: "mm/min"),
    26: .init(name: "Homing switch debounce delay", unit: "ms"),
    27: .init(name: "Homing switch pull-off distance", unit: "mm"),
    30: .init(name: "Maximum spindle speed", unit: "RPM"),
    31: .init(name: "Minimum spindle speed", unit: "RPM"),
    32: .init(name: "Laser-mode enable", unit: "bool"),
    100: .init(name: "X-axis travel resolution", unit: "step/mm"),
    101: .init(name: "Y-axis travel resolution", unit: "step/mm"),
    102: .init(name: "Z-axis travel resolution", unit: "step/mm"),
    110: .init(name: "X-axis maximum rate", unit: "mm/min"),
    111: .init(name: "Y-axis maximum rate", unit: "mm/min"),
    112: .init(name: "Z-axis maximum rate", unit: "mm/min"),
    120: .init(name: "X-axis acceleration", unit: "mm/s²"),
    121: .init(name: "Y-axis acceleration", unit: "mm/s²"),
    122: .init(name: "Z-axis acceleration", unit: "mm/s²"),
    130: .init(name: "X-axis maximum travel", unit: "mm"),
    131: .init(name: "Y-axis maximum travel", unit: "mm"),
    132: .init(name: "Z-axis maximum travel", unit: "mm"),
]

public func describeError(_ code: Int) -> String { grblErrors[code] ?? "Unknown error \(code)" }
public func describeAlarm(_ code: Int) -> String { grblAlarms[code] ?? "Unknown alarm \(code)" }
