// Port of packages/agent/test/controller.test.ts: MachineSession against the simulator.

import Foundation
import GCCCore
import Testing
@testable import GCCMachine

/// A pocket-like program: many short moves plus arcs, comments and blank lines.
func program() -> String {
    var out = ["(test pocket)", "G21 G90", "M3 S12000", "G0 Z5", "G0 X0 Y0", "G1 Z-1 F300"]
    for i in 0..<60 {
        out.append("G1 X\((i % 2) * 40) Y\(jsNumber(Double(i) * 0.5)) F2400 ; pass \(i)")
        if i % 10 == 0 { out += ["", "G2 X\((i % 2) * 40) Y\(jsNumber(Double(i) * 0.5 + 0.5)) I0 J0.25"] }
    }
    out += ["G0 Z5", "M5", "M30"]
    return out.joined(separator: "\n")
}

@Suite(.serialized) struct MachineSessionTests {
    @Test func streamsAWholeJobWithoutOverflowingTheRxBuffer() async throws {
        let r = try await Rig.make()
        let text = program()
        try await r.start(text, by: "test")
        try await until(15000, "done") { await r.job.status == .done }
        #expect(!r.sim.overflowed)
        let sent = text.split(separator: "\n", omittingEmptySubsequences: false).map { cleanLine(String($0)) }.filter { !$0.isEmpty }
        let all = r.sim.received
        let received = Array(all[(all.firstIndex(of: sent[0]) ?? 0)...])
        #expect(received == sent)
        let job = await r.job
        #expect(job.ackedLines == job.totalLines)
        #expect(await r.machine.firmware?.contains("1.1h") == true)
        await r.done()
    }

    @Test func refusesJogAndMdiWhileAJobRunsButAlwaysAcceptsHold() async throws {
        let r = try await Rig.make(Rig.sim(speed: 5))
        try await r.start(program())
        await expectThrows("job is running") { try await r.command(.jog(x: 1, y: nil, z: nil, feed: 1000)) }
        await expectThrows("job is running") { try await r.command(.mdi(line: "G0X0")) }
        try await r.command(.hold, by: "garage")
        #expect(await r.job.status == .paused)
        try await until { await r.machine.status == .hold }
        try await r.command(.resume, by: "studio")
        #expect(await r.job.status == .running)
        #expect(await r.machine.lastCommandBy == "studio")
        await r.done()
    }

    @Test func stopsAJobWithHoldThenResetWithoutAnAlarm() async throws {
        let r = try await Rig.make(Rig.sim(speed: 2))
        try await r.start(program())
        try await until { await r.machine.status == .run }
        try await r.command(.stop)
        try await until { await r.job.status == .stopped }
        try await until { await r.idle() }
        #expect(await r.machine.alarm == nil)
        await r.done()
    }

    @Test func pausesOnAGcodeErrorAndCanResume() async throws {
        let r = try await Rig.make()
        try await r.start("G21\nG0X1\nG1X5\nG0X0\n", "bad.nc")
        try await until { await r.job.status == .paused }
        #expect(await r.job.error?.contains("error:22") == true)
        try await r.command(.resume)
        try await until { await r.job.status == .done }
        await r.done()
    }

    @Test func failsTheJobOnAnAlarm() async throws {
        let r = try await Rig.make(Rig.sim(speed: 1))
        try await r.start(program())
        try await until { await r.machine.status == .run }
        r.sim.injectAlarm(1)
        try await until { await r.job.status == .error }
        #expect(await r.machine.alarm?.code == 1)
        await r.done()
    }

    @Test func setsWorkZeroAndJogs() async throws {
        let r = try await Rig.make()
        try await r.command(.jog(x: -10, y: -5, z: -20, feed: 3000))
        try await until { let m = await r.machine; return m.mpos[0] == -10 && m.status == .idle }
        try await r.command(.zero(axes: [.X, .Y, .Z]))
        try await until { let m = await r.machine; return m.wpos[0] == 0 && m.wco[0] == -10 }
        try await r.command(.jog(x: 3, y: nil, z: nil, feed: 3000))
        try await until { let m = await r.machine; return abs(m.wpos[0] - 3) < 1e-6 && m.status == .idle }
        try await r.command(.goToZero(axes: [.X, .Y]))
        try await until { let m = await r.machine; return abs(m.wpos[0]) < 1e-6 && m.status == .idle }
        #expect(close(await r.machine.wpos[2], 5))
        await r.done()
    }

