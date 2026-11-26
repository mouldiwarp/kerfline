// Programs that cut with the spindle off: GRBL runs them, driving a still cutter into the work.

import Foundation
import SGCore
import Testing

@Suite struct SpindleCheckTests {
    /// 0-based line of the first spindle-off cut.
    func first(_ lines: [String], from: Int = 0) -> Int? { spindleOffCut(lines.joined(separator: "\n"), from: from) }

    @Test func aProgramThatNeverStartsTheSpindle() {
        // Fretboard Modeller's output with a manual spindle: straight from the preamble into the cut.
        let p = ["(header)", "G21", "G90", "G17", "G94", "G54", "G0 Z14", "G0 X0 Y0", "G1 Z-1 F300", "G1 X50 F1000", "M2"]
        #expect(first(p) == 8)
        #expect(analyzeProgram(p.joined(separator: "\n")).spindleOffCut == 8)
        #expect(analyzeProgram(p.joined(separator: "\n")).usesSpindle == false)
    }

    @Test func aStartedSpindleIsFine() {
        #expect(first(["G21 G90", "M3 S18000", "G4 P5", "G0 Z5", "G1 Z-1 F300", "G1 X10", "M5", "M2"]) == nil)
        // The spindle starts in the same block as the first cut: GRBL turns it on before the motion.
        #expect(first(["G21", "G1 Z-1 F300 M3 S12000", "G1 X10"]) == nil)
        #expect(first(["M4 S9000", "G1 X10 F500"]) == nil)
        // Rapids with the spindle off are normal.
        #expect(first(["G0 Z5", "G0 X10 Y10", "M3 S10000", "G1 Z-1 F300"]) == nil)
    }

    @Test func noSpeedOrAStopCounts() {
        #expect(first(["M3", "G1 X10 F500"]) == 1)                         // no S word: 0 rpm
        #expect(first(["M3 S10000", "G1 X10 F500", "S0", "G1 X20"]) == 3)
        #expect(first(["M3 S10000", "G1 X10 F500", "M5", "G1 X20"]) == 3)
        #expect(first(["M3 S10000", "G1 X10 F500", "M2", "G1 X20"]) == 3)  // program end stops it
        #expect(first(["G2 X10 Y0 I5 J0 F500"]) == 0)                      // arcs too
    }

    @Test func probingAndOffsetsAreNotCutting() {
        #expect(first(["G21", "G38.2 Z-20 F100", "G10 L20 P1 Z0", "G0 Z5"]) == nil)
        #expect(first(["G1 F300", "G38.2 Z-20 F100", "Z-25", "G1 X5"]) == 3)   // G38.2 stays the motion mode
        #expect(first(["G1 F500", "G92 X0 Y0", "G28 Z5"]) == nil)
        #expect(first(["G53 G1 Z-5 F500"]) == 0)
    }

    /// A cut before the program has set every axis still cuts (the interpreter draws nothing until then).
    @Test func cutsBeforeEveryAxisIsKnown() {
        #expect(first(["G21", "G1 Z-2 F300", "G1 X40"]) == 1)
        #expect(first(["G1 F300", "X10", "G0 Z5"]) == 1)          // modal G1
        #expect(first(["G2 I5 J0 F500"]) == 0)                    // a full circle has no axis words
        #expect(first(["G80", "X10"]) == nil)
    }

    /// Resuming: only cuts from the resume line on matter, with the spindle as the program left it there.
    @Test func fromALine() {
        let p = ["G1 X1 F500", "M3 S10000", "G1 X2", "M5", "G0 Z5", "M3 S10000", "G1 X3"]
        #expect(first(p) == 0)
        #expect(first(p, from: 1) == nil)
        #expect(spindleOffCuts(p.joined(separator: "\n")) == [0])
    }

    @Test func theStartCommandCarriesTheConfirmation() throws {
        let c = Command.start(fileId: "f", group: nil, fromLine: nil, spindleOff: true)
        let back = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        // From a Mac that predates it: not confirmed.
        let old = try JSONDecoder().decode(Command.self, from: Data(#"{"type":"start","fileId":"f"}"#.utf8))
        #expect(old == .start(fileId: "f", group: nil, fromLine: nil, spindleOff: nil))
    }
}
