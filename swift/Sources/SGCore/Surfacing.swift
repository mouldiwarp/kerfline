// Spoilboard surfacing: a zigzag raster over a rectangle that starts at work X0 (the left edge of
// the board) and is centred on work Y0 (the board's centre line), taking the surface down from
// work Z0. The cutter never plunges: each depth level starts with a shallow ramp along the first
// line, then goes back over the ramp at full depth so no wedge is left behind.
// Port of packages/shared/src/surfacing.ts.

import Foundation

public struct SurfacingParams: Codable, Equatable, Sendable {
    /// Length to surface along X, from X0 (the left edge) to the right, mm.
    public var lengthX: Double
    /// Width to surface along Y, centred on Y0, mm.
    public var widthY: Double
    /// Material to remove below Z0, mm.
    public var totalDepth: Double
    /// Most to take in one pass, mm (no more than the cutter's cutting depth).
    public var stepDown: Double
    public var toolDiameter: Double
    /// Cutting depth of the cutter (flute length), mm.
    public var fluteLength: Double
    /// Distance between passes as a % of the diameter.
    public var stepoverPct: Double
    /// How far the cutter's edge goes past each edge of the area, mm. Raised if needed to
    /// r × (1 − 1/√2) (3.5 mm for a 24 mm cutter) so the round cutter reaches the corners.
    public var overhang: Double
    /// Ramp angle from horizontal, degrees.
    public var rampAngle: Double
    public var feed: Double
    public var rampFeed: Double
    public var spindleRpm: Double
    /// Height above Z0 for moves between levels, mm.
    public var safeZ: Double

    public static let defaults = SurfacingParams(
        lengthX: 0, widthY: 0, totalDepth: 0.5, stepDown: 1, toolDiameter: 24, fluteLength: 5, stepoverPct: 50,
        overhang: 4, rampAngle: 2, feed: 3000, rampFeed: 1000, spindleRpm: 18000, safeZ: 5)
}

public struct SurfacingPlan: Sendable {
    public var gcode: String
    /// Number of depth levels.
    public var levels: Int
    /// Raster lines per level.
    public var lines: Int
    /// Actual distance between lines, mm.
    public var stepover: Double
    /// Ramp length at the first level, mm.
    public var rampLength: Double
    /// Overhang used, mm (see effectiveOverhang).
    public var overhang: Double
    public var name: String
}

public struct SurfacingError: Error, CustomStringConvertible {
    public var problems: [String]
    public var description: String { problems.joined(separator: "; ") }
}

/// Problems that make the parameters unusable; empty when they're fine.
public func checkSurfacing(_ p: SurfacingParams) -> [String] {
    var errs: [String] = []
    func pos(_ v: Double, _ label: String) {
        if !(v.isFinite && v > 0) { errs.append("\(label) must be more than 0") }
    }
    pos(p.lengthX, "Length (X)")
    pos(p.widthY, "Width (Y)")
    pos(p.totalDepth, "Depth to remove")
    pos(p.stepDown, "Depth per pass")
    pos(p.toolDiameter, "Cutter diameter")
    pos(p.fluteLength, "Cutting depth")
    pos(p.feed, "Feed")
    pos(p.rampFeed, "Ramp feed")
    pos(p.spindleRpm, "Spindle speed")
    pos(p.safeZ, "Safe Z")
    if !(p.stepoverPct >= 5 && p.stepoverPct <= 95) { errs.append("Stepover must be between 5% and 95% of the diameter") }
    if !(p.rampAngle > 0 && p.rampAngle <= 45) { errs.append("Ramp angle must be between 0 and 45°") }
    if !(p.overhang >= 0) { errs.append("Overhang can't be negative") }
    if p.stepDown > p.fluteLength {
        errs.append("Depth per pass (\(jsNumber(p.stepDown)) mm) is more than the cutter's cutting depth (\(jsNumber(p.fluteLength)) mm)")
    }
    if p.totalDepth > 10 { errs.append("Depth to remove is over 10 mm: surfacing takes off a skim, not a pocket") }
    if !errs.isEmpty { return errs }
    let r = p.toolDiameter / 2
    let m = effectiveOverhang(p)
    if p.lengthX - 2 * r + 2 * m < 1 {
        errs.append("Length (X) must be at least \(fixed(2 * r - 2 * m + 1, 1)) mm to ramp in along it")
    }
    return errs
}