    @Test func neverLiftsPastTheTopOfZWhenWorkZZeroIsNearTheTop() async throws {
        let r = try await Rig.make(config: .defaults)
        try await r.command(.jog(x: -10, y: -5, z: -0.5, feed: 3000))
        try await until { let m = await r.machine; return m.mpos[0] == -10 && m.status == .idle }
        try await r.command(.zero(axes: [.X, .Y, .Z])) // Z zero 0.5 mm below the top
        try await r.command(.jog(x: 20, y: nil, z: -30, feed: 3000))
        try await until { let m = await r.machine; return abs(m.wpos[0] - 20) < 1e-6 && m.status == .idle }
        try await r.command(.goToZero(axes: [.X]))
        try await until { let m = await r.machine; return abs(m.wpos[0]) < 1e-6 && m.status == .idle }
        let m = await r.machine
        #expect(close(m.mpos[2], -1, 3)) // 1 mm under the top, not safe Z (+4.5)
        #expect(close(m.wpos[1], 0, 3)) // Y untouched
        // Already above the safe height: Z doesn't move at all.
        #expect(r.sim.received.filter { $0.hasPrefix("G53G0Z") }.count == 1)
        await r.done()
    }

    @Test func pauseStopsAtTheCurrentLineAndRaisesZToTheTop() async throws {
        let r = try await Rig.make(Rig.sim(speed: 5), config: .defaults)
        try await r.command(.home)
        try await until { await r.idle() }
        try await r.command(.jog(x: -100, y: -100, z: -40, feed: 6000))
        try await until { let m = await r.machine; return m.mpos[2] == -40 && m.status == .idle }
        try await r.command(.zero(axes: [.X, .Y, .Z]))
        try await until { await r.machine.wco[2] == -40 }
        try await r.start(program())
        try await until(15000) { let n = await r.job.cuttingLine ?? 0; let st = await r.machine.status; return n > 10 && st == .run }
        try await r.command(.pauseLift, by: "garage")
        let job = await r.job
        #expect(job.status == .stopped)
        #expect(job.lifted == true)
        #expect(try #require(job.resumeLine) > 5)
        try await until { let m = await r.machine; return m.status == .idle && close(m.mpos[2], -1, 3) }
        #expect(await r.machine.alarm == nil)
        #expect(r.sim.received.last == "G53G0Z-1")
        // A fresh start (the resume) clears the flag.
        await expectThrows("No job is running") { try await r.command(.pauseLift) }
        await r.done()
    }

    @Test func remembersWhereAStoppedJobGotToAndResumesFromThere() async throws {
        let r = try await Rig.make(Rig.sim(speed: 5), config: .defaults)
        let text = program()
        let lines = streamableLines(text)
        try await r.start(text)
        try await until(15000) { let n = await r.job.ackedLines; let st = await r.machine.status; return n > 30 && st == .run }
        try await r.command(.stop, by: "garage")
        try await until { await r.job.status == .stopped }
        try await until { await r.idle() }
        let stopped = await r.machine.wpos
        let resume = try #require(await r.job.resumeLine)
        #expect(resume > 5)
        // Never past the line the cutter was on: the stop position lies on or after the resume line's start.
        let at = stateAt(text, resume).pos
        let next = stateAt(text, resume + 1).pos
        #expect(try #require(at[1]) <= stopped[1] + 1e-6)
        #expect(try #require(next[1]) >= stopped[1] - 0.6) // within a line or so

        let before = r.sim.received.count
        try await r.start(text, from: resume)
        #expect(await r.job.ackedLines == resume)
        try await until(30000) { await r.job.status == .done }
        let sent = Array(r.sim.received[before...])
        #expect(Array(sent.prefix(2)) == ["", "G21G90G17G94G54"]) // the buffer flush, then the preamble
        #expect(sent.contains("M3S12000"))
        #expect(Array(sent.suffix(lines.count - resume)) == lines[resume...].map(\.text))
        let job = await r.job
        #expect(job.ackedLines == job.totalLines)
        await r.done()
    }

    @Test func clearsStrayCharactersBeforeAJob() async throws {
        let r = try await Rig.make()
        r.sim.write("7#") // noise received while idle, with no newline
        try await r.start(program())
        try await until(15000) { let s = await r.job.status; return s == .done || s == .paused }
        #expect(await r.job.error == nil)
        #expect(await r.job.status == .done)
        #expect(await r.s.console.contains { $0.text.contains("Cleared stray characters") })
        await r.done()
    }

