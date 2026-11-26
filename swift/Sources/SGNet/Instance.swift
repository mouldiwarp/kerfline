// One running copy of the app: the library, a MachineSession, and the link to the other Mac.
//
// Hub: serves the HTTP API (SwarfPath, Fretboard, curl) and /link, advertises with Bonjour, and
// watches the inbox. Agent: dials the hub's /link (found with Bonjour unless given), redialling
// every couple of seconds. Otherwise the two are the same.
//
// Whichever Mac has the FoxAlien on USB owns it: its MachineSession streams jobs from its own copy
// of the library, and the other Mac mirrors its machine, job and console and relays commands to it.
// Library commands always apply to the local library; sync carries them across.

import Foundation
import SGCore
import SGLibrary
import SGMachine
import HummingbirdWSClient
import Logging

public enum MachineOption: Sendable {
    /// No machine on this Mac.
    case none
    case simulator(FakeGrblOptions)
    /// A USB serial port; nil finds the GRBL controller.
    case serial(path: String?)
}

public struct InstanceOptions: Sendable {
    public var name: String
    public var role: Role
    /// Hub: the address and port to listen on (0 picks a free port).
    public var host: String
    public var port: Int
    /// Hub: advertise on Bonjour.
    public var advertise: Bool
    /// The Bonjour service the hub advertises and the agent looks for (a trial run alongside 1.0
    /// uses its own, so SwarfPath keeps finding 1.0).
    public var serviceType: String
    /// Agent: the hub, e.g. ws://hub.local:8080/link; nil finds it with Bonjour.
    public var hubURL: URL?
    public var machine: MachineOption
    /// Hub: the inbox folder to watch.
    public var inbox: URL?
    public var pollMs: Int
    /// Agent: seconds between attempts to reach the hub.
    public var redialSeconds: Double
    /// Seconds between attempts to reconnect a machine that dropped off USB.
    public var reconnectSeconds: Double
    /// How long a relayed command may take.
    public var relayTimeout: Double
    /// The code this app runs, sent to the other Mac.
    public var code: CodeVersion?

    public init(
        name: String, role: Role, host: String = "0.0.0.0", port: Int = defaultHubPort, advertise: Bool = true, serviceType: String = hubServiceType, hubURL: URL? = nil,
        machine: MachineOption = .serial(path: nil), inbox: URL? = nil, pollMs: Int = 150, redialSeconds: Double = 2,
        reconnectSeconds: Double = 3, relayTimeout: Double = 30, code: CodeVersion? = nil
    ) {
        self.code = code
        self.name = name
        self.role = role
        self.host = host
        self.port = port
        self.advertise = advertise
        self.serviceType = serviceType
        self.hubURL = hubURL
        self.machine = machine
        self.inbox = inbox
        self.pollMs = pollMs
        self.redialSeconds = redialSeconds
        self.reconnectSeconds = reconnectSeconds
        self.relayTimeout = relayTimeout
    }
}

public enum InstanceEvent: Sendable {
    /// Something on screen changed (machine, job, console, library or link).
    case changed
    case toast(Toast)
}