/// The overhang actually used: at least enough for the cutter to reach the area's corners.
public func effectiveOverhang(_ p: SurfacingParams) -> Double {
    let r = p.toolDiameter / 2
    return max(p.overhang, (r * (1 - 0.5.squareRoot()) * 10 + 0.5).rounded(.up) / 10)
}

public func planSurfacing(_ p: SurfacingParams) throws -> SurfacingPlan {
    let errs = checkSurfacing(p)
    if !errs.isEmpty { throw SurfacingError(problems: errs) }
    let f = gnum

    let r = p.toolDiameter / 2
    let m = effectiveOverhang(p)
    let x0 = r - m
    let x1 = p.lengthX - r + m
    let lineLen = x1 - x0

    let yHalf = p.widthY / 2 - r + m
    let maxStep = p.toolDiameter * p.stepoverPct / 100
    var ys: [Double] = []
    var stepover = 0.0
    if yHalf <= 0 {
        ys.append(0)
    } else {
        let n = Int((2 * yHalf / maxStep).rounded(.up)) + 1
        stepover = 2 * yHalf / Double(n - 1)
        for i in 0..<n { ys.append(-yHalf + Double(i) * stepover) }
    }

    let levels = Int((p.totalDepth / p.stepDown - 1e-9).rounded(.up))
    let tan = Foundation.tan(p.rampAngle * .pi / 180)
    var out: [String] = []
    let name = "Surface \(f(p.lengthX))x\(f(p.widthY)) -\(f(p.totalDepth))mm.nc"
    let rpm = Int(p.spindleRpm.rounded())

    out += [
        "(Spoilboard surfacing, made by SwarfGRBL)",
        "(Area: X0 to X\(f(p.lengthX)), Y\(f(-p.widthY / 2)) to Y\(f(p.widthY / 2)); Z0 is the surface)",
        "(Removes \(f(p.totalDepth)) mm in \(levels) level\(levels > 1 ? "s" : ""); \(ys.count) lines per level)",
        "(Cutter \(f(p.toolDiameter)) mm, stepover \(f(stepover == 0 ? maxStep : stepover)) mm, ramp \(f(p.rampAngle)) deg, runs \(f(m)) mm past the edges)",
        "G21 G90 G17 G94",
        "G0 Z\(f(p.safeZ))",
        "M3 S\(rpm)",
        "G4 P4",
    ]

    var rampLength = 0.0
    let r3 = { (n: Double) in (n * 1000).rounded() / 1000 }
    for level in 1...max(levels, 1) {
        let top = level == 1 ? 0 : -min(Double(level - 1) * p.stepDown, p.totalDepth)
        let z = -min(Double(level) * p.stepDown, p.totalDepth)
        out += ["(Level \(level) of \(levels): Z\(f(z)))", "G0 Z\(f(p.safeZ))", "G0 X\(f(x0)) Y\(f(ys[0]))", "G0 Z\(f(top + 1))"]
        out.append("G1 Z\(f(top)) F\(Int(p.rampFeed.rounded()))")

        // Ramp down along the first line, back and forth if the line is shorter than the ramp.
        let need = (top - z) / tan
        if level == 1 { rampLength = need }
        // Coordinates are written to 0.001 mm, so round X first and round Z up (shallower):
        // the ramp is then never steeper than the angle asked for.
        var x = x0
        var zNow = top
        var dir = 1.0
        while zNow > z + 1e-9 {
            let run = min(lineLen, (zNow - z) / tan)
            let nx = r3(x + dir * run)
            let nz = ((zNow - abs(nx - x) * tan) * 1000 - 1e-6).rounded(.up) / 1000
            x = nx
            zNow = max(z, nz)
            out.append("G1 X\(f(x)) Z\(f(zNow))")
            dir = -dir
        }
        // Back over the ramp at full depth to the start of the line.
        if abs(x - x0) > 1e-9 { out.append("G1 X\(f(x0)) F\(Int(p.feed.rounded()))") } else { out.append("F\(Int(p.feed.rounded()))") }

        // Zigzag raster, front to back.
        x = x0
        for (i, y) in ys.enumerated() {
            if i > 0 { out.append("G1 Y\(f(y))") }
            x = x == x0 ? x1 : x0
            out.append("G1 X\(f(x))")
        }
    }

    out += ["G0 Z\(f(p.safeZ))", "M5", "G0 X0 Y0", "M30"]
    return SurfacingPlan(
        gcode: out.joined(separator: "\n") + "\n", levels: levels, lines: ys.count, stepover: stepover == 0 ? maxStep : stepover,
        rampLength: rampLength, overhang: m, name: name)
}
