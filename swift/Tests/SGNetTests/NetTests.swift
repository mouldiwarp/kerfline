import Foundation
import SGCore
import SGLibrary
import SGMachine
import Testing

@testable import SGNet

@Suite(.serialized) struct HubAPITests {
    @Test func theHTTPAPIIsTheSameAs1_0() async throws {
        let m = Macs()
        try await m.startHub()
        defer { Task { await m.stop() } }
        let toasts = await Toasts(m.hub)
        let base = await m.base

        let health = try await http("GET", "\(base)/api/health")
        #expect(health.status == 200)
        #expect(health.json()["ok"] as? Bool == true)
        #expect(health.json()["role"] as? String == "hub")
        #expect(health.json()["name"] as? String == "Design")
        #expect(health.json()["agent"] as? Bool == false)

        // Swarf: percent-encoded headers, text/plain body.
        let up = try await http(
            "POST", "\(base)/api/jobs", body: gcode(),
            headers: ["Content-Type": "text/plain", "X-Filename": "Strat%20body%201.nc", "X-Source": "Swarf", "X-Group": "Strat%20body", "X-Group-Index": "1"])
        #expect(up.status == 201)
        let id = try #require(up.json()["id"] as? String)
        let item = try #require(await m.hub.library.item(id))
        #expect(item.name == "Strat body 1.nc")
        #expect(item.source == "Swarf")
        #expect(item.group == "Strat body")
        #expect(item.groupIndex == 1)
        #expect((up.json()["item"] as? [String: Any])?["name"] as? String == "Strat body 1.nc")
        #expect(await until { await toasts.has("Received Strat body 1.nc from Swarf") })

        // Query parameters work too; the source defaults to Upload (and isn't named in the toast).
        let q = try await http("POST", "\(base)/api/files?name=plain.nc&folder=Jigs", body: gcode(4))
        #expect(q.status == 201)
        let qid = try #require(q.json()["id"] as? String)
        #expect(await m.hub.library.item(qid)?.source == "Upload")
        #expect(await m.hub.library.item(qid)?.folder == "Jigs")
        #expect(await until { await toasts.has("Received plain.nc") })

        let bad = try await http("POST", "\(base)/api/jobs", body: Data(), headers: ["X-Filename": "empty.nc"])
        #expect(bad.status == 400)
        #expect(bad.json()["error"] as? String == "The file is empty")

        let got = try await http("GET", "\(base)/api/files/\(id)")
        #expect(got.status == 200)
        #expect(got.json()["sha256"] as? String == item.sha256)
        let content = try await http("GET", "\(base)/api/files/\(id)/content")
        #expect(content.status == 200)
        #expect(content.body == gcode())
        #expect(content.headers["content-type"] == "text/plain; charset=utf-8")
        #expect(content.headers["content-disposition"] == "inline; filename=\"Strat body 1.nc\"")
        #expect(content.headers["access-control-allow-origin"] == "*")

        let library = try await http("GET", "\(base)/api/library")
        #expect((try JSONSerialization.jsonObject(with: library.body) as? [Any])?.count == 2)
        let state = try JSONDecoder().decode(AppState.self, from: try await http("GET", "\(base)/api/state").body)
        #expect(state.library.count == 2)
        #expect(state.link.hubConnected && !state.link.agentConnected)
        #expect(state.machine.connection == .disconnected)

        for path in ["/api/files/nope", "/api/files/nope/content"] {
            let r = try await http("GET", base + path)
            #expect(r.status == 404)
            #expect(r.json()["error"] as? String == "File not found")
        }
        let unknown = try await http("GET", "\(base)/api/nope")
        #expect(unknown.status == 404)
        #expect(unknown.json()["error"] as? String == "Not found")
        #expect(try await http("GET", "\(base)/index.html").status == 404)

        let options = try await http("OPTIONS", "\(base)/api/jobs")
        #expect(options.status == 204)
        #expect(options.headers["access-control-allow-origin"] == "*")
        #expect(options.headers["access-control-allow-methods"] == "GET,POST,DELETE,OPTIONS")
        #expect(options.headers["access-control-allow-headers"] == "content-type,x-filename,x-source,x-group,x-group-index")

        let del = try await http("DELETE", "\(base)/api/files/\(id)")
        #expect(del.status == 200)
        #expect(del.json()["ok"] as? Bool == true)
        #expect(await m.hub.library.item(id) == nil)
        #expect(await m.hub.library.trash().map(\.item.id) == [id])
        let again = try await http("DELETE", "\(base)/api/files/\(id)")
        #expect(again.status == 400)
        #expect(again.json()["ok"] as? Bool == false)
    }

