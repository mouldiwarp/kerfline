// Port of packages/shared/test/gcode.test.ts and grbl.test.ts.

import Foundation
import Testing
@testable import SGCore

/// Vitest's toBeCloseTo: |a - b| < 10^-digits / 2.
func close(_ a: Double, _ b: Double, _ digits: Int = 2) -> Bool {
    abs(a - b) < pow(10, Double(-digits)) / 2
}

func close(_ a: Vec3, _ b: Vec3, _ digits: Int = 2) -> Bool {
    (0..<3).allSatisfy { close(a[$0], b[$0], digits) }
}

@Suite struct CleanLineTests {
    @Test func stripsCommentsAndWhitespaceAndUpperCases() {
        #expect(cleanLine("g1 x10 (cut) y5 ; trailing") == "G1X10Y5")
        #expect(cleanLine("(header only)") == "")
        #expect(cleanLine("%") == "")
        #expect(cleanLine("  ") == "")
    }

    @Test func parsesWordsLikeTheRegex() {
        #expect(parseWords("G1X10.Y-.5Z+3F") == [Word("G", 1), Word("X", 10), Word("Y", -0.5), Word("Z", 3)])
        #expect(parseWords("$J=G91X-1") == [Word("G", 91), Word("X", -1)])
    }
}

@Suite struct InterpreterTests {
    @Test func drawsNothingUntilTheStartPositionIsKnown() {
        let it = Interpreter()
        #expect(it.step("G0Z5").isEmpty)
        #expect(it.step("G0X1Y2").isEmpty)
        let s = it.step("G0X3")[0]
        #expect(s.type == .rapid && s.from == Vec3(1, 2, 5) && s.to == Vec3(3, 2, 5))
    }

    @Test func tracksModalMotionAbsoluteAndIncrementalMoves() {
        let it = Interpreter()
        it.setPosition(.zero)
        #expect(it.step("G0X10Y10")[0].to == Vec3(10, 10, 0))
        let plunge = it.step("G1Z-2F300")[0]
        #expect(plunge.type == .feed && plunge.to == Vec3(10, 10, -2) && plunge.feed == 300)
        #expect(it.step("X20")[0].to == Vec3(20, 10, -2))
        _ = it.step("G91")
        #expect(it.step("X5Y-5")[0].to == Vec3(25, 5, -2))
    }

    @Test func convertsInches() {
        let it = Interpreter()
        it.setPosition(.zero)
        _ = it.step("G20")
        let s = it.step("G1X1F10")[0]
        #expect(close(s.to, Vec3(25.4, 0, 0), 9) && close(s.feed, 254, 9))
    }

    @Test func doesNotTreatG10G92G28AxisWordsAsMotion() {
        let it = Interpreter()
        #expect(it.step("G10L20P0X0Y0").isEmpty)
        #expect(it.step("G92X0").isEmpty)
        #expect(it.step("G28X0Y0").isEmpty)
        #expect(it.pos == .zero)
    }

