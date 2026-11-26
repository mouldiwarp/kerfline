// Port of packages/agent/test/fakeGrbl.test.ts.

import Foundation
import SGCore
import Testing
@testable import SGMachine

/// Collects the simulator's reply lines.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    private var task: Task<Void, Never>?
    var all: [String] { lock.withLock { _all } }
    func contains(_ l: String) -> Bool { all.contains(l) }

    init(_ sim: FakeGrbl) {
        let events = sim.events
        task = Task { [weak self] in
            var buf: [UInt8] = []
            for await e in events {
                guard case .data(let d) = e else { continue }
                buf += d
                while let i = buf.firstIndex(of: 10) {
                    let l = latin1(buf[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                    buf.removeSubrange(...i)
                    if !l.isEmpty { self?.lock.withLock { self?._all.append(l) } }
                }
            }
        }
    }
}

@Suite struct FakeGrblTests {
    @Test func bootsIntoAlarmAndUnlocksWithDollarX() async throws {
        let sim = FakeGrbl(.init(bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        try await until { out.all.contains { $0.hasPrefix("Grbl 1.1h") } }
        #expect(sim.state == .alarm)
        sim.write("G0X1\n")
        try await until { out.contains("error:9") }
        sim.write("$X\n")
        try await until { out.contains("[MSG:Caution: Unlocked]") }
        #expect(sim.state == .idle)
        await sim.close()
    }

    @Test func movesReportsStatusAndSetsWorkZero() async throws {
        let sim = FakeGrbl(.init(speed: 100, homingRequired: false, workOffset: .zero, bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        sim.write("G0X-10Y-20\n")
        try await until { out.contains("ok") }
        try await until { sim.state == .idle && sim.mpos[0] == -10 }
        sim.write("G10L20P0X0Y0Z0\n")
        try await until { out.all.filter { $0 == "ok" }.count == 2 }
        #expect(sim.wco == Vec3(-10, -20, 0))
        sim.write("?")
        try await until { out.all.contains { $0.hasPrefix("<Idle|MPos:-10.000,-20.000,0.000") } }
        #expect(out.all.first { $0.hasPrefix("<Idle") }?.contains("WCO:-10.000,-20.000,0.000") == true)
        await sim.close()
    }

    @Test func refusesMovesAboveTheTopOfZEvenWithoutSoftLimits() async throws {
        let sim = FakeGrbl(.init(speed: 100, homingRequired: false, workOffset: .zero, bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        sim.write("$J=G91Z5F1000\n")
        try await until { out.contains("error:15") }
        #expect(sim.mpos[2] == 0)
        sim.write("G0Z5\n")
        try await until { out.contains("ALARM:2") }
        #expect(sim.state == .alarm)
        #expect(sim.mpos[2] == 0)
        await sim.close()
    }

    @Test func flagsRxOverflowWhenTheHostIgnoresTheBuffer() async throws {
        let sim = FakeGrbl(.init(speed: 0.001, homingRequired: false, bootDelayMs: 0))
        try await sim.open()
        sim.write((0..<40).map { "G1X\($0)F100" }.joined(separator: "\n") + "\n")
        #expect(sim.overflowed)
        await sim.close()
    }

    @Test func holdsResumesAndSoftResetInMotionRaisesAlarm3() async throws {
        let sim = FakeGrbl(.init(speed: 1, homingRequired: false, bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        sim.write("G1X-50F600\n")
        try await until { sim.state == .run }
        sim.write("!")
        #expect(sim.state == .hold)
        let x = sim.mpos[0]
        try await wait(50)
        #expect(sim.mpos[0] == x)
        sim.write("~")
        #expect(sim.state == .run)
        sim.write([RT.softReset])
        try await until { out.contains("ALARM:3") }
        #expect(sim.state == .alarm)
        await sim.close()
    }

    @Test func homesWithDollarHAndRepliesOkWhenDone() async throws {
        // Homing takes 2 simulated seconds: at speed 2, 100 ticks, so never less than about 1 s of real time.
        let sim = FakeGrbl(.init(speed: 2, bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        try await until { sim.state == .alarm }
        let start = ContinuousClock.now
        sim.write("$H\n")
        // Not by watching for the Home state: a busy CI runner can starve this poll past the end of homing.
        try await until { out.contains("ok") }
        #expect(ContinuousClock.now - start >= .milliseconds(900), "ok only once homing has finished")
        #expect(sim.state == .idle)
        #expect(sim.mpos == .zero)
        await sim.close()
    }

    @Test func appliesFeedOverridesFromRealtimeBytes() async throws {
        let sim = FakeGrbl(.init(homingRequired: false, bootDelayMs: 0))
        let out = Lines(sim)
        try await sim.open()
        sim.write([RT.feedOvPlus10, RT.feedOvPlus10, RT.feedOvPlus1])
        for _ in 0..<6 { sim.write("?") }
        try await until { out.all.contains { $0.contains("Ov:121,100,100") } }
        await sim.close()
    }
}
