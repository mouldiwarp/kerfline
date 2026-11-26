// Port of packages/shared/test/surfacing.test.ts.

import Foundation
import Testing
@testable import SGCore

@Suite struct SurfacingTests {
    var board: SurfacingParams {
        var p = SurfacingParams.defaults
        p.lengthX = 600
        p.widthY = 400
        return p
    }

    func with(_ change: (inout SurfacingParams) -> Void) -> SurfacingParams {
        var p = board
        change(&p)
        return p
    }

    @Test func coversTheWholeAreaAtDepthFromTheLeftEdgeAndCentredOnY0() throws {
        let plan = try planSurfacing(board)
        let a = analyzeProgram(plan.gcode)
        let r = board.toolDiameter / 2
        // Every point of the area (plus the overhang) is under the cutter at full depth somewhere.
        let atDepth = a.segments.filter { $0.type == .feed && abs($0.from[2] + 0.5) < 1e-6 && abs($0.to[2] + 0.5) < 1e-6 }
        func covered(_ x: Double, _ y: Double) -> Bool {
            atDepth.contains { s in
                let (ax, ay, bx, by) = (s.from[0], s.from[1], s.to[0], s.to[1])
                let dx = bx - ax
                let dy = by - ay
                let t = dx != 0 || dy != 0 ? max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy))) : 0
                return hypot(ax + t * dx - x, ay + t * dy - y) <= r + 1e-6
            }
        }
        var missed: [String] = []
        for x in stride(from: 0.0, through: 600, by: 5) {
            for y in stride(from: -200.0, through: 200, by: 5) where !covered(x, y) { missed.append("\(x),\(y)") }
        }
        #expect(missed.isEmpty, "not covered: \(missed.prefix(5))")
        for (x, y) in [(0.0, -200.0), (0, 200), (600, -200), (600, 200)] { #expect(covered(x, y), "corner \(x),\(y)") }
        // The cutter stays within the area plus the overhang.
        #expect(plan.overhang == 4)
        let cb = try #require(a.cutBounds)
        #expect(close(cb.min[0] - r, -4, 6))
        #expect(close(cb.max[0] + r, 604, 6))
        #expect(close(cb.min[1] - r, -204, 6))
        #expect(close(cb.max[1] + r, 204, 6))
        #expect(close(cb.min[2], -0.5, 6))
        #expect(plan.levels == 1)
        #expect(plan.stepover <= 12)
    }

    @Test func neverPlungesBelowTheSurface() throws {
        let cases = [board, with { $0.totalDepth = 2.5; $0.stepDown = 1 }, with { $0.lengthX = 40; $0.totalDepth = 1; $0.rampAngle = 1 }]
        for p in cases {
            let a = analyzeProgram(try planSurfacing(p).gcode)
            let tan = Foundation.tan(p.rampAngle * .pi / 180)
            var ramps = 0
            var floor = 0.0 // deepest Z already cut
            for s in a.segments {
                let drop = s.from[2] - s.to[2]
                if s.type == .rapid {
                    if drop > 0 { #expect(s.to[2] > floor) }
                    continue
                }
                // A feed move down into material that hasn't been cut yet must be a ramp.
                if drop > 1e-9 && s.to[2] < floor - 1e-9 {
                    ramps += 1
                    let run = hypot(s.to[0] - s.from[0], s.to[1] - s.from[1])
                    #expect(drop / run <= tan + 1e-6)
                }
                floor = min(floor, s.to[2])
            }
            #expect(ramps > 0)
            #expect(close(try #require(a.cutBounds).min[2], -p.totalDepth, 6))
        }
    }

    @Test func takesDeeperCutsInLevelsNoDeeperThanTheStepDown() throws {
        let plan = try planSurfacing(with { $0.totalDepth = 2.5; $0.stepDown = 1 })
        #expect(plan.levels == 3)
        #expect(plan.gcode.contains("(Level 3 of 3: Z-2.5)"))
    }

    @Test func startsTheSpindleAndEndsLiftedWithItOff() throws {
        let lines = try planSurfacing(board).gcode.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        #expect(lines.contains("M3 S18000"))
        #expect(Array(lines.suffix(4)) == ["G0 Z5", "M5", "G0 X0 Y0", "M30"])
    }

    @Test func raisesASmallOverhangSoTheCutterReachesTheCorners() throws {
        #expect(close(try planSurfacing(with { $0.overhang = 1 }).overhang, 3.6, 6))
        #expect(try planSurfacing(with { $0.overhang = 10 }).overhang == 10)
    }

    @Test func refusesTooDeepPassesAndAreasTooShortToRampIn() {
        let deep = checkSurfacing(with { $0.stepDown = 6 })
        #expect(deep.count == 1 && deep[0].contains("cutter's cutting depth") && deep[0].contains("(6 mm)"))
        #expect(checkSurfacing(with { $0.lengthX = 10 })[0].hasPrefix("Length (X) must be at least"))
        #expect(checkSurfacing(with { $0.lengthX = 0 })[0].contains("Length"))
        #expect(throws: SurfacingError.self) { try planSurfacing(with { $0.widthY = -1 }) }
        #expect((try? planSurfacing(with { $0.widthY = -1 })) == nil)
    }

    @Test func matchesThe1_0OutputExactly() throws {
        // Same G-code as 1.0 for the same board, so a file made by either is identical.
        let g = try planSurfacing(with { $0.lengthX = 100; $0.widthY = 50 }).gcode
        #expect(g.hasPrefix("(Spoilboard surfacing, made by SwarfGRBL)\n(Area: X0 to X100, Y-25 to Y25; Z0 is the surface)\n"))
        #expect(g.contains("G0 X8 Y-17\n"))
    }
}
