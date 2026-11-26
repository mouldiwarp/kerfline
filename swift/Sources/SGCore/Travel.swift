// Checking where a command would send the machine against its travel. With soft limits off
// ($20=0) GRBL happily drives past the end of travel into a limit switch, which stops it dead in
// ALARM with the position lost. These checks refuse such commands before they're sent.
// Port of packages/shared/src/travel.ts.

import Foundation

public struct DistanceModes: Equatable, Sendable, Codable {
    public var absolute: Bool
    public var inches: Bool
    public init(absolute: Bool = true, inches: Bool = false) {
        self.absolute = absolute
        self.inches = inches
    }
}

/// The distance modes in GRBL's `$G` report (`G0 G54 G17 G21 G90 G94 …`).
public func modesFromModal(_ modal: String?) -> DistanceModes {
    let gs = Set(parseWords(modal ?? "").filter { $0.letter == "G" }.map(\.value))
    return DistanceModes(absolute: !gs.contains(91), inches: gs.contains(20))
}

/// Upper-case, drop whitespace, `( … )` comments and everything after `;`.
private func stripForTarget(_ line: String) -> String {
    let chars = Array(line.uppercased().filter { !$0.isWhitespace })
    var out = ""
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == ";" { break }
        if c == "(", let close = chars[(i + 1)...].firstIndex(of: ")") {
            i = close + 1
            continue
        }
        out.append(c)
        i += 1
    }
    return out
}

public struct LineTarget: Equatable, Sendable {
    /// Machine-coordinate target per axis (nil for an axis the line doesn't move); nil if the
    /// line doesn't move to a stated position.
    public var target: [Double?]?
    /// The distance modes after the line.
    public var modes: DistanceModes
}

/// Where a command line sends the machine, in machine coordinates, and the distance modes after
/// it. `$J=` jogs don't change the modes. Lines that don't move to a stated position (settings,
/// G10/G92 offsets, G28/G30, dwells) have no target.
public func lineTarget(_ line: String, modes: DistanceModes, mpos: Vec3, wco: Vec3) -> LineTarget {
    var text = stripForTarget(line)
    let jog = text.hasPrefix("$J=")
    if jog { text.removeFirst(3) } else if text.hasPrefix("$") { return LineTarget(target: nil, modes: modes) }
    var m = modes
    var axis: [Double?] = [nil, nil, nil]
    var machine = false
    var skip = false
    for w in parseWords(text) {
        switch w.letter {
        case "G":
            let v = w.value
            if v == 90 { m.absolute = true }
            else if v == 91 { m.absolute = false }
            else if v == 20 { m.inches = true }
            else if v == 21 { m.inches = false }
            else if v == 53 { machine = true }
            else if [4, 10, 28, 30, 92, 28.1, 30.1, 92.1].contains(v) { skip = true }
        case "X": axis[0] = w.value
        case "Y": axis[1] = w.value
        case "Z": axis[2] = w.value
        default: break
        }
    }
    let after = jog ? modes : m
    if skip || axis.allSatisfy({ $0 == nil }) { return LineTarget(target: nil, modes: after) }
    let scale = m.inches ? 25.4 : 1
    let target: [Double?] = (0..<3).map { i in
        guard let v = axis[i] else { return nil }
        if !m.absolute && !machine { return mpos[i] + v * scale }
        return (machine ? 0 : wco[i]) + v * scale
    }
    return LineTarget(target: target, modes: after)
}

private let axisNames = ["X", "Y", "Z"]

/// What's wrong with a machine-coordinate target, or nil if it's within travel.
public func travelProblem(_ target: [Double?], _ env: Bounds) -> String? {
    var out: [String] = []
    for (i, t) in target.enumerated() {
        guard let t else { continue }
        let a = axisNames[i]
        if t > env.max[i] + 0.01 {
            out.append("\(fixed(t - env.max[i], 1)) mm past the \(i == 2 ? "top" : "end") of \(a)")
        } else if t < env.min[i] - 0.01 {
            out.append("\(fixed(env.min[i] - t, 1)) mm past the \(i == 2 ? "bottom" : "start") of \(a)")
        }
    }
    return out.isEmpty ? nil : out.joined(separator: " and ")
}
