import Foundation
import Testing
@testable import SGCore

/// Where Z zero is taken, read from the header of the files Fretboard Modeller and Swarf write.
@Suite struct ZZeroTests {
    @Test func fretboardHeaders() {
        #expect(zZeroReference("""
            ; Fretboard Modeller
            ; Work origin: X0 Y0 at the nut end, centre line. Z0 = TOP of stock
            G21 G90
            G0 Z5
            """) == .materialTop)
        #expect(zZeroReference("""
            ; Work origin: X0 Y0 at the nut end. Z0 = SPOILBOARD surface (bottom of the stock)
            G21 G90
            """) == .spoilboard)
        #expect(zZeroReference("(Inlay pockets)\n(Z0 = BOARD SURFACE at that point)\nG21\n") == .materialTop)
    }

    @Test func swarfHeaders() {
        #expect(zZeroReference("(Swarf: neck)\n(Z0 = TOP of stock: touch off Z on the material surface)\nG21\n") == .materialTop)
        #expect(zZeroReference("(Z0 = SPOILBOARD surface, the bottom of the stock: touch off Z on the spoilboard)\nG21\n") == .spoilboard)
        #expect(zZeroReference("; Z0 = TOP of the test board: touch off Z on the material surface\n") == .materialTop)
        // Older Swarf files give the work zero in stock space, where Z 0 is the bottom of the stock.
        #expect(zZeroReference("(Work zero [stock space]: X0.00 Y0.00 Z0.00)\nG21\n") == .spoilboard)
        #expect(zZeroReference("(Work zero [stock space]: X0.00 Y0.00 Z25.40)\nG21\n") == .materialTop)
        // Saying it in words wins over the coordinates.
        #expect(zZeroReference("(Work zero [stock space]: X0 Y0 Z0.00)\n(Zero Z on the top of the test board)\n") == .materialTop)
    }

    /// Only comments count, and only near the top; files that don't say get nil.
    @Test func onlyHeaderComments() {
        #expect(zZeroReference("G21\nG0 Z5\nG1 X10 F500\n") == nil)
        #expect(zZeroReference("G0 Z0 ; top\n") == nil)
        let late = String(repeating: "G1 X1\n", count: 100) + "; Z0 = SPOILBOARD\n"
        #expect(zZeroReference(late) == nil)
    }

    @Test func analysisCarriesIt() {
        let a = analyzeProgram("; Z0 = SPOILBOARD surface\nG21 G90\nM3 S10000\nG1 X10 Z-1 F500\n")
        #expect(a.zZero == .spoilboard)
    }
}