public actor Instance {
    public let options: InstanceOptions
    public nonisolated let library: Library
    public nonisolated let session: MachineSession
    /// Hub: the port it's listening on, once started.
    public private(set) var port: Int?

    private var link: LinkConnection?
    private var peer: Hello?
    private var peerView: MachineView?
    private var sync: LibrarySync?
    private var pending: [String: CheckedContinuation<CommandResult, Never>] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var inbox: Inbox?
    private var advert: BonjourAdvert?
    private var browser: BonjourBrowser?
    private var foundHub: FoundHub?
    private var autoConnect = false
    /// The running job's content (a whole group's, from the start), taken when it started so sync
    /// can't change it mid-run; the shas are pinned in the library until the job ends.
    private var jobContent: [String: Data] = [:]
    private var jobPins: [String] = []
    private var subscribers: [UUID: AsyncStream<InstanceEvent>.Continuation] = [:]

    public init(_ options: InstanceOptions, library: Library) {
        self.options = options
        self.library = library
        var simulated = false
        if case .simulator = options.machine { simulated = true }
        session = MachineSession(pollMs: options.pollMs, simulated: simulated)
    }

    // MARK: Lifecycle

    public func start() async throws {
        await session.setConfig(await library.config())
        await session.setMacros(await library.macros())
        let sessionEvents = await session.events()
        tasks.append(Task { [weak self] in
            for await e in sessionEvents { await self?.sessionEvent(e) }
        })
        let libraryEvents = await library.events()
        tasks.append(Task { [weak self] in
            for await _ in libraryEvents { await self?.libraryChanged() }
        })
        tasks.append(Task { [weak self, s = options.reconnectSeconds] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(s))
                await self?.reconnectIfDropped()
            }
        })
        switch options.role {
        case .hub:
            try await startServer()
            if options.advertise, let port { advert = BonjourAdvert(name: options.name, port: port, type: options.serviceType) }
            if let dir = options.inbox {
                let inbox = Inbox(dir, onFile: { [weak self] name, data in
                    guard let self else { return }
                    let item = try await self.library.add(data, AddOptions(name: name, source: "Inbox"))
                    await self.notify(.info, "Imported \(item.name) from the inbox")
                }, onError: { [weak self] name, error in
                    await self?.notify(.error, "Could not import \(name): \(error.localizedDescription)")
                })
                await inbox.start()
                self.inbox = inbox
            }
        case .agent:
            if options.hubURL == nil {
                let browser = BonjourBrowser(type: options.serviceType, onFound: { [weak self] hub in
                    Task { await self?.found(hub) }
                })
                browser.start()
                self.browser = browser
            }
            tasks.append(Task { [weak self] in await self?.dialLoop() })
        }
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        advert?.stop()
        advert = nil
        browser?.stop()
        browser = nil
        await inbox?.stop()
        inbox = nil
        link?.close()
        if let link { detached(link) }
        autoConnect = false
        await session.disconnect()
        releasePins()
        for c in subscribers.values { c.finish() }
        subscribers = [:]
    }

    /// What happens here, for the window.
    public func events() -> AsyncStream<InstanceEvent> {
        let (stream, c) = AsyncStream.makeStream(of: InstanceEvent.self, bufferingPolicy: .bufferingNewest(100))
        let id = UUID()
        subscribers[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ e: InstanceEvent) {
        for c in subscribers.values { c.yield(e) }
    }

    /// Show a notification on both Macs.
    /// Starts updating this Mac (returns once it's under way; throws if it can't start).
    private var updater: (@Sendable () async throws -> Void)?

    public func setUpdater(_ f: (@Sendable () async throws -> Void)?) { updater = f }

    /// A message on both Macs.
    public func announce(_ level: Toast.Level, _ text: String) { notify(level, text) }

    func notify(_ level: Toast.Level, _ text: String) {
        let t = Toast(level, text)
        emit(.toast(t))
        link?.send(.toast(t))
    }

    // MARK: State

    /// The other Mac's name, while linked.
    public var peerName: String? { peer?.name }
    public var isLinked: Bool { peer != nil }

    /// Where the machine is: this Mac, the other one, or nowhere.
    public enum Owner: Sendable, Equatable {
        case here, peer(String), none
    }

    public func owner() async -> Owner {
        if await session.machine.connection != .disconnected { return .here }
        if let peer, peerView?.hasMachine == true { return .peer(peer.name) }
        return .none
    }

    /// The machine as shown here: the owner's.
    public func machineView() async -> MachineView {
        if case .peer = await owner(), let peerView { return peerView }
        return MachineView(machine: await session.machine, job: await session.job, console: await session.console)
    }

    public func state() async -> AppState {
        let view = await machineView()
        let linked = peer != nil
        let machineOn: String? =
            switch await owner() {
            case .here: options.name
            case .peer(let name): name
            case .none: nil
            }
        let link = LinkState(
            hubConnected: options.role == .hub || linked, agentConnected: options.role == .agent || linked, via: options.role,
            hubName: options.role == .hub ? options.name : peer?.name, agentName: options.role == .agent ? options.name : peer?.name,
            machineOn: machineOn, peerCode: peer?.code)
        return AppState(
            link: link, machine: view.machine, job: view.job, library: await library.items(), folders: await library.folders(),
            libraryRoot: library.root.path, macros: await library.macros(), config: await library.config(), console: view.console)
    }

    // MARK: Uploads

    /// A file from SwarfPath, Fretboard or curl (POST /api/jobs).
    public func upload(_ data: Data, _ o: AddOptions) async throws -> LibraryItem {
        let item = try await library.add(data, o)
        notify(.info, "Received \(item.name)\(item.source != "Upload" ? " from \(item.source)" : "")")
        return item
    }

    // MARK: Commands

    /// Run a command from this Mac's window (or its HTTP API). Throws with a user-facing message.
    public func execute(_ cmd: Command, by: String) async throws {
        try await perform(cmd, by: by, relayed: false)
    }

    private func perform(_ cmd: Command, by: String, relayed: Bool) async throws {
        if cmd.isLibraryCommand {
            try await libraryCommand(cmd)
            return
        }
        if case .update(let target) = cmd {
            // Update this Mac, or ask the other one to update itself.
            if target.rawValue == options.role.rawValue || relayed {
                guard let updater else { throw MachineError("\(options.name) can't update itself") }
                try await updater()
            } else {
                try await relay(cmd, by: by)
            }
            return
        }
        switch await owner() {
        case .here:
            try await local(cmd, by: by)
        case .peer(let name):
            if case .connect = cmd { throw MachineError("The machine is connected to \(name). Disconnect it there first") }
            // A command relayed from the other Mac runs here even if it thinks this Mac owns it.
            if relayed { try await local(cmd, by: by) } else { try await relay(cmd, by: by) }
        case .none:
            if case .connect(let port) = cmd, !relayed, peer != nil, !canConnectHere(port) {
                try await relay(cmd, by: by)
            } else {
                try await local(cmd, by: by)
            }
        }
    }

    private func libraryCommand(_ cmd: Command) async throws {
        switch cmd {
        case .deleteFile(let id):
            let view = await machineView()
            if view.job.fileId == id, [.loading, .running, .paused, .stopping].contains(view.job.status) {
                throw MachineError("Can't delete the file that is running")
            }
            try await library.delete(id)
        case .renameFile(let id, let name): try await library.renameFile(id, name)
        case .moveFile(let id, let folder): try await library.moveFile(id, to: folder)
        case .createFolder(let path): try await library.createFolder(path)
        case .renameFolder(let path, let to): try await library.renameFolder(path, to: to)
        case .deleteFolder(let path): try await library.deleteFolder(path)
        case .saveMacro(let m): try await library.saveMacro(m)
        case .deleteMacro(let id): try await library.deleteMacro(id)
        case .saveConfig(let patch): _ = try await library.saveConfig(patch)
        default: break
        }
    }

    private func relay(_ cmd: Command, by: String) async throws {
        guard let link, let peer else { throw MachineError("The other Mac is not connected") }
        let id = randomId()
        let timeout = options.relayTimeout
        let result = await withCheckedContinuation { (c: CheckedContinuation<CommandResult, Never>) in
            pending[id] = c
            link.send(.cmd(id: id, command: cmd, by: by))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.answer(id, .failure("\(peer.name) did not answer"))
            }
        }
        if !result.ok { throw MachineError(result.error ?? "Command failed") }
    }

    private func answer(_ id: String, _ r: CommandResult) {
        pending.removeValue(forKey: id)?.resume(returning: r)
    }

    /// Run a machine command on this Mac's session.
    private func local(_ cmd: Command, by: String) async throws {
        switch cmd {
        case .connect(let port):
            try await connectHere(port)
        case .disconnect:
            if await session.isJobActive { throw MachineError("Can't disconnect while a job is running") }
            autoConnect = false
            await session.disconnect()
        case .start(let fileId, let group, let fromLine, let spindleOff):
            try await startJob(fileId, runGroup: group == true, fromLine: fromLine, spindleOff: spindleOff == true, by: by)
        case .startNext:
            try await startNext(by: by)
        default:
            try await session.command(cmd, by: by)
        }
    }

    // MARK: The machine on this Mac

    private func canConnectHere(_ port: String?) -> Bool {
        switch options.machine {
        case .none: false
        case .simulator: true
        case .serial(let path): port != nil || path != nil || autoDetectPort() != nil
        }
    }

    private func transport(_ port: String?) throws -> any Transport {
        switch options.machine {
        case .none:
            throw MachineError("No USB GRBL controller found")
        case .simulator(let o):
            return FakeGrbl(o)
        case .serial(let path):
            guard let p = port ?? path ?? autoDetectPort() else { throw MachineError("No USB GRBL controller found") }
            return SerialPort(p)
        }
    }

    private func connectHere(_ port: String?) async throws {
        autoConnect = true
        let t = try transport(port)
        do {
            try await session.connect(t)
        } catch {
            throw MachineError("Could not connect to the machine: \(error.localizedDescription)")
        }
    }

    /// The machine dropped off USB (or wasn't there yet): try again, unless the other Mac has it.
    private func reconnectIfDropped() async {
        guard autoConnect, await owner() == .none, canConnectHere(nil) else { return }
        try? await connectHere(nil)
    }

    // MARK: Jobs (always from this Mac's library)

    private func startJob(_ fileId: String, runGroup: Bool, fromLine: Int?, spindleOff: Bool, by: String) async throws {
        if await session.job.status == .toolchange {
            throw MachineError("A group is waiting for a bit change. Use Start next, or End group first")
        }
        try await session.checkCanStart()
        guard let item = await library.item(fileId) else { throw MachineError("That file is not in the library") }
        var group: JobGroup?
        var files = [item]
        if runGroup, let name = item.group {
            let all = await library.items().filter { $0.group == name }.sorted { ($0.groupIndex ?? 0) < ($1.groupIndex ?? 0) }
            if let index = all.firstIndex(where: { $0.id == item.id }), index < all.count - 1 {
                group = JobGroup(name: name, files: all.map { GroupFile(id: $0.id, name: $0.name) }, index: index)
                files = Array(all[index...])
            }
        }
        releasePins()
        try await load(item, files, by: by, group: group, fromLine: fromLine, spindleOff: spindleOff)
    }

    /// After a bit change: the next file of the group, as it was when the group started.
    private func startNext(by: String) async throws {
        let job = await session.job
        guard job.status == .toolchange, var g = job.group, g.index + 1 < g.files.count else {
            throw MachineError("No group is waiting for the next file")
        }
        try await session.checkCanStart()
        let next = g.files[g.index + 1]
        guard let item = await library.item(next.id) else { throw MachineError("\(next.name) is no longer in the library") }
        g.index += 1
        // The whole group was checked for spindle-off cuts when it started.
        try await load(item, [item], by: by, group: g, fromLine: nil, spindleOff: true)
    }

    /// `spindleOff`: the user confirmed running files that cut with the spindle off; otherwise they're refused.
    private func load(_ item: LibraryItem, _ files: [LibraryItem], by: String, group: JobGroup?, fromLine: Int?, spindleOff: Bool) async throws {
        let previous = await session.job
        await session.markLoading(fileId: item.id, fileName: item.name, by: by)
        func fail(_ error: Error) async -> Error {
            if previous.status == .toolchange {
                await session.restoreJob(previous)
            } else {
                await session.cancelLoading(error.localizedDescription)
            }
            return error
        }
        var text = ""
        for f in files {
            let data: Data
            if let held = jobContent[f.id] {
                data = held
            } else {
                guard let d = await library.content(sha: f.sha256) else {
                    let from = peer.map { " from \($0.name)" } ?? ""
                    throw await fail(MachineError("\(f.name) hasn't arrived\(from) yet"))
                }
                await library.pin(f.sha256)
                jobPins.append(f.sha256)
                jobContent[f.id] = d
                data = d
            }
            if f.id == item.id { text = String(decoding: data, as: UTF8.self) }
            if !spindleOff {
                let t = f.id == item.id ? text : String(decoding: data, as: UTF8.self)
                let from = f.id == item.id ? fromLine.flatMap { i in streamableLines(t).dropFirst(i).first?.source } ?? 0 : 0
                if let line = spindleOffCut(t, from: from) {
                    throw await fail(MachineError(spindleOffMessage(f.name, line)))
                }
            }
        }
        // The machine could have changed state while loading.
        do {
            try await session.checkCanStart(loading: true)
            try await session.checkFitsTravel(item.bounds)
        } catch {
            throw await fail(error)
        }
        do {
            try await session.startJob(
                text, MachineSession.JobMeta(fileId: item.id, fileName: item.name, by: by, estSeconds: item.estSeconds, group: group, fromLine: fromLine))
        } catch {
            await session.cancelLoading(error.localizedDescription)
            throw error
        }
    }

    private func releasePins() {
        let pins = jobPins
        jobPins = []
        jobContent = [:]
        let library = self.library
        Task { for sha in pins { await library.unpin(sha) } }
    }

    // MARK: Events

    private func sessionEvent(_ e: SessionEvent) async {
        switch e {
        case .machine(let m):
            link?.send(.machine(m))
        case .job(let j):
            link?.send(.job(j))
            // Look at the job now, not this (possibly stale) event: a new job may have started.
            let now = await session.job.status
            if ![.loading, .running, .paused, .stopping, .toolchange].contains(now), !jobPins.isEmpty { releasePins() }
        case .console(let lines):
            link?.send(.console(lines))
        case .toast(let t):
            emit(.toast(t))
            link?.send(.toast(t))
            return
        }
        emit(.changed)
    }

    private func libraryChanged() async {
        await session.setConfig(await library.config())
        await session.setMacros(await library.macros())
        emit(.changed)
    }

    // MARK: The link

    /// A link came up (the hub accepted one, or the agent's dial connected).
    func attached(_ conn: LinkConnection) async {
        if let old = link {
            old.close()
            detached(old)
        }
        link = conn
        conn.send(.hello(Hello(name: options.name, role: options.role, version: linkProtocolVersion, replica: library.replica, code: options.code)))
        conn.send(.snapshot(MachineView(machine: await session.machine, job: await session.job, console: await session.console)))
    }

    func detached(_ conn: LinkConnection) {
        guard link?.id == conn.id else { return }
        let name = peer?.name ?? "the other Mac"
        link = nil
        peer = nil
        peerView = nil
        let s = sync
        sync = nil
        Task { await s?.stop() }
        for (_, c) in pending { c.resume(returning: .failure("Lost the link to \(name)")) }
        pending = [:]
        emit(.changed)
    }

    func received(_ m: LinkMessage, on conn: LinkConnection) async {
        guard link?.id == conn.id else { return }
        switch m {
        case .hello(let h):
            if h.version != linkProtocolVersion {
                emit(.toast(Toast(.error, "\(h.name) runs a different version of SwarfGRBL. Update both Macs")))
                conn.close()
                return
            }
            if h.replica == library.replica || h.role == options.role {
                conn.close()
                return
            }
            peer = h
            let s = LibrarySync(library: library, peerName: h.name) { [weak conn] m in conn?.send(.sync(m)) }
            sync = s
            await s.start()
        case .snapshot(let v):
            peerView = v
        case .machine(let machine):
            if peerView == nil { peerView = MachineView(machine: machine) } else { peerView?.machine = machine }
        case .job(let job):
            peerView?.job = job
        case .console(let lines):
            peerView?.console.append(contentsOf: lines)
            if let n = peerView?.console.count, n > 500 { peerView?.console.removeFirst(n - 500) }
        case .cmd(let id, let command, let by):
            // Not awaited here, so a long command (homing) can't hold up a Stop behind it.
            Task {
                var result = CommandResult.success
                do {
                    try await self.perform(command, by: by, relayed: true)
                } catch {
                    result = .failure(error.localizedDescription)
                }
                conn.send(.result(id: id, result: result))
            }
            return
        case .result(let id, let result):
            answer(id, result)
            return
        case .toast(let t):
            emit(.toast(t))
            return
        case .sync(let s):
            sync?.receive(s)
            return
        }
        emit(.changed)
    }

    // MARK: Agent: reaching the hub

    private func found(_ hub: FoundHub) {
        // 1.0 hubs advertise version 1 and have no /link.
        guard hub.name != options.name, hub.version == linkProtocolVersion else { return }
        foundHub = hub
    }

    private func hubURL() -> URL? {
        if let url = options.hubURL { return url }
        guard let hub = foundHub else { return nil }
        return URL(string: "ws://\(hub.host):\(hub.port)/link")
    }

    private func dialLoop() async {
        let logger = Logger(label: "swarfgrbl.link")
        while !Task.isCancelled {
            if let url = hubURL() {
                let conn = LinkConnection()
                _ = try? await WebSocketClient.connect(
                    url: url.absoluteString, configuration: WebSocketClientConfiguration(maxFrameSize: linkMaxFrame), logger: logger
                ) { inbound, outbound, _ in
                    await self.attached(conn)
                    await conn.run(inbound: inbound, outbound: outbound) { m in await self.received(m, on: conn) }
                    await self.detached(conn)
                }
                await detached(conn)
            }
            try? await Task.sleep(for: .seconds(options.redialSeconds))
        }
    }

    // MARK: Hub: the server

    private func startServer() async throws {
        let (portStream, portCont) = AsyncStream.makeStream(of: Int.self)
        let app = makeHubApplication(instance: self, host: options.host, port: options.port) { port in
            portCont.yield(port)
            portCont.finish()
        }
        tasks.append(Task {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {}
            portCont.finish()
        })
        var it = portStream.makeAsyncIterator()
        guard let p = await it.next() else {
            throw MachineError("Could not listen on port \(options.port). Is another copy of SwarfGRBL running?")
        }
        port = p
    }
}