    @Test func reportsProgressByMachineTimeNotByLinesQueued() async throws {
        let r = try await Rig.make(Rig.sim(speed: 5))
        // One long cut (10 s), then 30 short moves (3 s between them).
        let text = (["G21 G90", "G0 X0 Y0 Z0", "G1 X100 F600"] + (0..<30).map { "G1 X\(jsNumber(100 + Double($0 % 2 + 1) * 0.5)) F600" }).joined(separator: "\n")
        try await r.start(text, "long.nc")
        // On the long cut: back at Y0 Z0 after the rapid, part way along X.
        try await until {
            let m = await r.machine
            return m.status == .run && abs(m.wpos[1]) < 1e-3 && abs(m.wpos[2]) < 1e-3 && m.wpos[0] > 30 && m.wpos[0] < 80
        }
        try await wait(150)
        // GRBL has taken nearly every line, but the cutter is still on the long one.
        let job = await r.job
        #expect(job.ackedLines > 12) // the sim queues 15 moves
        #expect(job.cuttingLine == 2)
        #expect(job.percent > 20 && job.percent < 80)
        // It advances with the tool along the cut: 1 mm of X is 0.1 s at F600.
        // Job and position from the same status report (one arriving between the reads would skew it).
        func sample() async throws -> (Double, Double) {
            while true {
                let before = await r.machine.wpos[0]
                let done = await r.job.doneSeconds ?? 0
                if await r.machine.wpos[0] == before { return (done, before) }
                try await wait(20)
            }
        }
        let (d1, x1) = try await sample()
        try await wait(300)
        let (d2, x2) = try await sample()
        #expect(d2 > d1)
        #expect(abs(d2 - d1 - (x2 - x1) / 10) < 0.6)
        try await until(15000) { await r.job.status == .done }
        #expect(await r.job.percent == 100)
        await r.done()
    }

