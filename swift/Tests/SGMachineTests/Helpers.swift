import Foundation
import SGCore
import Testing
@testable import SGMachine

struct Timeout: Error, CustomStringConvertible {
    var description: String
}

/// Poll until `cond` holds (every 5 ms), or fail after `ms`.
func until(_ ms: Int = 8000, _ what: String = "condition", sourceLocation: SourceLocation = #_sourceLocation, _ cond: () async -> Bool) async throws {
    let end = ContinuousClock.now + .milliseconds(ms)
    while !(await cond()) {
        if ContinuousClock.now > end {
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
            throw Timeout(description: "timeout: \(what)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func wait(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

/// Expect `body` to throw an error whose message matches the regex `pattern`.
func expectThrows(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected an error matching /\(pattern)/", sourceLocation: sourceLocation)
    } catch {
        let message = "\(error)"
        #expect(message.range(of: pattern, options: .regularExpression) != nil, "\"\(message)\" doesn't match /\(pattern)/", sourceLocation: sourceLocation)
    }
}

func close(_ a: Double, _ b: Double, _ digits: Int = 2) -> Bool { abs(a - b) < 0.5 * pow(10, -Double(digits)) }

/// A FakeGrbl and a MachineSession connected to it.
struct Rig {
    let sim: FakeGrbl
    let s: MachineSession

    static func make(_ opts: FakeGrblOptions = .init(speed: 200, homingRequired: false, bootDelayMs: 0), config: MachineConfig? = nil, waitForSettings: Bool = true) async throws -> Rig {
        let sim = FakeGrbl(opts)
        let s = MachineSession(pollMs: 20, simulated: true)
        await s.setConfig(config)
        try await s.connect(sim)
        try await until(8000, "connected and idle") { let m = await s.machine; return m.connection == .connected && m.status == .idle }
        if waitForSettings { try await until(8000, "settings") { await s.machine.settings != nil } }
        return Rig(sim: sim, s: s)
    }

    static func sim(speed: Double = 200, _ change: (inout FakeGrblOptions) -> Void = { _ in }) -> FakeGrblOptions {
        var o = FakeGrblOptions(speed: speed, homingRequired: false, bootDelayMs: 0)
        change(&o)
        return o
    }

    var machine: MachineState { get async { await s.machine } }
    var job: JobState { get async { await s.job } }
    func command(_ c: Command, by: String? = nil) async throws { try await s.command(c, by: by) }
    func start(_ text: String, _ name: String = "pocket.nc", from: Int? = nil, by: String? = nil) async throws {
        try await s.startJob(text, .init(fileId: "f1", fileName: name, by: by, fromLine: from))
    }
    func idle() async -> Bool { await machine.status == .idle }
    func done() async { await s.disconnect() }
}
