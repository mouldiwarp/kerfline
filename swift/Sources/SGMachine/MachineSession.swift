// MachineSession: owns one Transport and turns it into machine state, job state and a console log.
// Port of packages/agent/src/controller.ts (GrblController).
//
// Lines are streamed with GRBL's character-counting protocol: the sum of unacknowledged line
// lengths never exceeds the controller's RX buffer, so GRBL always has the next lines queued
// without overflowing.
//
// An actor: incoming bytes, timers and commands all run on it one at a time. Commands that wait
// for GRBL's reply suspend, so replies (and Hold/Stop) keep being handled while they wait.

import Foundation
import SGCore

public struct Toast: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warn, error }
    public var level: Level
    public var text: String
    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

public enum SessionEvent: Sendable {
    case machine(MachineState)
    case job(JobState)
    case console([ConsoleLine])
    case toast(Toast)
}

public struct AckResult: Sendable {
    public var ok: Bool
    public var error: String?
}

private enum LineKind { case job, user, `internal` }

private struct QueuedLine {
    var text: String
    var kind: LineKind
    var source: Int?
    var by: String?
    /// Echo responses to the console (user commands).
    var echo: Bool
    var resolve: ((AckResult) -> Void)?
    /// When it was written to the controller (ms).
    var sentAt: Double?
}