    @Test func stopsJogsAtTheEndOfTravelOnceHomed() async throws {
        let r = try await Rig.make(config: .defaults) // travel X/Y -800..0, Z -120..0
        // Before homing the position means nothing, so jogs aren't limited.
        #expect(await r.machine.homed != true)
        try await r.command(.home)
        #expect(await r.machine.homed == true)
        try await r.command(.jog(x: nil, y: nil, z: -30, feed: 3000))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] < -29.9 }
        r.sim.clearReceived()
        try await r.command(.jog(x: nil, y: nil, z: 50, feed: 3000)) // only 30 mm left
        #expect(r.sim.received.last == "$J=G91G21Z30F3000")
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] > -0.01 }
        await expectThrows(#"end of travel \(Z\+\)"#) { try await r.command(.jog(x: nil, y: nil, z: 10, feed: 3000)) }
        // Sideways still works at the top.
        try await r.command(.jog(x: -10, y: nil, z: 5, feed: 3000))
        #expect(r.sim.received.last == "$J=G91G21X-10F3000")
        #expect(await r.machine.alarm == nil)
        await r.done()
    }

    /// Home X on a GRBL with single-axis homing: Z homes first to lift the bit, then X; Y stays where it was.
    @Test func homesOneAxisWithZFirst() async throws {
        let r = try await Rig.make(config: .defaults)
        try await until { await r.machine.homeAxes == true }
        try await r.command(.jog(x: -100, y: -100, z: -30, feed: 5000))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] < -29.9 }
        #expect(await r.machine.homed != true)
        r.sim.clearReceived()
        try await r.command(.homeAxis(axis: .X))
        #expect(r.sim.received.filter { $0.hasPrefix("$H") } == ["$HZ", "$HX"])
        try await until { let m = await r.machine; return m.status == .idle && abs(m.mpos[0]) < 0.01 }
        let m = await r.machine
        #expect(abs(m.mpos[2]) < 0.01 && abs(m.mpos[1] + 100) < 0.01)
        // Two of three axes homed isn't homed; Y makes it.
        #expect(m.homed != true)
        try await r.command(.homeAxis(axis: .Y))
        #expect(await r.machine.homed == true)
        await r.done()
    }

    /// Stock GRBL can't home one axis: never send it `$HX`; once homed, move back to the home position instead.
    @Test func withoutSingleAxisHomingMovesBackToHome() async throws {
        let r = try await Rig.make(Rig.sim { $0.singleAxisHoming = false }, config: .defaults)
        try await until { await r.machine.homeAxes == false }
        await expectThrows("can't home one axis") { try await r.command(.homeAxis(axis: .X)) }
        try await r.command(.home)
        try await until { let m = await r.machine; return m.status == .idle && m.homed == true }
        try await wait(100) // the status report after homing records where it left the machine
        try await r.command(.jog(x: -100, y: -100, z: -30, feed: 5000))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] < -29.9 }
        r.sim.clearReceived()
        try await r.command(.homeAxis(axis: .X))
        #expect(!r.sim.received.contains { $0.hasPrefix("$H") })
        #expect(r.sim.received.filter { $0.hasPrefix("G53") } == ["G53G0Z0", "G53G0X0"])
        await r.done()
    }

    @Test func refusesAJobThatWouldGoPastTheTopOfZ() async throws {
        let r = try await Rig.make(config: .defaults)
        try await r.command(.home)
        try await r.command(.jog(x: -100, y: -100, z: -3, feed: 5000))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] < -2.9 }
        try await r.command(.zero(axes: [.X, .Y, .Z])) // Z zero 3 mm below the top
        try await until { abs(await r.machine.wco[2] + 3) < 1e-6 }
        let fits = Bounds(min: Vec3(0, 0, -1), max: Vec3(50, 50, 2))
        try await r.s.checkFitsTravel(fits)
        await expectThrows("Z by 2.0 mm past the top.*safe-Z") { try await r.s.checkFitsTravel(Bounds(min: fits.min, max: Vec3(50, 50, 5))) }
        await expectThrows("X by 50.0 mm past the near end") { try await r.s.checkFitsTravel(Bounds(min: Vec3(-750, 0, -1), max: fits.max)) }
        await r.done()
    }

    @Test func refusesTypedCommandsAndMacrosPastTheEndOfTravel() async throws {
        let r = try await Rig.make(config: .defaults) // Z -120..0
        try await r.command(.home)
        try await r.command(.jog(x: nil, y: nil, z: -20, feed: 3000))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] < -19.9 }
        r.sim.clearReceived()
        // The second line, relative to where the first leaves it, ends 10 mm above the top.
        await expectThrows(#""G0 Z15" would go 10.0 mm past the top of Z"#) { try await r.command(.mdi(line: "G91 G0 Z15\nG0 Z15")) }
        await expectThrows("past the end of X") { try await r.command(.mdi(line: "G53 G0 X10")) }
        #expect(r.sim.received.isEmpty)
        await r.s.setMacros([Macro(id: "m", name: "Park", gcode: "G53 G0 Z5")])
        await expectThrows(#"Macro "Park": "G53 G0 Z5" would go 5.0 mm past the top"#) { try await r.command(.runMacro(id: "m")) }
        // Within travel is fine, and relative moves are followed line by line.
        try await r.command(.mdi(line: "G91 G0 Z10\nG0 Z5\nG90"))
        try await until { let m = await r.machine; return m.status == .idle && m.mpos[2] > -5.1 }
        #expect(await r.machine.alarm == nil)
        await r.done()
    }

    @Test func stopsAndRestartsTheSpindleWhilePaused() async throws {
        let r = try await Rig.make(Rig.sim(speed: 2))
        try await r.start(program())
        try await until { let m = await r.machine; return m.accessories == "S" && m.status == .run }
        try await r.command(.hold)
        try await until { let m = await r.machine; return m.status == .hold && m.subState == 0 }
        try await r.command(.spindleStop)
        try await until { (await r.machine.accessories ?? "").isEmpty }
        #expect(await r.machine.spindle == 0)
        try await r.command(.resume)
        try await until { await r.machine.accessories == "S" }
        try await r.command(.stop)
        try await until { await r.job.status == .stopped }
        await r.done()
    }

    @Test func marksTheJobFailedWhenTheUsbLinkDrops() async throws {
        let r = try await Rig.make(Rig.sim(speed: 1))
        try await r.start(program())
        try await until { await r.machine.status == .run }
        r.sim.unplug()
        try await until { await r.job.status == .error }
        #expect(await r.machine.connection == .disconnected)
        await r.done()
    }
}

@Suite(.serialized) struct ProbeTests {
    func config(_ plate: Double = 15) -> MachineConfig {
        var c = MachineConfig.defaults
        c.probe.plateThickness = plate
        return c
    }

