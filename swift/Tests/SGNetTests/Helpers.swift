import Foundation
import SGCore
import SGLibrary
import SGMachine
import Testing

@testable import SGNet

func gcode(_ n: Int = 3) -> Data {
    Data((["G21 G90", "M3 S12000", "G0 Z5"] + (0..<n).map { "G1 X\($0) Y\($0) F1000" } + ["M30"]).joined(separator: "\n").utf8)
}

/// A temporary folder per test (the previous run's are removed).
final class Sandbox: Sendable {
    let dir: URL
    var data: URL { dir.appending(path: "data") }
    var root: URL { dir.appending(path: "SwarfGRBL") }

    static let base: URL = {
        let base = FileManager.default.temporaryDirectory.appending(path: "sg-net-tests")
        try? FileManager.default.removeItem(at: base)
        return base.appending(path: UUID().uuidString)
    }()

    init() {
        dir = Sandbox.base.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func open() async throws -> Library {
        try await Library.open(LibraryOptions(dataDir: data, root: root, settleMs: 0))
    }
}

func until(_ ms: Int = 8000, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await cond()
}

let fastSim = MachineOption.simulator(FakeGrblOptions(speed: 50, homingRequired: false, workOffset: .zero, bootDelayMs: 0))

/// A hub on 127.0.0.1 (a free port, no Bonjour), and optionally an agent linked to it.
final class Macs: @unchecked Sendable {
    let hubBox = Sandbox(), agentBox = Sandbox()
    var hub: Instance!
    var agent: Instance!

    func startHub(machine: MachineOption = .none, inbox: URL? = nil, code: CodeVersion? = nil) async throws {
        let lib = try await hubBox.open()
        hub = Instance(
            InstanceOptions(name: "Design", role: .hub, host: "127.0.0.1", port: 0, advertise: false, machine: machine, inbox: inbox, pollMs: 50, code: code),
            library: lib)
        try await hub.start()
    }

    var base: String {
        get async { "http://127.0.0.1:\(await hub.port!)" }
    }

    func startAgent(machine: MachineOption = fastSim, code: CodeVersion? = nil) async throws {
        let lib = try await agentBox.open()
        let url = URL(string: "ws://127.0.0.1:\(await hub.port!)/link")!
        agent = Instance(
            InstanceOptions(name: "Garage", role: .agent, hubURL: url, machine: machine, pollMs: 50, redialSeconds: 0.2, code: code), library: lib)
        try await agent.start()
    }

    func linked() async -> Bool {
        await until {
            let a = await hub.isLinked
            let b = await agent.isLinked
            return a && b
        }
    }

    func stop() async {
        await agent?.stop()
        await hub?.stop()
    }
}

struct HTTPReply {
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    func json() -> [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

func http(_ method: String, _ url: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> HTTPReply {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    r.httpBody = body
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await URLSession.shared.data(for: r)
    let h = response as! HTTPURLResponse
    var headers: [String: String] = [:]
    for (k, v) in h.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
    return HTTPReply(status: h.statusCode, headers: headers, body: data)
}

/// Collects an instance's toasts.
actor Toasts {
    private(set) var texts: [String] = []
    init(_ instance: Instance) async {
        let events = await instance.events()
        Task { [weak self] in
            for await e in events {
                if case .toast(let t) = e { await self?.add(t.text) }
            }
        }
    }
    private func add(_ t: String) { texts.append(t) }
    func has(_ t: String) -> Bool { texts.contains(t) }
}

/// A job that stays inside the simulator's travel (machine coordinates are negative).
func job(_ n: Int) -> Data {
    Data((["G21 G90", "M3 S12000", "G0 Z-1"] + (1...n).map { "G1 X-\($0) Y-\($0) F3000" } + ["G0 Z-1", "M30"]).joined(separator: "\n").utf8)
}