    @Test func theInboxImportsSettledFilesAndFilesThemAway() async throws {
        let box = Sandbox()
        let dir = box.dir.appending(path: "GCode Inbox")
        try FileManager.default.createDirectory(at: dir.appending(path: "imported"), withIntermediateDirectories: true)
        let got = Got()
        let inbox = Inbox(dir) { name, data in await got.add(name, data) }
        try gcode().write(to: dir.appending(path: "part.nc"))
        try Data("x".utf8).write(to: dir.appending(path: ".hidden.nc"))
        try Data("%PDF".utf8).write(to: dir.appending(path: "drawing.pdf"))
        await inbox.scan()
        #expect(await got.names.isEmpty) // not settled yet
        await inbox.scan()
        #expect(await got.names == ["part.nc"])
        #expect(await got.data == [gcode()])
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appending(path: "imported/part.nc").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "part.nc").path))
        #expect(fm.fileExists(atPath: dir.appending(path: ".hidden.nc").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "drawing.pdf").path))

        // The same name again isn't overwritten in imported/.
        try gcode(5).write(to: dir.appending(path: "part.nc"))
        await inbox.scan()
        await inbox.scan()
        #expect(await got.names == ["part.nc", "part.nc"])
        let imported = try fm.contentsOfDirectory(atPath: dir.appending(path: "imported").path).sorted()
        #expect(imported.count == 2)
        #expect(imported.contains("part.nc"))
    }

    @Test func theHubsInboxLandsInTheLibrary() async throws {
        let m = Macs()
        let dir = m.hubBox.dir.appending(path: "GCode Inbox")
        try await m.startHub(inbox: dir)
        defer { Task { await m.stop() } }
        let toasts = await Toasts(m.hub)
        try gcode().write(to: dir.appending(path: "from-fusion.nc"))
        #expect(await until(10000) { await m.hub.library.items().contains { $0.name == "from-fusion.nc" && $0.source == "Inbox" } })
        #expect(await until { await toasts.has("Imported from-fusion.nc from the inbox") })
    }

    @Test func bonjourFindsTheHub() async throws {
        let name = "sg-test-\(randomId(6))"
        let found = Got()
        let browser = BonjourBrowser(onFound: { hub in
            if hub.name == name { Task { await found.add("\(hub.port) v\(hub.version ?? 0)", Data()) } }
        })
        browser.start()
        defer { browser.stop() }
        let advert = try #require(BonjourAdvert(name: name, port: 18_123))
        defer { advert.stop() }
        #expect(await until(10000) { await found.names.contains("18123 v2") })
    }
}

actor Got {
    private(set) var names: [String] = []
    private(set) var data: [Data] = []
    func add(_ n: String, _ d: Data) {
        names.append(n)
        data.append(d)
    }
}

@Suite(.serialized) struct TwoMacTests {
    @Test func aSwarfUploadLandsOnBothMacs() async throws {
        let m = Macs()
        try await m.startHub()
        try await m.startAgent()
        defer { Task { await m.stop() } }
        #expect(await m.linked())
        let agentToasts = await Toasts(m.agent)
        let base = await m.base
        #expect(try await http("GET", "\(base)/api/health").json()["agent"] as? Bool == true)

        let up = try await http("POST", "\(base)/api/jobs", body: gcode(), headers: ["X-Filename": "neck.nc", "X-Source": "Swarf"])
        let id = try #require(up.json()["id"] as? String)
        #expect(await until { await m.agent.library.content(id) == gcode() })
        #expect(await until { await agentToasts.has("Received neck.nc from Swarf") })

        // And the other way: a file added in the garage shows on the hub.
        let g = try await m.agent.library.add(gcode(6), AddOptions(name: "jig.nc", source: "Upload"))
        #expect(await until { await m.hub.library.content(g.id) == gcode(6) })

        let state = await m.agent.state()
        #expect(state.link.hubConnected && state.link.agentConnected)
        #expect(state.link.hubName == "Design" && state.link.agentName == "Garage")
    }