private let consoleMax = 500
nonisolated(unsafe) private let dwellRegex = try! Regex(#"G0?4(?![\d.])"#).ignoresCase()
nonisolated(unsafe) private let prbRegex = try! Regex(#"^\[PRB:([-\d.]+),([-\d.]+),([-\d.]+)(?:,[-\d.]+)*:(\d)\]$"#)
nonisolated(unsafe) private let settingLine = try! Regex(#"^\$(\d+)=(.*)$"#)

public actor MachineSession {
    public private(set) var machine: MachineState
    public private(set) var job = JobState()
    /// A `pauseLift` is stopping the job (so finishing it says "paused", not "stopped").
    private var pausing = false
    public private(set) var console: [ConsoleLine] = []
    public var config: MachineConfig?
    public var macros: [Macro] = []

    private let pollMs: Int
    private var transport: (any Transport)?
    private var reader: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var welcomeTask: Task<Void, Never>?
    private var jobEmitTask: Task<Void, Never>?
    private var consoleTask: Task<Void, Never>?

    private var rxBytes: [UInt8] = []
    private var queue: [QueuedLine] = []
    private var inflight: [QueuedLine] = []
    private var inflightBytes = 0
    private var rxSize = 128
    private var jobLines: [StreamLine] = []
    /// Job lines (preamble included) GRBL has acknowledged in this run.
    private var jobAcked = 0
    /// Preamble lines at the front of jobLines (a resume).
    private var jobPreamble = 0
    /// Latest buffer report, to tell which line the cutter is on.
    private var lastBuf: BufferState?
    /// Estimated time per line of the running program, for progress.
    private var progress: ProgressModel?
    /// GRBL's distance modes, for working out where typed commands go.
    private var modes = DistanceModes()
    /// jobAcked when that buffer report arrived.
    private var jobAckedAtStatus = 0
    private var jobCursor = 0
    /// Stop feeding job lines (pause-on-error). Hold alone keeps the buffer topped up.
    private var jobSuspended = false
    private var settingsDraft: [String: String]?
    private var draftId = 0
    private var lastWco = Vec3.zero
    private var pendingConsole: [ConsoleLine] = []
    /// Last `[PRB:x,y,z:ok]` report (machine coordinates).
    private var lastPrb: (pos: Vec3, ok: Bool)?
    /// Axes homed one at a time (`$HZ`…) since the position was last lost: all three make the machine homed.
    private var homedAxes: Set<Axis> = []
    /// Where the last full homing cycle left the machine (the pull-off point), for Home X/Y/Z on a GRBL that can't
    /// home one axis; and whether to record it from the next idle status report.
    private var homePosition: Vec3?
    private var captureHomePosition = false

    private func lostHome() {
        machine.homed = false
        homedAxes = []
    }
    private var lastAlarmCode: Int?
    private var lastSettingsAsk = 0.0
    private var maxRxFree = 0
    private var maxPlannerFree = 0
    /// Counts machine updates, so a wait can tell a fresh status report arrived.
    private var machineUpdates = 0
    /// Counts controller resets (banners), so a multi-step command can tell one happened between its steps.
    private var resets = 0

    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    public init(pollMs: Int = 150, simulated: Bool = false) {
        self.pollMs = pollMs
        machine = MachineState(simulated: simulated)
    }

    /// Machine, job, console and toast updates from now on.
    public func events() -> AsyncStream<SessionEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .bufferingNewest(1000))
        let id = UUID()
        subscribers[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ e: SessionEvent) {
        for c in subscribers.values { c.yield(e) }
    }

    public func setConfig(_ c: MachineConfig?) { config = c }
    public func setMacros(_ m: [Macro]) { macros = m }

    /// loading, running, paused or stopping (not a group waiting for its next file).
    public var isJobActive: Bool { [.loading, .running, .paused, .stopping].contains(job.status) }

    // MARK: Connection

    public func connect(_ t: any Transport) async throws {
        if transport != nil { await disconnect() }
        transport = t
        machine.connection = .connecting
        machine.port = t.name
        machine.simulated = t.simulated
        machine.firmware = nil
        machineChanged()
        let events = t.events
        reader = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                await self.handle(e, from: t)
            }
        }
        do {
            try await t.open()
        } catch {
            transport = nil
            reader?.cancel()
            machine.connection = .disconnected
            lostHome()
            machineChanged()
            log(.error, "Could not open \(t.name): \(error.localizedDescription)")
            throw error
        }
        log(.info, "Opened \(t.simulated ? "GRBL simulator" : t.name)")
        // An Arduino-based GRBL resets when the port opens and prints its banner.
        // grblHAL boards don't, so poke them with a soft reset if nothing arrives.
        welcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            await self?.pokeIfSilent()
        }
        let ms = pollMs
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(ms))
                await self?.poll()
            }
        }
    }

    private func pokeIfSilent() {
        if machine.connection == .connecting { realtime(RT.softReset) }
    }

    private func poll() {
        if machine.connection == .connected { realtime(RT.status) }
    }

    public func disconnect() async {
        let t = transport
        teardown()
        if let t { await t.close() }
        machine.connection = .disconnected
        machine.status = .unknown
        lostHome()
        machineChanged()
    }

    private func teardown() {
        pollTask?.cancel()
        welcomeTask?.cancel()
        pollTask = nil
        welcomeTask = nil
        transport = nil
        rxBytes = []
        flushBuffers("Disconnected")
        if isJobActive { failJob("Machine disconnected during the job") }
    }

    private func handle(_ e: TransportEvent, from t: any Transport) {
        guard let current = transport, current === t else { return }
        switch e {
        case .data(let bytes): onData(bytes)
        case .closed(let err): onTransportClosed(err)
        }
    }

    private func onTransportClosed(_ err: (any Error)?) {
        log(.error, "Connection closed\(err.map { ": \($0.localizedDescription)" } ?? "")")
        teardown()
        machine.connection = .disconnected
        machine.status = .unknown
        lostHome()
        machineChanged()
    }

    // MARK: Incoming data

    private func onData(_ bytes: [UInt8]) {
        rxBytes += bytes
        while let nl = rxBytes.firstIndex(of: UInt8(ascii: "\n")) {
            let line = latin1(rxBytes[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            rxBytes.removeSubrange(...nl)
            if !line.isEmpty { onLine(line) }
        }
    }

    private func onLine(_ line: String) {
        let r = classifyResponse(line)
        switch r.kind {
        case .status:
            if let s = r.status { onStatus(s) }
        case .ok, .error:
            onAck(r.kind == .ok, r.code, line)
        case .alarm:
            let code = r.code ?? 0
            let message = describeAlarm(code)
            lastAlarmCode = code
            log(.error, "\(line) \(message)")
            machine.status = .alarm
            machine.alarm = Alarm(code: code, message: message)
            lostHome()
            machineChanged()
            flushBuffers("Alarm")
            if isJobActive { failJob("ALARM:\(code) \(message)") }
        case .welcome:
            onWelcome(line)
        case .msg:
            log(.in, line)
        case .setting:
            if let m = line.wholeMatch(of: settingLine), let k = m.output[1].substring, let v = m.output[2].substring {
                if settingsDraft != nil {
                    settingsDraft?[String(k)] = String(v)
                } else {
                    // $$ typed in the console: keep the machine's settings up to date as well.
                    machine.settings = (machine.settings ?? [:]).merging([String(k): String(v)]) { $1 }
                    machineChanged()
                }
            }
            echoIfUser(line)
        case .feedback:
            if line.hasPrefix("[GC:") {
                machine.modal = String(line.dropFirst(4).dropLast())
                machineChanged()
                modes = modesFromModal(line)
            }
            if line.hasPrefix("[PRB:") {
                // X,Y,Z then any extra axes (FoxAlien's 4-axis GRBL adds A), then :1 for a contact.
                if let m = line.wholeMatch(of: prbRegex),
                   let x = Double(m.output[1].substring ?? ""), let y = Double(m.output[2].substring ?? ""),
                   let z = Double(m.output[3].substring ?? "") {
                    lastPrb = (Vec3(x, y, z), m.output[4].substring == "1")
                }
                log(.in, line)
                return
            }
            if line.hasPrefix("[VER:") {
                var v = String(line.dropFirst(5).dropLast())
                if v.hasSuffix(":") { v.removeLast() }
                machine.firmware = "GRBL \(v)"
                machineChanged()
            }
            if line.hasPrefix("[OPT:") {
                let parts = line.dropFirst(5).dropLast().split(separator: ",", omittingEmptySubsequences: false)
                if parts.count > 2, let rx = Int(parts[2]), rx > 0 { rxSize = rx }
                if let codes = parts.first {
                    machine.homeAxes = codes.contains("H")
                    machineChanged()
                }
            }
            echoIfUser(line)
        default:
            echoIfUser(line)
        }
    }

    private func echoIfUser(_ line: String) {
        if inflight.first.map({ $0.echo }) ?? true { log(.in, line) }
    }

    private func onWelcome(_ line: String) {
        welcomeTask?.cancel()
        resets += 1
        let wasConnecting = machine.connection == .connecting
        log(.in, line)
        // A banner means the controller reset: everything in flight is gone.
        flushBuffers("Controller reset")
        if job.status == .stopping {
            finishJob(.stopped)
        } else if isJobActive {
            failJob("The controller reset during the job")
        }
        machine.connection = .connected
        machine.firmware = line.range(of: "grblhal", options: .caseInsensitive) != nil ? "grblHAL" : (machine.firmware ?? "GRBL")
        machineChanged()
        if wasConnecting || (machine.settings ?? [:]).isEmpty {
            `internal`("$I")
            queryState()
        }
        realtime(RT.status)
    }

    private func queryState() {
        draftId += 1
        let id = draftId
        settingsDraft = [:]
        `internal`("$$") { [weak self] _ in
            guard let self else { return }
            self.assumeIsolated { $0.finishDraft(id) }
        }
        `internal`("$G")
    }

    private func finishDraft(_ id: Int) {
        guard id == draftId, let draft = settingsDraft else { return }
        // Interrupted (a reset) before any settings arrived: leave them unread so they're asked for again.
        if !draft.isEmpty {
            machine.settings = (machine.settings ?? [:]).merging(draft) { $1 }
            machineChanged()
        }
        settingsDraft = nil
    }

    private func onStatus(_ s: StatusReport) {
        machine.status = s.state
        machine.subState = s.subState
        if let wco = s.wco { lastWco = wco }
        if let mpos = s.mpos {
            machine.mpos = mpos
            machine.wpos = mpos - lastWco
        } else if let wpos = s.wpos {
            machine.wpos = wpos
            machine.mpos = wpos + lastWco
        }
        machine.wco = lastWco
        if captureHomePosition, s.state == .idle {
            homePosition = machine.mpos
            captureHomePosition = false
        }
        if let f = s.feed { machine.feed = f }
        if let sp = s.spindle { machine.spindle = sp }
        if let ov = s.overrides { machine.overrides = ov }
        // Some boards refuse $$ in the alarm state they boot into: read the settings once idle.
        if s.state == .idle, machine.connection == .connected, settingsDraft == nil, (machine.settings ?? [:]).isEmpty,
           nowMs() - lastSettingsAsk > 5000 {
            lastSettingsAsk = nowMs()
            Task { self.queryState() }
        }
        if let buf = s.buffer {
            machine.buffer = buf
            lastBuf = buf
            // GRBL sends replies in order, so this report counts exactly the lines acknowledged so far.
            jobAckedAtStatus = jobAcked
            checkForLostReplies(s.state, buf)
            if job.status == .running || job.status == .paused { trackProgress(machine.wpos) }
        }
        machine.pins = s.pins
        machine.accessories = s.accessories
        if s.state != .alarm { machine.alarm = nil }
        // Booting into ALARM (homing required): the position can't be trusted until homed.
        if s.state == .alarm && machine.homed == true { lostHome() }
        if machine.connection == .connecting {
            // Boards that don't reset when the port opens (no banner) come up through a status
            // report instead: ask for the build info and settings here too.
            machine.connection = .connected
            welcomeTask?.cancel()
            Task {
                self.internal("$I")
                self.queryState()
            }
        }
        machineChanged()

        // GRBL ignores feed hold while Idle, so a hold pressed just before motion starts can be
        // lost. If we think the job is paused but GRBL is running, hold again.
        if (job.status == .paused || job.status == .stopping) && s.state == .run { realtime(RT.feedHold) }

        // A job is finished once every line is acknowledged and the machine is idle.
        if job.status == .running, jobCursor >= jobLines.count, !inflight.contains(where: { $0.kind == .job }), s.state == .idle {
            finishJob(.done)
        }
    }

    private func onAck(_ ok: Bool, _ code: Int?, _ raw: String) {
        guard !inflight.isEmpty else {
            if !ok { log(.error, "\(raw) \(describeError(code ?? 0))") }
            return
        }
        let item = inflight.removeFirst()
        inflightBytes -= item.text.utf8.count + 1
        let errorText = ok ? nil : "\(raw): \(describeError(code ?? 0))"

        if item.kind == .job {
            jobAcked += 1
            let preamble = item.source == -1
            if !preamble {
                job.ackedLines += 1
                job.sourceLine = item.source ?? job.sourceLine
            }
            if let errorText {
                let at = preamble ? "Set-up move" : "Line \((item.source ?? 0) + 1)"
                log(.error, "\(at) \"\(item.text)\" → \(errorText)")
                pauseOnError("\(at) (\(item.text)) → \(errorText)")
            }
            scheduleJobEmit()
        } else {
            if item.echo { log(ok ? .in : .error, errorText ?? "ok") }
            if !ok && item.kind == .user {
                machine.lastError = CommandError(code: code ?? 0, message: describeError(code ?? 0), line: item.text)
                machineChanged()
            }
        }
        item.resolve?(AckResult(ok: ok, error: errorText))
        pump()
    }

    // MARK: Streaming

    private func pump() {
        guard let t = transport, machine.connection == .connected else { return }
        while true {
            var next: QueuedLine
            var fromJob = false
            if let q = queue.first {
                next = q
            } else if (job.status == .running || job.status == .paused) && !jobSuspended && jobCursor < jobLines.count {
                let l = jobLines[jobCursor]
                next = QueuedLine(text: l.text, kind: .job, source: l.source, echo: false)
                fromJob = true
            } else {
                return
            }
            let len = next.text.utf8.count + 1
            if !inflight.isEmpty && inflightBytes + len > rxSize { return }
            if fromJob { jobCursor += 1 } else { queue.removeFirst() }
            next.sentAt = nowMs()
            inflight.append(next)
            inflightBytes += len
            t.write(next.text + "\n")
        }
    }

    private func enqueue(_ line: QueuedLine) async -> AckResult {
        await withCheckedContinuation { (c: CheckedContinuation<AckResult, Never>) in
            enqueue(line) { c.resume(returning: $0) }
        }
    }

    private func enqueue(_ line: QueuedLine, then done: @escaping (AckResult) -> Void) {
        guard transport != nil, machine.connection == .connected else {
            return done(AckResult(ok: false, error: "The machine is not connected"))
        }
        var l = line
        l.resolve = done
        queue.append(l)
        pump()
    }

    private func `internal`(_ text: String, _ done: ((AckResult) -> Void)? = nil) {
        enqueue(QueuedLine(text: text, kind: .internal, echo: false)) { done?($0) }
    }

    private func user(_ text: String, by: String?) async -> AckResult {
        log(.out, text, by: by)
        return await enqueue(QueuedLine(text: text, kind: .user, by: by, echo: true))
    }

    private func flushBuffers(_ reason: String) {
        let pending = inflight + queue
        inflight = []
        queue = []
        inflightBytes = 0
        for p in pending { p.resolve?(AckResult(ok: false, error: reason)) }
    }

    /// GRBL answers every line with ok or error, so the lines waiting for a reply should be the
    /// ones still in its buffer. If it reports an empty input buffer and planner while idle, yet
    /// lines have waited over two seconds, a reply went missing and everything after it would be
    /// answered one late (the last command never). Treat those lines as done instead of hanging.
    private func checkForLostReplies(_ state: GrblState, _ buf: BufferState) {
        maxRxFree = max(maxRxFree, buf.rx)
        maxPlannerFree = max(maxPlannerFree, buf.planner)
        guard let oldest = inflight.first, state == .idle, buf.rx >= maxRxFree, buf.planner >= maxPlannerFree else { return }
        // A dwell reports Idle with empty buffers before it answers; job lines are left to the streamer.
        if inflight.contains(where: { $0.kind == .job || $0.text.contains(dwellRegex) }) { return }
        if nowMs() - (oldest.sentAt ?? nowMs()) < 2000 { return }
        let lost = inflight
        inflight = []
        inflightBytes = 0
        let names = lost.map { "\"\($0.text)\"" }.joined(separator: ", ")
        log(.info, "No reply from the controller to \(names), though it has finished with \(lost.count > 1 ? "them" : "it"). Carrying on.")
        for l in lost { l.resolve?(AckResult(ok: true)) }
        pump()
    }

    private func realtime(_ byte: UInt8) {
        transport?.write([byte])
    }

    // MARK: Jobs

    public struct JobMeta: Sendable {
        public var fileId: String
        public var fileName: String
        public var by: String?
        public var estSeconds: Double?
        public var group: JobGroup?
        public var fromLine: Int?
        public init(fileId: String, fileName: String, by: String? = nil, estSeconds: Double? = nil, group: JobGroup? = nil, fromLine: Int? = nil) {
            self.fileId = fileId
            self.fileName = fileName
            self.by = by
            self.estSeconds = estSeconds
            self.group = group
            self.fromLine = fromLine
        }
    }

    public func startJob(_ text: String, _ meta: JobMeta) throws {
        let lines = streamableLines(text)
        let from = max(0, meta.fromLine ?? 0)
        if from >= lines.count { throw MachineError("The file has only \(lines.count) lines") }
        // Never lower the cutter before it's over the work: lift first, then X, then Y (see planStart/planResume).
        let approach = ResumeOptions(machine: machine, config: config ?? .defaults)
        var preamble: [String]
        if from > 0 {
            let plan = try planResume(text, from, approach)
            preamble = plan.preamble
            for w in plan.state.warnings { log(.info, "Resume: \(w)", by: meta.by) }
        } else {
            preamble = planStart(text, approach)
        }
        jobLines = preamble.map { StreamLine(text: $0, source: -1) } + lines[from...]
        // From where the tool is now, so the first moves out to the work get their time too.
        let model = progressModel(text, options: InterpreterOptions(rapidRate: config?.rapidRate ?? 5000), from: from == 0 ? machine.wpos : nil)
        progress = model
        let startSeconds = secondsDone(model, from)
        jobPreamble = preamble.count
        jobAcked = 0
        jobAckedAtStatus = 0
        jobCursor = 0
        jobSuspended = false
        var j = JobState()
        j.status = .running
        j.fileId = meta.fileId
        j.fileName = meta.fileName
        j.totalLines = lines.count
        j.ackedLines = from
        j.firstLine = from
        j.cuttingLine = from
        j.totalSeconds = model.total
        j.doneSeconds = startSeconds
        j.startSeconds = startSeconds
        j.startedAt = nowMs()
        j.startedBy = meta.by
        if let est = meta.estSeconds, est > 0 { j.estSeconds = est * Double(lines.count - from) / Double(lines.count) }
        j.group = meta.group
        job = j
        emit(.job(job))
        let part = meta.group.map { " [\($0.name): file \($0.index + 1) of \($0.files.count)]" } ?? ""
        let at = from > 0 ? ", resuming at line \(from + 1) of \(lines.count)" : " (\(lines.count) lines)"
        log(.info, "Job started: \(meta.fileName)\(at)\(part)\(meta.by.map { " by \($0)" } ?? "")")
        // An empty line first: it ends any stray characters sitting in GRBL's line buffer (electrical
        // noise on the USB cable, say) so they can't be glued onto the job's first line.
        enqueue(QueuedLine(text: "", kind: .internal, echo: false)) { [weak self] r in
            guard let self, !r.ok else { return }
            self.assumeIsolated { $0.log(.info, "Cleared stray characters from GRBL's input before the job (likely electrical noise on the USB cable)") }
        }
        pump()
    }

    /// The stream line the cutter is on: the last acknowledged lines are still queued in GRBL's
    /// planner, so walk back over as many moves as it holds. Arcs take several planner blocks per
    /// line, which only moves the answer earlier (re-cutting, never skipping).
    private func currentLine() -> Int? {
        guard !jobLines.isEmpty, job.fileId != nil else { return nil }
        let used = lastBuf.map { max(0, maxPlannerFree - $0.planner) } ?? 0
        // Pair the planner count with the acknowledgements it was reported against. The cutter
        // may have moved on since, which only makes the answer earlier (safe).
        var i = lastBuf != nil ? jobAckedAtStatus : jobAcked
        var moves = 0
        while i > 0 && moves < used {
            i -= 1
            if isMotionLine(jobLines[i].text) { moves += 1 }
        }
        let line = (job.firstLine ?? 0) + max(0, i - jobPreamble)
        return min(line, job.totalLines - 1)
    }

    /// Where the machine has got to: the line it's executing and the estimated time done.
    private func trackProgress(_ wpos: Vec3) {
        guard let lowest = currentLine(), let progress else { return }
        // During the set-up moves (getting over the start point) the tool isn't on the program's path yet.
        let settingUp = jobAckedAtStatus <= jobPreamble
        // Counting queued moves can land early (GRBL skips moves to where the tool already is, and
        // splits arcs into many moves), so go forward to the line whose path the tool is on.
        let highest = (job.firstLine ?? 0) + jobAckedAtStatus - jobPreamble - 1
        let line = settingUp ? lowest : max(lowest, lineAtPosition(progress, lowest, highest, wpos))
        let done = max(job.startSeconds ?? 0, secondsDone(progress, line, settingUp ? nil : wpos))
        if line == job.cuttingLine && abs(done - (job.doneSeconds ?? 0)) < 0.5 { return }
        job.cuttingLine = line
        job.doneSeconds = done
        scheduleJobEmit()
    }

    private func pauseOnError(_ message: String) {
        jobSuspended = true
        realtime(RT.feedHold)
        job.status = .paused
        job.pausedAt = nowMs()
        job.error = message
        emit(.job(job))
        emit(.toast(Toast(.error, "Job paused: \(message)")))
    }

    private func failJob(_ message: String) {
        if isJobActive { job.resumeLine = currentLine() }
        jobSuspended = true
        job.status = .error
        job.error = message
        let now = nowMs()
        job.finishedAt = now
        if let p = job.pausedAt {
            job.pausedMs += now - p
            job.pausedAt = nil
        }
        jobLines = []
        emit(.job(job))
        log(.error, "Job failed: \(message)")
        emit(.toast(Toast(.error, "Job stopped: \(message)")))
    }

    private func finishJob(_ status: JobStatus) {
        if status == .done, let g = job.group, g.index < g.files.count - 1 { return awaitToolChange(g) }
        job.status = status
        let now = nowMs()
        job.finishedAt = now
        if let p = job.pausedAt {
            job.pausedMs += now - p
            job.pausedAt = nil
        }
        if status == .done {
            job.ackedLines = job.totalLines
            job.cuttingLine = nil
            if let t = job.totalSeconds, t > 0 { job.doneSeconds = t }
        }
        jobLines = []
        emit(.job(job))
        let name = job.fileName ?? ""
        if status == .stopped, pausing {
            let at = job.resumeLine.map { " at line \($0 + 1)" } ?? ""
            log(.info, "Job paused\(at): \(name). Raising Z")
            emit(.toast(Toast(.info, "Paused\(at). Raising Z")))
            return
        }
        log(.info, status == .done ? "Job complete: \(name)" : "Job stopped: \(name)")
        emit(.toast(Toast(.info, status == .done ? "Job complete: \(name)" : "Job stopped")))
    }

    /// A file in a group finished and another follows. Turn the spindle off (the file may not
    /// have) and wait for the bit change and Start next.
    private func awaitToolChange(_ g: JobGroup) {
        job.status = .toolchange
        job.finishedAt = nowMs()
        job.ackedLines = job.totalLines
        jobLines = []
        `internal`("M5")
        emit(.job(job))
        let next = g.files[g.index + 1]
        log(.info, "File \(g.index + 1) of \(g.files.count) complete: \(job.fileName ?? ""). Next: \(next.name). Change the bit, re-probe Z, then Start next.")
        emit(.toast(Toast(.info, "File \(g.index + 1) of \(g.files.count) done. Change the bit for \(next.name)")))
    }

    private func scheduleJobEmit() {
        guard jobEmitTask == nil else { return }
        jobEmitTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            self.jobEmitTask = nil
            self.emit(.job(self.job))
        }
    }

    // MARK: Commands

    /// Validate and run a machine command. Throws with a user-facing message if refused.
    public func command(_ cmd: Command, by: String? = nil) async throws {
        switch cmd {
        case .connect, .disconnect: break
        default:
            machine.lastCommandBy = by
            machineChanged()
        }
        let connected = machine.connection == .connected
        func need() throws {
            if !connected { throw MachineError("The machine is not connected") }
        }
        func idle(_ what: String) throws {
            try need()
            if isJobActive { throw MachineError("Can't \(what) while a job is running") }
            if machine.status == .alarm { throw MachineError("Can't \(what) in ALARM. Home or unlock first") }
            if machine.probing == true { throw MachineError("Can't \(what) while probing") }
        }
        /// `checked`: already checked as part of a batch (where the position is still changing).
        func run(_ text: String, checked: Bool = false) async throws {
            if !checked { try checkTravel([text]) }
            let r = await user(text, by: by)
            if !r.ok { throw MachineError(r.error ?? "Command failed") }
        }

        switch cmd {
        case .home:
            try need()
            if isJobActive { throw MachineError("Can't home while a job is running") }
            // GRBL may not answer status queries while homing, so the UI can look idle: ignore repeats.
            if (inflight + queue).contains(where: { $0.text == "$H" }) || machine.status == .home {
                throw MachineError("Already homing")
            }
            lostHome()
            machineChanged()
            try await run("$H")
            machine.homed = true
            homedAxes = Set(Axis.allCases)
            captureHomePosition = true
            machineChanged()
        case .homeAxis(let axis):
            try need()
            if isJobActive { throw MachineError("Can't home while a job is running") }
            if (inflight + queue).contains(where: { $0.text.hasPrefix("$H") }) || machine.status == .home {
                throw MachineError("Already homing")
            }
            if machine.homeAxes == true {
                // X and Y move at the cutter's height: home Z first, so the bit goes up clear of the work.
                for a in axis == .Z ? [Axis.Z] : [.Z, axis] {
                    try await run("$H\(a.rawValue)")
                    homedAxes.insert(a)
                    // Homing one axis leaves the others where they were: still homed if they were before.
                    if homedAxes.count == 3 { machine.homed = true }
                    machineChanged()
                }
            } else {
                // Stock GRBL 1.1 can't home one axis (and `$HX` there can leave it stuck in Home): move back to
                // where the last full home left that axis instead, Z first.
                guard machine.homed == true, let h = homePosition else {
                    throw MachineError("This GRBL can't home one axis at a time. Home all axes once: after that, Home \(axis.rawValue) moves \(axis.rawValue) back to its home position")
                }
                try idle("move")
                if machine.mpos[2] < h[2] - 0.001 || axis == .Z { try await run("G53G0Z\(fmt(h[2]))") }
                if axis != .Z {
                    let i = axis == .X ? 0 : 1
                    try await run("G53G0\(axis.rawValue)\(fmt(h[i]))")
                }
            }
        case .unlock:
            try need()
            try await run("$X")
        case .reset:
            try need()
            log(.out, "[soft reset]", by: by)
            if isJobActive { job.status = .stopping }
            realtime(RT.softReset)
        case .hold:
            try need()
            log(.out, "[feed hold]", by: by)
            realtime(RT.feedHold)
            if job.status == .running {
                job.status = .paused
                job.pausedAt = nowMs()
                emit(.job(job))
            }
        case .resume:
            try need()
            log(.out, "[cycle start]", by: by)
            realtime(RT.cycleStart)
            if job.status == .paused {
                job.status = .running
                if let p = job.pausedAt { job.pausedMs += nowMs() - p }
                job.pausedAt = nil
                job.error = nil
                jobSuspended = false
                emit(.job(job))
                pump()
            }
        case .stop:
            try await stopJob(by: by)
        case .pauseLift:
            try need()
            guard job.status == .running || job.status == .paused else { throw MachineError("No job is running to pause") }
            pausing = true
            defer { pausing = false }
            try await stopJob(by: by)
            // Wait for the reset to finish the job and GRBL to settle, then lift.
            let until = nowMs() + 6000
            while nowMs() < until, !(job.status == .stopped && machine.status == .idle) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard job.status == .stopped else { throw MachineError("The job didn't stop cleanly, so Z wasn't raised") }
            job.lifted = true
            emit(.job(job))
            guard machine.status == .idle else {
                throw MachineError("Paused, but GRBL is \(machine.status.rawValue), so Z wasn't raised. Unlock or home, then jog Z up")
            }
            // Homed: just under the top of travel. Not homed, the top isn't known: only to safe Z above work zero.
            let target = machine.homed == true
                ? (config?.envelope.max[2] ?? 0) - 1
                : machine.wco[2] + (config?.safeZ ?? 5)
            if target > machine.mpos[2] + 0.001 {
                let r = await user("G53G0Z\(fmt(target))", by: by)
                if !r.ok { throw MachineError("Paused, but raising Z failed: \(r.error ?? "error")") }
            }
        case .spindleStop:
            try need()
            // GRBL only takes this once a feed hold has completed; it toggles, and Resume turns it back on.
            if machine.status != .hold || machine.subState != 0 { throw MachineError("Pause the job first, then wait for it to stop moving") }
            let acc = machine.accessories ?? ""
            log(.out, acc.contains("S") || acc.contains("C") ? "[spindle stop]" : "[spindle restart]", by: by)
            realtime(RT.spindleStop)
        case let .jog(x, y, z, feed):
            try idle("jog")
            let d = try limitJog(Vec3(x ?? 0, y ?? 0, z ?? 0), by: by)
            var text = "$J=G91G21"
            for (i, a) in ["X", "Y", "Z"].enumerated() where d[i] != 0 { text += "\(a)\(fmt(d[i]))" }
            if text == "$J=G91G21" { return }
            text += "F\(jsNumber(feed.rounded()))"
            try await run(text)
        case .jogCancel:
            try need()
            realtime(RT.jogCancel)
        case .zero(let axes):
            try idle("set zero")
            if axes.isEmpty { return }
            try await run("G10L20P0" + axes.map { "\($0.rawValue)0" }.joined())
        case .goToZero(let axes):
            try idle("move")
            let safeZ = config?.safeZ ?? 5
            if axes.contains(.X) || axes.contains(.Y) {
                // Lift to the safe height above work zero first, but only ever up, and never closer
                // than 1 mm to the top of Z travel (with soft limits off, GRBL would drive into the
                // limit switch: a Z zero near the top puts "safe Z" past it).
                let top = (config?.envelope.max[2] ?? 0) - 1
                let mz = machine.mpos[2]
                let target = min(machine.wco[2] + safeZ, top)
                if target > mz + 0.001 { try await run("G53G0Z\(fmt(target))") }
                let xy = axes.filter { $0 != .Z }.map { "\($0.rawValue)0" }.joined()
                try await run("G90G0\(xy)")
            }
            if axes.contains(.Z) {
                if machine.wco[2] > (config?.envelope.max[2] ?? 0) + 0.001 {
                    throw MachineError("Work Z zero is above the top of Z travel. Zero Z on the stock (or probe) first")
                }
                try await run("G90G0Z0")
            }
        case .mdi(let text):
            try idle("send commands")
            let lines = splitCommandLines(text)
            try checkTravel(lines) // the whole batch before any of it is sent
            defer { `internal`("$G") } // keep the distance modes in step
            for l in lines { try await run(l, checked: true) }
        case .runMacro(let id):
            guard let macro = macros.first(where: { $0.id == id }) else { throw MachineError("Macro not found") }
            try idle("run a macro")
            let lines = splitCommandLines(macro.gcode)
            try checkTravel(lines, what: "Macro \"\(macro.name)\"")
            log(.info, "Macro: \(macro.name)", by: by)
            defer { `internal`("$G") }
            for l in lines { try await run(l, checked: true) }
        case let .override(kind, action):
            try need()
            guard let byte = overrideByte(kind, action) else { throw MachineError("Unknown override") }
            realtime(byte)
        case .refreshSettings:
            try idle("read settings")
            queryState()
        case .clearJob:
            if isJobActive { throw MachineError("A job is still running") }
            if job.status == .toolchange {
                log(.info, "Group \(job.group?.name ?? "") ended after file \((job.group?.index ?? 0) + 1)", by: by)
            }
            job = JobState()
            emit(.job(job))
        case .probeZ:
            try idle("probe")
            try await probeZ(by: by)
        case .start, .startNext:
            throw MachineError("start must go through the library")
        default:
            throw MachineError("Unsupported command \(cmd.type)")
        }
    }

    /// Set work Z from a touch plate: a fast touch, lift 2 mm, a slow touch, then set the contact
    /// point to the plate thickness and lift clear. Uses G38.2, so GRBL raises ALARM:5 if nothing
    /// is touched within the search distance.
    private func probeZ(by: String?) async throws {
        guard let p = config?.probe, p.plateThickness > 0 else { throw MachineError("Set the touch plate thickness in Settings first") }
        if machine.status != .idle { throw MachineError("The machine is busy (\(machine.status.rawValue))") }
        if machine.pins?.contains("P") == true {
            throw MachineError("The probe input is already closed. Check the plate is not touching the bit and the clip is not shorted")
        }
        machine.probing = true
        machineChanged()
        log(.info, "Probing Z (plate \(jsNumber(p.plateThickness)) mm, searching \(jsNumber(p.maxTravel)) mm down)", by: by)
        func fail(_ message: String) -> MachineError {
            machine.probing = false
            machine.lastProbe = ProbeResult(ok: false, message: message, t: nowMs())
            machineChanged()
            return MachineError(message)
        }
        let startResets = resets
        func step(_ text: String) async throws {
            // A reset between steps (Reset pressed, or the board rebooted) ends the cycle: the next
            // step must not run on a machine that has just been reset.
            if resets != startResets || transport == nil { throw fail("Probing stopped: the controller reset") }
            log(.out, text, by: by)
            lastAlarmCode = nil
            let r = await enqueue(QueuedLine(text: text, kind: .user, by: by, echo: true))
            if resets != startResets && lastAlarmCode == nil { throw fail("Probing stopped: the controller reset") }
            if r.ok { return }
            if lastAlarmCode == 5 { throw fail("No contact within \(jsNumber(p.maxTravel)) mm. Check the clip and plate, then unlock to continue") }
            if lastAlarmCode == 4 { throw fail("The probe input was already closed when probing started. Check the clip, then unlock") }
            throw fail("Probing stopped: \(r.error ?? "command failed")")
        }
        func touch(_ text: String) async throws -> Vec3 {
            lastPrb = nil
            try await step(text)
            guard let prb = lastPrb, prb.ok else { throw fail("The probe did not report a contact") }
            return prb.pos
        }

        let z0 = machine.wpos[2]
        try await step("G21G90")
        let first = try await touch("G38.2Z\(fmt(z0 - p.maxTravel))F\(jsNumber(p.seekFeed.rounded()))")
        let firstWorkZ = first[2] - machine.wco[2]
        try await step("G0Z\(fmt(firstWorkZ + 2))")
        let second = try await touch("G38.2Z\(fmt(firstWorkZ - 2))F\(jsNumber(p.latchFeed.rounded()))")
        // The tool now rests on the plate: that height is the plate thickness above the stock.
        try await step("G10L20P0Z\(fmt(p.plateThickness))")
        try await step("G0Z\(fmt(p.plateThickness + p.retract))")
        try await step("G4P0.01") // a dwell is answered only once motion has stopped
        await waitForIdle()
        if resets != startResets { throw fail("Probing stopped: the controller reset") }
        let message = "Z zeroed on the stock surface (plate \(jsNumber(p.plateThickness)) mm). Remove the plate and clip"
        log(.info, message, by: by)
        machine.probing = false
        machine.lastProbe = ProbeResult(ok: true, message: message, t: nowMs(), contactZ: second[2])
        machineChanged()
    }

    /// Wait for a fresh status report showing Idle (up to 2 s).
    private func waitForIdle() async {
        let end = nowMs() + 2000
        let start = machineUpdates
        while nowMs() < end && !(machineUpdates > start && machine.status == .idle) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Refuse commands that would take the machine past the end of its travel (once homed, when the
    /// position is known). Works through the lines in order, following the distance modes and where
    /// each line leaves the machine, and throws before anything is sent.
    private func checkTravel(_ lines: [String], what: String? = nil) throws {
        let env = config?.envelope
        var modes = self.modes
        var pos = machine.mpos
        for line in lines {
            let lt = lineTarget(line, modes: modes, mpos: pos, wco: machine.wco)
            if let target = lt.target, let env, machine.homed == true, let problem = travelProblem(target, env) {
                let message = "\(what.map { "\($0): " } ?? "")\"\(line)\" would go \(problem), into the limit switch. Not sent"
                log(.error, message)
                throw MachineError(message)
            }
            if let target = lt.target {
                for i in 0..<3 { if let t = target[i] { pos[i] = t } }
            }
            modes = lt.modes
        }
    }

    /// Shorten a jog so it stops at the end of travel. With soft limits off GRBL would drive into
    /// the limit switch, which stops it dead (ALARM, position lost). Only once homed: before that
    /// the machine position means nothing.
    private func limitJog(_ d: Vec3, by: String?) throws -> Vec3 {
        guard let env = config?.envelope, machine.homed == true else { return d }
        let names = ["X", "Y", "Z"]
        var out = d
        var cut: [String] = []
        for a in 0..<3 where d[a] != 0 {
            let p = machine.mpos[a]
            let target = min(env.max[a], max(env.min[a], p + d[a]))
            let moved = abs(target - p) < 0.001 ? 0 : ((target - p) * 1000).rounded() / 1000
            if abs(moved - d[a]) > 0.001 { cut.append("\(names[a])\(d[a] > 0 ? "+" : "−")") }
            out[a] = moved
        }
        if out == .zero { throw MachineError("Already at the end of travel (\(cut.joined(separator: ", ")))") }
        if !cut.isEmpty {
            let text = "Jog shortened to stop at the end of travel (\(cut.joined(separator: ", ")))"
            log(.info, text, by: by)
            emit(.toast(Toast(.warn, text)))
        }
        return out
    }

    /// Refuse a program that would go past the end of travel from the current work zero: GRBL
    /// would drive into a limit switch (with soft limits off) and stop dead in ALARM.
    public func checkFitsTravel(_ bounds: Bounds?) throws {
        guard let env = config?.envelope, let bounds, machine.homed == true else { return }
        let wco = machine.wco
        var over: [String] = []
        let names = ["X", "Y", "Z"]
        for a in 0..<3 {
            let lo = bounds.min[a] + wco[a]
            let hi = bounds.max[a] + wco[a]
            if hi > env.max[a] + 0.01 { over.append("\(names[a]) by \(fixed(hi - env.max[a], 1)) mm past the \(a == 2 ? "top" : "far end")") }
            if lo < env.min[a] - 0.01 { over.append("\(names[a]) by \(fixed(env.min[a] - lo, 1)) mm past the \(a == 2 ? "bottom" : "near end")") }
        }
        if !over.isEmpty {
            let z = over.contains { $0.hasPrefix("Z") && $0.contains("top") }
            throw MachineError(
                "From this work zero the program goes outside the machine's travel: \(over.joined(separator: "; "))."
                    + (z ? " Its safe-Z moves would hit the top limit switch: set Z zero lower, or lower the program's safe Z." : " Check the work zero."))
        }
    }

    /// Refuse to start unless the machine is idle and nothing else is running.
    public func checkCanStart(loading: Bool = false) throws {
        if machine.connection != .connected { throw MachineError("The machine is not connected") }
        let busy = loading ? isJobActive && job.status != .loading : isJobActive
        if busy { throw MachineError("A job is already running") }
        if machine.status == .alarm { throw MachineError("The machine is in ALARM. Home or unlock first") }
        if machine.status != .idle { throw MachineError("The machine is busy (\(machine.status.rawValue))") }
        if machine.probing == true { throw MachineError("Probing is in progress") }
    }

    public func markLoading(fileId: String, fileName: String, by: String?) {
        var j = JobState()
        j.status = .loading
        j.fileId = fileId
        j.fileName = fileName
        j.startedBy = by
        job = j
        emit(.job(job))
    }

    /// Put back a job state saved before loading (a group waiting for its next file).
    public func restoreJob(_ j: JobState) {
        job = j
        emit(.job(job))
    }

    public func cancelLoading(_ error: String) {
        guard job.status == .loading else { return }
        job.status = .error
        job.error = error
        emit(.job(job))
    }

    private func stopJob(by: String?) async throws {
        if machine.connection != .connected { throw MachineError("The machine is not connected") }
        log(.out, "[stop]", by: by)
        jobSuspended = true
        if isJobActive {
            // Before the reset clears GRBL's queue: which line the cutter is on, to resume from.
            job.resumeLine = currentLine()
            job.status = .stopping
            emit(.job(job))
        }
        // Hold first so the reset doesn't happen mid-motion (which would raise ALARM:3).
        realtime(RT.feedHold)
        let until = nowMs() + 1500
        while nowMs() < until {
            let s = machine.status
            if (s == .hold && machine.subState == 0) || s == .idle || s == .alarm { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        realtime(RT.softReset)
        // onWelcome finishes the job as stopped when the banner arrives.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.job.status == .stopping { self.finishJob(.stopped) }
        }
    }

    // MARK: State helpers

    private func machineChanged() {
        machineUpdates += 1
        emit(.machine(machine))
    }

    public func log(_ dir: ConsoleLine.Direction, _ text: String, by: String? = nil) {
        let line = ConsoleLine(dir: dir, text: text, by: by)
        console.append(line)
        if console.count > consoleMax { console.removeFirst(console.count - consoleMax) }
        pendingConsole.append(line)
        if consoleTask == nil {
            consoleTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                self.consoleTask = nil
                let lines = self.pendingConsole
                self.pendingConsole = []
                self.emit(.console(lines))
            }
        }
    }
}

private func splitCommandLines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r\n" }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private func overrideByte(_ kind: OverrideKind, _ action: OverrideAction) -> UInt8? {
    switch (kind, action) {
    case (.feed, .reset): RT.feedOvReset
    case (.feed, .plus10): RT.feedOvPlus10
    case (.feed, .minus10): RT.feedOvMinus10
    case (.feed, .plus1): RT.feedOvPlus1
    case (.feed, .minus1): RT.feedOvMinus1
    case (.spindle, .reset): RT.spindleOvReset
    case (.spindle, .plus10): RT.spindleOvPlus10
    case (.spindle, .minus10): RT.spindleOvMinus10
    case (.spindle, .plus1): RT.spindleOvPlus1
    case (.spindle, .minus1): RT.spindleOvMinus1
    case (.rapid, .reset): RT.rapidOv100
    case (.rapid, .r50): RT.rapidOv50
    case (.rapid, .r25): RT.rapidOv25
    default: nil
    }
}

/// A jog or move distance as 1.0 wrote it: four decimals at most, no trailing zeros.
func fmt(_ n: Double) -> String { jsNumber(Double(fixed(n, 4)) ?? n) }
