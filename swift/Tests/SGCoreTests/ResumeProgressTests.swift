// Port of packages/shared/test/resume.test.ts and progress.test.ts.

import Foundation
import Testing
@testable import SGCore

@Suite struct ResumeTests {
    let program = [
        "(test)", "G21 G90 G17 G94", "G0 Z5", "M3 S12000", "G4 P2", "G0 X10 Y10", "G1 Z-1 F300", "G1 X50 F1000", "G1 Y40", "G20",
        "G1 X1", "M5",
    ].joined(separator: "\n")

    func index(_ text: String) -> Int { streamableLines(program).firstIndex { $0.text == text }! }

    @Test func knowsTheModesAndThePositionBeforeALine() {
        let st = stateAt(program, index("G1Y40"))
        #expect(!st.inches && st.absolute && st.plane == 17 && st.motion == 1 && st.feed == 1000)
        #expect(st.spindle == "M3" && st.speed == 12000 && st.pos == [50, 10, -1])
        let later = stateAt(program, index("G1X1"))
        #expect(later.inches && later.pos == [50, 40, -1])
    }

    /// Homed, at work Z 0, with the top of travel at work Z 60.
    let homed = ResumeOptions(topZ: 60, currentZ: 0, spinup: 4, plungeFeed: 300)

    @Test func liftsSpinsUpMovesXThenYThenLowers() throws {
        let plan = try planResume(program, index("G1Y40"), homed)
        #expect(plan.preamble == [
            "G21G90G17G94G54", "G0Z60", "M3S12000", "G4P4", "G0X50", "G0Y10", "G0Z5", "G1Z-1F300", "G21G90G1F1000",
        ])
        #expect(plan.start == Vec3(50, 10, -1))
        #expect(plan.travelZ == 60 && plan.clearZ == 5)
    }

    @Test func restoresInchesAfterMovingInMm() throws {
        var o = homed
        o.spinup = 0
        let plan = try planResume(program, index("G1X1"), o)
        #expect(plan.preamble.last == "G20G90G1F1000")
        #expect(plan.preamble.contains("G0X50") && plan.preamble.contains("G0Y40"))
    }

    /// The fretboard: Z zero under the board, cutting at about Z 7 and travelling at Z 14. Resuming used to "lift" to
    /// the larger of safe Z (5) and the cut's own Z, so it crossed the work at cutting depth.
    let board = ["G21", "G90", "G54", "M3 S18000", "G4 P5", "G0 Z14", "G0 X-9.25 Y-38.395", "G0 Z10", "G1 Z7 F1000",
                 "G1 Y-24.433 F2500", "G1 Y-21.441 Z7.192", "G1 Y-18.449 Z7.358", "G1 Y-15.458 Z7.495"].joined(separator: "\n")

    @Test func neverCrossesTheWorkAtCuttingDepth() throws {
        let at = streamableLines(board).firstIndex { $0.text == "G1Y-15.458Z7.495" }!
        let plan = try planResume(board, at, ResumeOptions(topZ: 64.3, currentZ: 6.9, spinup: 4, plungeFeed: 300))
        #expect(plan.preamble == [
            "G21G90G17G94G54", "G0Z64.3", "M3S18000", "G4P4", "G0X-9.25", "G0Y-18.449", "G0Z14", "G1Z7.358F300", "G21G90G1F2500",
        ])
        // Not homed: the program's own travel height, not safe Z.
        let unhomed = try planResume(board, at, ResumeOptions(topZ: nil, currentZ: 6.9, safeZ: 5, spinup: 4, plungeFeed: 300))
        #expect(unhomed.travelZ == 14)
        #expect(Array(unhomed.preamble[1...]).prefix(1) == ["G0Z14"])
    }

    @Test func neverMovesDownToTravel() throws {
        let plan = try planResume(program, index("G1Y40"), ResumeOptions(topZ: nil, currentZ: 30, spinup: 0, plungeFeed: 300))
        #expect(plan.travelZ == 30)
        #expect(plan.preamble[1] == "G0Z30")
    }

    /// Every move that goes down comes after every move across, and the spindle is on before any of them.
    @Test(arguments: [true, false]) func theOrderIsSafe(isHomed: Bool) throws {
        let o = isHomed ? homed : ResumeOptions(topZ: nil, currentZ: 0, spinup: 4, plungeFeed: 300)
        let pre = try planResume(program, index("G1Y40"), o).preamble
        let lift = pre.firstIndex { $0.hasPrefix("G0Z") }!, spin = pre.firstIndex { $0.hasPrefix("M3") }!
        let x = pre.firstIndex { $0.hasPrefix("G0X") }!, y = pre.firstIndex { $0.hasPrefix("G0Y") }!
        let down = pre.lastIndex { $0.hasPrefix("G1Z") }!
        #expect(lift < spin && spin < x && x < y && y < down)
    }

    /// GRBL refuses G1 with no feed set (after a reset, say), so the feed goes on the same line as the modes.
    @Test func theFeedComesWithTheMotionMode() throws {
        let p = ["G21 G90", "G0 X0 Y0 Z5", "M3 S10000", "G1 F800", "G1 X10", "G1 X20"].joined(separator: "\n")
        let plan = try planResume(p, 5, ResumeOptions(topZ: 5, currentZ: 5, spinup: 0, plungeFeed: 300))
        #expect(plan.preamble.last == "G21G90G1F800")
        #expect(!plan.preamble.contains { $0.hasPrefix("G1Z") })
    }

    @Test func aStartGoesOverTheFirstPointBeforeAnythingGoesDown() {
        #expect(planStart(board, ResumeOptions(topZ: 64.3, currentZ: 64.3, spinup: 4, plungeFeed: 300))
            == ["G21G90G94G54", "G0Z64.3", "G0X-9.25", "G0Y-38.395"])
        // Not homed: up to the program's highest Z.
        #expect(planStart(board, ResumeOptions(topZ: nil, currentZ: 2, spinup: 4, plungeFeed: 300))[1] == "G0Z14")
        // A program that never says where X and Y are gets nothing added.
        #expect(planStart("G21\nG0 Z5\nG1 Z-1 F100", homed).isEmpty)
    }

    @Test func refusesALineBeforeTheProgramHasSaidWhereTheToolIs() {
        #expect {
            try planResume(program, index("G0Z5"), homed)
        } throws: { ($0 as? ResumeError)?.description.contains("isn't known") == true }
    }

    @Test func tellsMovesFromOtherLines() {
        #expect(isMotionLine("G1X5"))
        #expect(isMotionLine("X5Y2"))
        #expect(!isMotionLine("G4P2"))
        #expect(!isMotionLine("G04P2"))
        #expect(!isMotionLine("G10L20P0X0"))
        #expect(!isMotionLine("G92X0"))
        #expect(!isMotionLine("M3S1000"))
        #expect(isMotionLine("G43Z5"))
        #expect(isMotionLine("G40G1X5"))
    }

    @Test func showsTheSourceLineOfAResumePoint() {
        #expect(sourceLineText(program, index("G1Y40")) == StreamLine(text: "G1 Y40", source: 8))
        #expect(sourceLineText(program, 999) == nil)
    }
}