    @Test func linearisesAFullIJKCircleThatReturnsToItsStart() {
        let it = Interpreter(.init(arcTolerance: 0.01))
        it.setPosition(.zero)
        _ = it.step("G0X10Y0")
        let segs = it.step("G2X10Y0I-10J0F500")
        #expect(segs.count > 20)
        let last = segs.last!.to
        #expect(close(last[0], 10) && close(last[1], 0))
        // Every point sits on the radius-10 circle centred at the origin.
        for s in segs { #expect(close(hypot(s.to[0], s.to[1]), 10, 5)) }
        // Clockwise from +X goes through -Y first.
        #expect(segs[1].to[1] < 0)
    }

    @Test func computesRFormArcCentresLikeGrbl() {
        let it = Interpreter()
        it.setPosition(.zero)
        _ = it.step("G0X10Y0")
        // Quarter circle CCW from (10,0) to (0,10), radius 10 about the origin.
        let segs = it.step("G3X0Y10R10F100")
        #expect(!segs.isEmpty)
        for s in segs { #expect(close(hypot(s.to[0], s.to[1]), 10, 5)) }
    }
}

@Suite struct AnalyzeProgramTests {
    let square = ["G21 G90", "G0 Z5", "G0 X0 Y0", "G1 Z-1 F100", "G1 X100 F1000", "Y50", "X0", "Y0", "G0 Z5", "M30"].joined(separator: "\n")

    @Test func reportsBoundsDistancesAndTime() {
        let a = analyzeProgram(square)
        // The plunge from Z5 to Z-1 is a feed move, so it counts as cutting.
        #expect(a.cutBounds == Bounds(min: Vec3(0, 0, -1), max: Vec3(100, 50, 5)))
        #expect(close(a.feedDistance, 306))
        // 300 mm at 1000 mm/min = 18 s, plus 6 mm at 100 mm/min = 3.6 s, plus a little rapid time.
        #expect(a.estSeconds > 21.6 && a.estSeconds < 22)
        #expect(a.streamLines == 10)
        #expect(!a.usesSpindle)
        #expect(analyzeProgram("G0X0Y0Z0\nM03 S1000").usesSpindle)
        #expect(!analyzeProgram("M30").usesSpindle)
    }

    @Test func mapsStreamLinesToSourceLines() {
        #expect(streamableLines("(comment)\nG0X1\n\nG1X2F10\n") == [StreamLine(text: "G0X1", source: 1), StreamLine(text: "G1X2F10", source: 3)])
        #expect(splitLines("a\r\nb\rc\nd") == ["a", "b", "c", "d"])
    }
}

@Suite struct GrblTests {
    @Test func parsesAFullStatusReport() throws {
        let s = try #require(parseStatus("<Hold:0|MPos:-10.000,-20.500,-3.000|Bf:15,128|FS:1200,18000|WCO:-100.000,-200.000,-50.000|Pn:XZ>"))
        var want = StatusReport(state: .hold)
        want.subState = 0
        want.mpos = Vec3(-10, -20.5, -3)
        want.buffer = BufferState(planner: 15, rx: 128)
        want.feed = 1200
        want.spindle = 18000
        want.wco = Vec3(-100, -200, -50)
        want.pins = "XZ"
        #expect(s == want)
    }

    @Test func parsesOverridesAndWPos() throws {
        let s = try #require(parseStatus("<Idle|WPos:1.000,2.000,3.000|FS:0,0|Ov:120,50,90>"))
        #expect(s.state == .idle && s.wpos == Vec3(1, 2, 3) && s.overrides == Overrides(feed: 120, rapid: 50, spindle: 90))
        #expect(parseStatus("<Run|MPos:0,0,0|A:S>")?.accessories == "S")
        #expect(parseStatus("<Weird|MPos:0,0,0>")?.state == .unknown)
    }

    @Test func rejectsNonStatusLines() {
        #expect(parseStatus("ok") == nil)
    }

    @Test func classifiesEveryResponseKind() {
        #expect(classifyResponse("ok").kind == .ok)
        #expect(classifyResponse("error:22").kind == .error && classifyResponse("error:22").code == 22)
        #expect(classifyResponse("ALARM:2").kind == .alarm && classifyResponse("ALARM:2").code == 2)
        #expect(classifyResponse("Grbl 1.1h ['$' for help]").kind == .welcome)
        #expect(classifyResponse("GrblHAL 1.1f ['$' or '$HELP' for help]").kind == .welcome)
        #expect(classifyResponse("[MSG:Caution: Unlocked]").kind == .msg)
        #expect(classifyResponse("[GC:G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0]").kind == .feedback)
        #expect(classifyResponse("$110=5000.000").kind == .setting)
        #expect(classifyResponse("$J=G91X1").kind == .other)
        #expect(classifyResponse("ok\r\n").kind == .ok)
    }

    @Test func realtimeBytes() {
        #expect(isRealtimeByte(RT.status) && isRealtimeByte(RT.feedHold) && isRealtimeByte(RT.spindleStop))
        #expect(!isRealtimeByte(UInt8(ascii: "G")))
        #expect(describeAlarm(3).hasPrefix("Reset while in motion"))
        #expect(describeError(99) == "Unknown error 99")
    }
}
