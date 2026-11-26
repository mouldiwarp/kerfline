// swarfgrbl-cli: a headless GRBL sender built on MachineSession.
//   swarfgrbl-cli ports                                  list serial ports
//   swarfgrbl-cli stream --simulate file.nc              stream to the built-in simulator
//   swarfgrbl-cli stream [--port /dev/cu.x] file.nc      stream over USB (auto-detects the port)
// Ctrl-C stops the job (feed hold, then soft reset).

import Foundation
import SGCore
import SGMachine

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swarfgrbl-cli: \(message)\n".utf8))
    exit(1)
}

let usage = """
    usage: swarfgrbl-cli ports
           swarfgrbl-cli stream [--simulate [--speed N] | --port PATH] [--from LINE] FILE
    """

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func next() -> String { args.isEmpty ? "" : args.removeFirst() }
guard let verb = args.first else { print(usage); exit(2) }
args.removeFirst()

switch verb {
case "ports":
    let ports = listPorts()
    if ports.isEmpty { print("No serial ports") }
    for p in ports {
        let ids = [p.vendorId, p.productId].compactMap { $0 }.joined(separator: ":")
        print("\(p.likelyGrbl ? "*" : " ") \(p.path)\(ids.isEmpty ? "" : "  [\(ids)]")\(p.manufacturer.map { "  \($0)" } ?? "")")
    }
    exit(0)
case "stream":
    var simulate = false
    var speed = 1.0
    var port: String?
    var from: Int?
    var file: String?
    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--simulate": simulate = true
        case "--speed":
            guard let n = Double(next()) else { fail("--speed needs a number") }
            speed = n
        case "--port": port = next()
        case "--from":
            guard let n = Int(next()), n > 0 else { fail("--from needs a line number") }
            from = n - 1
        default: file = a
        }
    }
    guard let file else { fail(usage) }
    guard let data = FileManager.default.contents(atPath: file) else {
        fail("can't read \(file)")
    }
    let text = String(decoding: data, as: UTF8.self)
    try await stream(text, name: (file as NSString).lastPathComponent, simulate: simulate, speed: speed, port: port, from: from)
default:
    print(usage)
    exit(2)
}

func stream(_ text: String, name: String, simulate: Bool, speed: Double, port: String?, from: Int?) async throws {
    let transport: any Transport
    if simulate {
        transport = FakeGrbl(FakeGrblOptions(speed: speed, homingRequired: false))
    } else {
        guard let path = port ?? autoDetectPort() else { fail("no GRBL port found (swarfgrbl-cli ports lists them)") }
        transport = SerialPort(path)
    }
    let session = MachineSession(simulated: simulate)
    await session.setConfig(.defaults)
    let events = await session.events()

    // Print the console and progress as they arrive; finish when the job does.
    let finished = Task { () -> JobStatus in
        var started = false
        var lastPct = -1
        for await e in events {
            switch e {
            case .console(let lines):
                for l in lines {
                    let tag = switch l.dir { case .in: "<"; case .out: ">"; case .info: "*"; case .error: "!" }
                    print("\(tag) \(l.text)")
                }
            case .job(let j):
                if j.status == .running { started = true }
                let pct = Int(j.percent)
                if j.status == .running && pct != lastPct && pct % 5 == 0 {
                    lastPct = pct
                    print("  \(pct)%  line \(j.sourceLine + 1) of \(j.totalLines)  \(formatDuration(j.elapsedSeconds()))")
                }
                if started && [.done, .stopped, .error, .toolchange].contains(j.status) { return j.status }
            case .machine(let m):
                if started && m.connection == .disconnected { return .error }
            case .toast: break
            }
        }
        return .error
    }

    try await session.connect(transport)
    // Wait for the banner (or first status report) and the settings.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let m = await session.machine
        if m.connection == .connected && m.status != .unknown && !(m.settings ?? [:]).isEmpty { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let m = await session.machine
    guard m.connection == .connected else { fail("the controller did not answer on \(transport.name)") }
    if m.status == .alarm { fail("the machine is in ALARM (home or unlock it first)") }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\n* Stopping…")
        Task { try? await session.command(.stop, by: "swarfgrbl-cli") }
    }
    sigint.resume()

    do {
        try await session.startJob(text, .init(fileId: "cli", fileName: name, by: "swarfgrbl-cli", fromLine: from))
    } catch {
        fail(error.localizedDescription)
    }
    let status = await finished.value
    try await Task.sleep(for: .milliseconds(100)) // let the last console lines print
    let j = await session.job
    await session.disconnect()
    if let f = transport as? FakeGrbl, f.overflowed { fail("RX buffer overflow in the simulator") }
    print("Finished: \(status.rawValue) in \(formatDuration(j.elapsedSeconds()))\(j.error.map { " (\($0))" } ?? "")")
    exit(status == .done ? 0 : 1)
}