    @Test func theAgentOwnsTheMachineAndTheHubDrivesIt() async throws {
        let m = Macs()
        try await m.startHub()
        try await m.startAgent()
        defer { Task { await m.stop() } }
        #expect(await m.linked())

        // The hub has no machine, so Connect goes to the garage.
        try await m.hub.execute(.connect(port: nil), by: "Design")
        #expect(await until {
            let s = await m.hub.state()
            return s.machine.connection == .connected && s.machine.status == .idle && s.link.machineOn == "Garage"
        })
        #expect(await m.agent.owner() == .here)
        #expect(await m.hub.owner() == .peer("Garage"))

        // Commands from the hub run in the garage, and the hub sees the result.
        try await m.hub.execute(.mdi(line: "G0 X-10"), by: "Design")
        #expect(await until { await abs(m.agent.session.machine.wpos[0] + 10) < 1e-6 })
        #expect(await until { await abs(m.hub.state().machine.wpos[0] + 10) < 1e-6 })
        #expect(await until { await m.hub.state().console.contains { $0.text.contains("G0 X-10") } })

        // Refusals come back to the hub.
        await #expect(throws: MachineError("The machine is connected to Garage. Disconnect it there first")) {
            try await m.hub.execute(.connect(port: nil), by: "Design")
        }

        // A file sent to the hub runs in the garage from the garage's copy.
        let up = try await http("POST", "\(await m.base)/api/jobs", body: job(20), headers: ["X-Filename": "pocket.nc"])
        let id = try #require(up.json()["id"] as? String)
        #expect(await until { await m.agent.library.content(id) != nil })
        try await m.hub.execute(.start(fileId: id, group: nil, fromLine: nil), by: "Design")
        #expect(await until(15000) { await m.hub.state().job.status == .done })
        let job = await m.agent.session.job
        #expect(job.status == .done && job.fileId == id && job.startedBy == "Design")

        // Disconnecting from the hub frees the machine.
        try await m.hub.execute(.disconnect, by: "Design")
        #expect(await until { await m.hub.owner() == .none })
        #expect(await m.agent.owner() == .none)
    }

    @Test func eitherMacCanOwnTheMachine() async throws {
        let m = Macs()
        try await m.startHub(machine: fastSim)
        try await m.startAgent(machine: fastSim)
        defer { Task { await m.stop() } }
        #expect(await m.linked())

        try await m.agent.execute(.connect(port: nil), by: "Garage")
        #expect(await until { await m.hub.owner() == .peer("Garage") })
        await #expect(throws: MachineError("The machine is connected to Garage. Disconnect it there first")) {
            try await m.hub.execute(.connect(port: nil), by: "Design")
        }
        try await m.agent.execute(.disconnect, by: "Garage")
        #expect(await until { await m.hub.owner() == .none })

        // Now it's plugged into the design Mac.
        try await m.hub.execute(.connect(port: nil), by: "Design")
        #expect(await until {
            let s = await m.agent.state()
            return s.machine.connection == .connected && s.link.machineOn == "Design"
        })
        await #expect(throws: MachineError("The machine is connected to Design. Disconnect it there first")) {
            try await m.agent.execute(.connect(port: nil), by: "Garage")
        }
        try await m.agent.execute(.mdi(line: "G0 Y-5"), by: "Garage")
        #expect(await until { await abs(m.hub.session.machine.wpos[1] + 5) < 1e-6 })
        #expect(await m.agent.session.machine.connection == .disconnected)
    }

    @Test func aJobKeepsRunningWhenTheLinkDrops() async throws {
        let m = Macs()
        try await m.startHub()
        try await m.startAgent(machine: .simulator(FakeGrblOptions(speed: 5, homingRequired: false, workOffset: .zero, bootDelayMs: 0)))
        defer { Task { await m.stop() } }
        #expect(await m.linked())
        try await m.hub.execute(.connect(port: nil), by: "Design")
        #expect(await until { await m.hub.state().machine.status == .idle })
        let item = try await m.hub.library.add(job(40), AddOptions(name: "long.nc"))
        #expect(await until { await m.agent.library.content(item.id) != nil })
        try await m.hub.execute(.start(fileId: item.id, group: nil, fromLine: nil), by: "Design")
        #expect(await until { await m.agent.session.job.status == .running })

        // The design Mac goes away mid-job; the garage carries on.
        await m.hub.stop()
        #expect(await until { await !m.agent.isLinked })
        #expect(await m.agent.session.job.status == .running)
        #expect(await until(20000) { await m.agent.session.job.status == .done })
    }

    /// A program that cuts without ever starting the spindle (Fretboard Modeller with a manual spindle, say) is
    /// refused at Start, on the Mac that owns the machine, unless the user confirmed it; the library item says so too.
    @Test func aProgramThatNeverStartsTheSpindleNeedsConfirming() async throws {
        let m = Macs()
        try await m.startHub()
        try await m.startAgent(machine: fastSim)
        defer { Task { await m.stop() } }
        #expect(await m.linked())
        try await m.agent.execute(.connect(port: nil), by: "Garage")
        #expect(await until { await m.agent.state().machine.status == .idle })
        let text = "(no spindle)\nG21\nG90\nG0 Z-1\nG1 Z-2 F300\nG1 X-10 F1000\nM2\n"
        let item = try await m.hub.library.add(Data(text.utf8), AddOptions(name: "board.nc"))
        #expect(item.spindleOffCut == 4)
        #expect(await until { await m.agent.library.content(item.id) != nil })
        await #expect(throws: MachineError(spindleOffMessage("board.nc", 4))) {
            try await m.hub.execute(.start(fileId: item.id, group: nil, fromLine: nil), by: "Design")
        }
        #expect(await m.agent.session.job.status != .running)
        try await m.hub.execute(.start(fileId: item.id, group: nil, fromLine: nil, spindleOff: true), by: "Design")
        #expect(await until { await m.agent.session.job.status == .done })
    }

    @Test func scriptsOnThisMacCanSendCommands() async throws {
        let m = Macs()
        try await m.startHub(machine: fastSim)
        defer { Task { await m.stop() } }
        let base = await m.base
        let ok = try await http("POST", "\(base)/api/command", body: Data(#"{"type":"connect"}"#.utf8))
        #expect(ok.status == 200)
        #expect(await until { await m.hub.state().machine.status == .idle })
        _ = try await http("POST", "\(base)/api/command", body: Data(#"{"type":"mdi","line":"G0 X-5"}"#.utf8))
        #expect(await until { await abs(m.hub.state().machine.wpos[0] + 5) < 1e-6 })
        // Refusals come back as errors, and junk is rejected.
        let refused = try await http("POST", "\(base)/api/command", body: Data(#"{"type":"start","fileId":"nope"}"#.utf8))
        #expect(refused.status == 409)
        let junk = try await http("POST", "\(base)/api/command", body: Data(#"{"type":"fly"}"#.utf8))
        #expect(junk.status == 400)
    }

    @Test func eachMacKnowsTheOthersCodeAndCanAskItToUpdate() async throws {
        let m = Macs()
        let old = CodeVersion(version: "2.0.0", commit: "aaaaaaa1", time: 1_000)
        let new = CodeVersion(version: "2.0.0", commit: "bbbbbbb2", time: 2_000)
        try await m.startHub(code: new)
        try await m.startAgent(machine: .none, code: old)
        defer { Task { await m.stop() } }
        #expect(await m.linked())
        #expect(await until { await m.hub.state().link.peerCode == old })
        #expect(await m.agent.state().link.peerCode == new)
        #expect(compareCode(new, await m.hub.state().link.peerCode) == .ahead)

        // Without an updater, the garage refuses (and the refusal comes back to the hub).
        await #expect(throws: MachineError("Garage can't update itself")) {
            try await m.hub.execute(.update(target: .agent), by: "Design")
        }
        // With one, the hub's request runs it in the garage.
        let asked = Counter()
        await m.agent.setUpdater { await asked.add() }
        try await m.hub.execute(.update(target: .agent), by: "Design")
        #expect(await asked.n == 1)
        // A refusal to start (a job running there) comes back too.
        await m.agent.setUpdater { throw MachineError("A job is running on Garage") }
        await #expect(throws: MachineError("A job is running on Garage")) {
            try await m.hub.execute(.update(target: .agent), by: "Design")
        }
    }
}

actor Counter {
    var n = 0
    func add() { n += 1 }
}