@Suite struct ProgressTests {
    let text = ["(t)", "G21 G90", "G0 X0 Y0 Z0", "G1 X100 F600", "G4 P2", "G1 Y60 F1200"].joined(separator: "\n")

    @Test func timesEachLineByDistanceAndFeedAndDwellsByLength() {
        let m = progressModel(text, options: .init(rapidRate: 5000))
        #expect(m.dur == [0, 0, 10, 2, 3])
        #expect(m.start == [0, 0, 0, 10, 12])
        #expect(m.total == 15)
    }

    @Test func countsHowFarAlongTheCurrentLineTheToolIs() {
        let m = progressModel(text, options: .init(rapidRate: 5000))
        #expect(close(secondsDone(m, 2, Vec3(25, 0, 0)), 2.5))
        #expect(close(secondsDone(m, 2, Vec3(100, 0, 0)), 10))
        #expect(close(secondsDone(m, 4, Vec3(100, 30, 0)), 13.5))
        #expect(secondsDone(m, 3, Vec3(100, 0, 0)) == 10) // dwelling: no position to go by
        #expect(secondsDone(m, 5) == 15)
    }

    @Test func timesTheOpeningRapidFromAKnownPosition() {
        let m = progressModel("G0 X50", options: .init(rapidRate: 6000), from: Vec3(0, 0, 0))
        #expect(close(m.total, 0.5))
    }

    @Test func findsTheLineTheToolIsOn() {
        let zz = ["G21 G90", "G0 X0 Y0 Z0", "G0 X0 Y0", "G1 X100 F600", "G1 Y10", "G1 X0"].joined(separator: "\n")
        let m = progressModel(zz, options: .init(rapidRate: 5000))
        #expect(lineAtPosition(m, 1, 5, Vec3(40, 0, 0)) == 3)
        #expect(lineAtPosition(m, 1, 5, Vec3(100, 4, 0)) == 4)
        #expect(lineAtPosition(m, 4, 5, Vec3(60, 10, 0)) == 5)
        #expect(lineAtPosition(m, 1, 2, Vec3(40, 0, 0)) == 1) // never past what GRBL has taken
        #expect(lineAtPosition(m, 3, 5, Vec3(55, 3, 0)) == 3) // off every path: the lower bound
    }
}
