import Foundation
import SGCore
import SGLibrary
import SGMachine
import SGNet
import Testing

@testable import SGUI

private func gcode(_ n: Int = 3) -> Data {
    Data((["G21 G90", "M3 S12000", "G0 Z-1"] + (1...n).map { "G1 X-\($0) Y-\($0) F3000" } + ["M30"]).joined(separator: "\n").utf8)
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "sg-ui-tests/\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor
private func until(_ ms: Int = 8000, _ cond: @MainActor () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await cond()
}

private let fastSim = MachineOption.simulator(FakeGrblOptions(speed: 50, homingRequired: false, workOffset: .zero, bootDelayMs: 0))

/// A hub with a simulator, attached to a model.
@MainActor
private func hubModel(machine: MachineOption = fastSim) async throws -> (AppModel, URL) {
    let dir = tempDir()
    let lib = try await Library.open(LibraryOptions(dataDir: dir.appending(path: "data"), root: dir.appending(path: "lib"), settleMs: 0))
    let inst = Instance(
        InstanceOptions(name: "Design", role: .hub, host: "127.0.0.1", port: 0, advertise: false, machine: machine, pollMs: 50), library: lib)
    let model = AppModel()
    try await model.attach(inst)
    return (model, dir)
}

private func item(_ id: String, folder: String = "", group: String? = nil, index: Int? = nil, added: Double = 0) -> LibraryItem {
    LibraryItem(
        id: id, name: "\(id).nc", folder: folder, source: "Upload", size: 10, sha256: "", addedAt: added, sourceLines: 1, streamLines: 1,
        bounds: Bounds(min: Vec3(0, 0, -12.5), max: Vec3(220, 180, 0)), cutBounds: nil, estSeconds: 60, group: group, groupIndex: index)
}

@Suite struct Helpers {
    @Test func tree() {
        let folders = ["", "Guitars", "Guitars/Tele", "Guitars/Strat", "Jigs"]
        #expect(childFolders(folders, "") == ["Guitars", "Jigs"])
        #expect(childFolders(folders, "Guitars") == ["Guitars/Strat", "Guitars/Tele"])
        let lib = [item("a", folder: "Guitars", added: 1), item("b", folder: "Guitars/Tele"), item("c", folder: "Jigs")]
        #expect(countIn(lib, "Guitars") == 2)
        #expect(baseName("Guitars/Tele") == "Tele")
        #expect(parentOf("Guitars/Tele") == "Guitars")
        #expect(parentOf("Guitars") == "")
    }

    @Test func groupsInRunOrderOthersNewestFirst() {
        let lib = [item("old", added: 1), item("g2", group: "Body", index: 1, added: 5), item("new", added: 9), item("g1", group: "Body", index: 0, added: 5)]
        let ids = filesIn(lib, "").map(\.id)
        #expect(ids.firstIndex(of: "g1")! < ids.firstIndex(of: "g2")!)
        #expect(ids.firstIndex(of: "new")! < ids.firstIndex(of: "old")!)
    }

    @Test func sizes() {
        #expect(dims(item("a")) == "220×180×12.5")
    }

    @Test func hubAddress() {
        var s = AppSetup(role: .agent, name: "Garage", machine: .usb, hubAddress: "", trial: true)
        #expect(s.hubURL == nil)
        s.hubAddress = "design.local"
        #expect(s.hubURL?.absoluteString == "ws://design.local:\(defaultHubPort + 1)/link")
        s.hubAddress = "10.0.0.2:9000"
        #expect(s.hubURL?.absoluteString == "ws://10.0.0.2:9000/link")
        s.trial = false
        s.hubAddress = "design.local"
        #expect(s.hubURL?.absoluteString == "ws://design.local:\(defaultHubPort)/link")
    }

    @Test func trialKeepsAwayFrom1() {
        let trial = AppSetup(role: .hub, name: "Design", machine: .none, trial: true)
        let real = AppSetup(role: .hub, name: "Design", machine: .none, trial: false)
        #expect(trial.port != real.port)
        #expect(trial.serviceType != real.serviceType)
        #expect(trial.libraryRoot != real.libraryRoot)
        #expect(trial.dataDir != real.dataDir)
        #expect(trial.instanceOptions.serviceType == trial.serviceType)
        #expect(AppSetup(role: .agent, name: "G", machine: .usb).v1 == nil)
    }

    @Test func setupRoundTrips() {
        let d = UserDefaults(suiteName: "sg-ui-tests-\(UUID().uuidString)")!
        #expect(AppSetup.load(d) == nil)
        let s = AppSetup(role: .agent, name: "Garage", machine: .simulator, hubAddress: "x", trial: false)
        s.save(d)
        #expect(AppSetup.load(d) == s)
    }

    @Test func nextGroupFile() {
        var s = AppState(
            link: LinkState(hubConnected: true, agentConnected: false, via: .hub), machine: MachineState(), job: JobState(), library: [],
            folders: [], libraryRoot: nil, macros: [], config: .defaults, console: [])
        #expect(s.nextGroupFile == nil)
        s.job.status = .toolchange
        s.job.group = JobGroup(name: "Body", files: [GroupFile(id: "1", name: "a.nc"), GroupFile(id: "2", name: "b.nc")], index: 0)
        #expect(s.nextGroupFile == NextFile(id: "2", name: "b.nc", index: 1, total: 2))
        #expect(!s.jobActive)
        s.job.group?.index = 1
        #expect(s.nextGroupFile == nil)
        #expect(s.startHint(selected: nil) == "Machine not connected")
        s.machine.connection = .connected
        s.machine.status = .idle
        #expect(s.startHint(selected: nil) == "Select a file in the library")
        #expect(s.startHint(selected: item("a")) == nil)
        #expect(s.canJog)
    }
}

@Suite(.serialized) @MainActor struct Model {
    @Test func followsTheMachine() async throws {
        let (model, _) = try await hubModel()
        defer { Task { await model.shutdown() } }
        #expect(model.state != nil)
        #expect(model.jogFeedXY == MachineConfig.defaults.jogFeedXY)
        await model.run(.connect(port: nil))
        #expect(await until { model.state?.machineReady == true && model.state?.machine.status == .idle })
        #expect(model.state?.link.machineOn == "Design")

        model.jogStep = 10
        model.jog(-1, 0, 0)
        #expect(await until { (model.state?.machine.wpos.x ?? 0) <= -9.99 && model.state?.machine.status == .idle })
    }

    @Test func refusalsBecomeToasts() async throws {
        let (model, _) = try await hubModel(machine: .none)
        defer { Task { await model.shutdown() } }
        let ok = await model.run(.home)
        #expect(!ok)
        #expect(model.toasts.count == 1)
        #expect(model.toasts.first?.level == .error)
        model.dismiss(model.toasts[0].id)
        #expect(model.toasts.isEmpty)
    }

    @Test func uploadAndTrash() async throws {
        let (model, dir) = try await hubModel(machine: .none)
        defer { Task { await model.shutdown() } }
        let file = dir.appending(path: "part.nc")
        try gcode().write(to: file)
        let junk = dir.appending(path: "empty.nc")
        try Data().write(to: junk)
        await model.run(.createFolder(path: "Jigs"))
        await model.upload([file, junk], folder: "Jigs")
        #expect(model.state?.library.map(\.name) == ["part.nc"])
        #expect(model.state?.library.first?.folder == "Jigs")
        #expect(model.toasts.contains { $0.text == "empty.nc: The file is empty" })

        let id = try #require(model.state?.library.first?.id)
        model.previewId = id
        #expect(model.selected?.name == "part.nc")
        await model.run(.deleteFile(fileId: id))
        #expect(model.state?.library.isEmpty == true)
        await model.refreshTrash()
        #expect(model.trash.map(\.item.id) == [id])
        await model.library { try await $0.restore(id) }
        #expect(model.state?.library.map(\.id) == [id])
        #expect(model.trash.isEmpty)
    }

    @Test func runsAJob() async throws {
        let (model, dir) = try await hubModel()
        defer { Task { await model.shutdown() } }
        await model.run(.connect(port: nil))
        #expect(await until { model.state?.machine.status == .idle })
        let file = dir.appending(path: "job.nc")
        try gcode(20).write(to: file)
        await model.upload([file])
        let id = try #require(model.state?.library.first?.id)
        #expect(model.state?.startHint(selected: model.state?.library.first) == nil)
        #expect(await model.run(.start(fileId: id, group: nil, fromLine: nil)))
        let done = await until { model.state?.job.status == .done }
        #expect(done, "\(String(describing: model.state?.job)) \(String(describing: model.state?.machine)) \(String(describing: model.state?.console.map { "\($0.dir) \($0.text)" }.suffix(30)))")
        #expect(!model.jobRunningHere)
    }
}