    func rig(_ surface: Double?, plate: Double = 15, speed: Double = 100, _ change: (inout FakeGrblOptions) -> Void = { _ in }) async throws -> Rig {
        try await Rig.make(Rig.sim(speed: speed) { $0.probeSurfaceZ = surface; change(&$0) }, config: config(plate), waitForSettings: false)
    }

    @Test func touchesTwiceAndSetsWorkZToThePlateThickness() async throws {
        let r = try await rig(-20)
        try await r.command(.probeZ, by: "garage")
        let probes = r.sim.received.filter { $0.hasPrefix("G38.2") }
        #expect(probes.count == 2)
        #expect(probes.last?.hasSuffix("F25") == true) // slow second touch
        // Plate top at machine Z -20, 15 mm thick: the stock surface is machine Z -35.
        try await until { abs(await r.machine.wpos[2] - 20) < 0.01 } // lifted to thickness + retract
        let m = await r.machine
        #expect(close(m.wco[2], -35, 3))
        #expect(m.probing == false)
        #expect(m.lastProbe?.ok == true && m.lastProbe?.contactZ == -20)
        #expect(m.status == .idle)
        await r.done()
    }

    @Test func reportsAMissWhenNothingIsTouched() async throws {
        let r = try await rig(nil)
        await expectThrows("No contact within 25 mm") { try await r.command(.probeZ) }
        let m = await r.machine
        #expect(m.status == .alarm)
        #expect(m.lastProbe?.ok == false)
        #expect(m.probing == false)
        try await until { abs(await r.machine.mpos[2] + 25) < 0.001 } // searched the full 25 mm
        await r.done()
    }

    @Test func refusesToProbeUntilThePlateThicknessIsSet() async throws {
        let r = try await rig(-20, plate: 0)
        await expectThrows("plate thickness") { try await r.command(.probeZ) }
        #expect(!r.sim.received.contains { $0.hasPrefix("G38") })
        await r.done()
    }

    @Test func refusesToProbeWhenTheProbeInputIsAlreadyClosed() async throws {
        let r = try await rig(0) // the bit already rests on the plate
        try await until { await r.machine.pins?.contains("P") == true }
        await expectThrows("already closed") { try await r.command(.probeZ) }
        #expect(!r.sim.received.contains { $0.hasPrefix("G38") })
        await r.done()
    }

    @Test func blocksJoggingWhileProbing() async throws {
        let r = try await rig(-20, speed: 2)
        let probing = Task { () -> (any Error)? in
            do { try await r.command(.probeZ); return nil } catch { return error }
        }
        try await until { await r.machine.probing == true }
        await expectThrows("while probing") { try await r.command(.jog(x: nil, y: nil, z: 1, feed: 100)) }
        try await r.command(.reset)
        #expect(await probing.value != nil)
        #expect(await r.machine.probing == false)
        await r.done()
    }

    @Test func readsFoxAliens4AxisProbeReportFromABoardThatDoesntResetOnOpen() async throws {
        let r = try await rig(-20) { $0.fourAxis = true; $0.bannerOnOpen = false }
        try await until { await r.machine.settings?["130"] != nil }
        #expect(await r.machine.firmware?.hasPrefix("GRBL 1.1h") == true)
        try await r.command(.probeZ, by: "garage")
        try await until { abs(await r.machine.wpos[2] - 20) < 0.01 }
        let m = await r.machine
        #expect(close(m.wco[2], -35, 3))
        #expect(m.lastProbe?.ok == true && m.lastProbe?.contactZ == -20)
        await r.done()
    }

    @Test func keepsSettingsTypedAsDollarDollarInTheConsole() async throws {
        let r = try await rig(-20)
        try await until { await r.machine.settings?["130"] != nil }
        try await r.command(.mdi(line: "$130=750"))
        try await r.command(.mdi(line: "$$"))
        try await until { let v = await r.machine.settings?["130"]; return v == "750.000" || v == "750" }
        await r.done()
    }

    @Test func carriesOnWhenAReplyGoesMissingInsteadOfHanging() async throws {
        let r = try await rig(-20)
        r.sim.dropNextOk()
        try await r.command(.mdi(line: "G21"))
        #expect(await r.s.console.contains { $0.text.contains("No reply from the controller to \"G21\"") })
        try await r.command(.probeZ, by: "garage")
        try await until { abs(await r.machine.wpos[2] - 20) < 0.01 }
        #expect(await r.machine.lastProbe?.ok == true)
        await r.done()
    }
}
