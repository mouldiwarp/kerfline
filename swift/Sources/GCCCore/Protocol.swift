// The state every window renders and the commands that drive the machine and the library.
// Whichever Mac has the machine on USB is the authority on machine and job state. The JSON
// shapes match 1.0's (packages/shared/src/protocol.ts), so 1.0's saved data (library.json,
// config.json) decodes directly.

import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected
}

public struct Alarm: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct CommandError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var line: String?
    public init(code: Int, message: String, line: String? = nil) {
        self.code = code
        self.message = message
        self.line = line
    }
}

public struct ProbeResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    /// When, ms since 1970.
    public var t: Double
    /// Machine Z where the bit touched the plate.
    public var contactZ: Double?
    public init(ok: Bool, message: String, t: Double, contactZ: Double? = nil) {
        self.ok = ok
        self.message = message
        self.t = t
        self.contactZ = contactZ
    }
}

public struct MachineState: Codable, Equatable, Sendable {
    public var connection: ConnectionState = .disconnected
    public var port: String?
    public var simulated: Bool
    public var firmware: String?
    public var status: GrblState = .unknown
    public var subState: Int?
    public var mpos = Vec3.zero
    public var wpos = Vec3.zero
    public var wco = Vec3.zero
    /// Homed since the last alarm or connect, so the machine position (and the travel limits) can be trusted.
    public var homed: Bool?
    /// GRBL was built with single-axis homing (`$HX`, `$HY`, `$HZ`; "H" in `$I`'s `[OPT:]`).
    public var homeAxes: Bool?
    public var feed = 0.0
    public var spindle = 0.0
    public var overrides = Overrides()
    public var buffer: BufferState?
    public var pins: String?
    /// Spindle/coolant state from the status report's A: field ("S" clockwise, "C" counter, "F" flood, "M" mist).
    public var accessories: String?
    public var alarm: Alarm?
    /// Last `error:N` received outside a job, for the toast.
    public var lastError: CommandError?
    /// Name of the client that sent the most recent command.
    public var lastCommandBy: String?
    /// Raw `[GC:...]` modal state.
    public var modal: String?
    public var settings: [String: String]?
    /// A Z probe cycle is running.
    public var probing: Bool?
    /// Result of the most recent Z probe.
    public var lastProbe: ProbeResult?

    public init(simulated: Bool = false) { self.simulated = simulated }
}

/// `toolchange`: one file of a group has finished and the next is waiting for a bit change.
public enum JobStatus: String, Codable, Sendable {
    case idle, loading, running, paused, stopping, toolchange, done, stopped, error

    /// A job is under way (including a group waiting for its next file).
    public var isActive: Bool { [.loading, .running, .paused, .stopping, .toolchange].contains(self) }
}

public struct GroupFile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A run of several library files in order (one per tool, or side A / side B).
public struct JobGroup: Codable, Equatable, Sendable {
    public var name: String
    public var files: [GroupFile]
    /// Index in `files` of the file this job state is about.
    public var index: Int
    public init(name: String, files: [GroupFile], index: Int) {
        self.name = name
        self.files = files
        self.index = index
    }
}

public struct JobState: Codable, Equatable, Sendable {
    public var status: JobStatus = .idle
    public var fileId: String?
    public var fileName: String?
    /// Lines that will be streamed.
    public var totalLines = 0
    /// Lines GRBL has acknowledged with ok (planned or executed).
    public var ackedLines = 0
    /// Source line index (0-based) of the last acknowledged line, for the visualizer.
    public var sourceLine = -1
    /// ms since 1970.
    public var startedAt: Double?
    public var finishedAt: Double?
    /// Milliseconds spent paused so far.
    public var pausedMs = 0.0
    public var pausedAt: Double?
    public var startedBy: String?
    public var estSeconds: Double?
    public var error: String?
    public var group: JobGroup?
    /// Stream line this run started from (0 unless resumed part way).
    public var firstLine: Int?
    /// After a stop or failure: the stream line the cutter was on, to resume from.
    public var resumeLine: Int?
    /// Stopped by Pause (`pauseLift`): Z was raised, and Resume carries on from `resumeLine`.
    public var lifted: Bool?
    /// Stream line the machine is executing now (behind ackedLines by what GRBL has queued).
    public var cuttingLine: Int?
    /// Estimated seconds of the whole program, and how many of them the machine has done.
    public var totalSeconds: Double?
    public var doneSeconds: Double?
    /// doneSeconds when this run started (non-zero for a resume).
    public var startSeconds: Double?

    public init() {}

    /// Seconds the job has actually been running (excluding pauses).
    public func elapsedSeconds(now: Double = nowMs()) -> Double {
        guard let startedAt else { return 0 }
        let end = finishedAt ?? now
        let paused = pausedMs + (pausedAt.map { end - $0 } ?? 0)
        return max(0, (end - startedAt - paused) / 1000)
    }

    public var percent: Double {
        if totalLines == 0 { return 0 }
        if status == .done || status == .toolchange { return 100 }
        // By estimated machine time when known: lines say little (GRBL acknowledges queued moves,
        // and one line can take a minute while hundreds of others take a second between them).
        if let totalSeconds, totalSeconds > 0, let doneSeconds { return min(100, doneSeconds / totalSeconds * 100) }
        return min(100, Double(ackedLines) / Double(totalLines) * 100)
    }
}

public struct LibraryItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// File name on disk, including the extension.
    public var name: String
    /// Folder inside the library, "/"-separated; "" for the top level.
    public var folder: String
    public var source: String
    public var size: Int
    public var sha256: String
    /// ms since 1970.
    public var addedAt: Double
    public var sourceLines: Int
    public var streamLines: Int
    public var bounds: Bounds?
    public var cutBounds: Bounds?
    public var estSeconds: Double
    public var group: String?
    public var groupIndex: Int?
    /// 0-based source line of the first cutting move made with the spindle off, if the program has one
    /// (see `ProgramAnalysis.spindleOffCut`). Nil from a Mac that predates the check.
    public var spindleOffCut: Int?
    /// Where the file's header says Z zero is taken. Nil when it doesn't say, or from a Mac that predates reading it.
    public var zZero: ZZeroReference?

    public init(
        id: String, name: String, folder: String, source: String, size: Int, sha256: String, addedAt: Double,
        sourceLines: Int, streamLines: Int, bounds: Bounds?, cutBounds: Bounds?, estSeconds: Double,
        group: String? = nil, groupIndex: Int? = nil, spindleOffCut: Int? = nil, zZero: ZZeroReference? = nil
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.source = source
        self.size = size
        self.sha256 = sha256
        self.addedAt = addedAt
        self.sourceLines = sourceLines
        self.streamLines = streamLines
        self.bounds = bounds
        self.cutBounds = cutBounds
        self.estSeconds = estSeconds
        self.group = group
        self.groupIndex = groupIndex
        self.spindleOffCut = spindleOffCut
        self.zZero = zZero
    }
}

public struct Macro: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var gcode: String
    public init(id: String, name: String, gcode: String) {
        self.id = id
        self.name = name
        self.gcode = gcode
    }
}

public struct ProbeConfig: Codable, Equatable, Sendable {
    /// Touch plate thickness, mm. 0 means not set yet: probing is refused until it is measured.
    public var plateThickness: Double
    /// How far down to search before giving up, mm.
    public var maxTravel: Double
    /// First, fast touch, mm/min.
    public var seekFeed: Double
    /// Second, slow touch that sets zero, mm/min.
    public var latchFeed: Double
    /// Lift above the plate when done, mm.
    public var retract: Double

    public init(plateThickness: Double, maxTravel: Double, seekFeed: Double, latchFeed: Double, retract: Double) {
        self.plateThickness = plateThickness
        self.maxTravel = maxTravel
        self.seekFeed = seekFeed
        self.latchFeed = latchFeed
        self.retract = retract
    }
}

public struct MachineConfig: Codable, Equatable, Sendable {
    /// Machine-coordinate travel envelope (from $130-$132 and the homing corner).
    public var envelope: Bounds
    /// Height above work zero to lift to before moving XY to zero, mm.
    public var safeZ: Double
    public var jogSteps: [Double]
    public var jogFeedXY: Double
    public var jogFeedZ: Double
    public var rapidRate: Double
    public var probe: ProbeConfig

    /// The simulator's travel: an 800 x 800 x 120 mm machine homing to the positive corner (GRBL's
    /// default). The FoxAlien homes front-left, so its travel is positive; the start-up check
    /// offers the controller's own travel when they differ.
    public static let defaults = MachineConfig(
        envelope: Bounds(min: Vec3(-800, -800, -120), max: Vec3(0, 0, 0)),
        safeZ: 5,
        jogSteps: [0.1, 1, 10, 50],
        jogFeedXY: 3000,
        jogFeedZ: 1000,
        rapidRate: 5000,
        probe: ProbeConfig(plateThickness: 0, maxTravel: 25, seekFeed: 150, latchFeed: 25, retract: 5))

    /// Apply the fields a `saveConfig` command sets.
    public mutating func apply(_ p: MachineConfigPatch) {
        if let v = p.envelope { envelope = v }
        if let v = p.safeZ { safeZ = v }
        if let v = p.jogSteps { jogSteps = v }
        if let v = p.jogFeedXY { jogFeedXY = v }
        if let v = p.jogFeedZ { jogFeedZ = v }
        if let v = p.rapidRate { rapidRate = v }
        if let v = p.probe { probe = v }
    }
}

/// Some of MachineConfig's fields (1.0's `Partial<MachineConfig>`).
public struct MachineConfigPatch: Codable, Equatable, Sendable {
    public var envelope: Bounds?
    public var safeZ: Double?
    public var jogSteps: [Double]?
    public var jogFeedXY: Double?
    public var jogFeedZ: Double?
    public var rapidRate: Double?
    public var probe: ProbeConfig?
    public init(
        envelope: Bounds? = nil, safeZ: Double? = nil, jogSteps: [Double]? = nil, jogFeedXY: Double? = nil,
        jogFeedZ: Double? = nil, rapidRate: Double? = nil, probe: ProbeConfig? = nil
    ) {
        self.envelope = envelope
        self.safeZ = safeZ
        self.jogSteps = jogSteps
        self.jogFeedXY = jogFeedXY
        self.jogFeedZ = jogFeedZ
        self.rapidRate = rapidRate
        self.probe = probe
    }
}

public struct ConsoleLine: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case `in`, out, info, error
    }
    /// ms since 1970.
    public var t: Double
    public var dir: Direction
    public var text: String
    public var by: String?
    public init(t: Double = nowMs(), dir: Direction, text: String, by: String? = nil) {
        self.t = t
        self.dir = dir
        self.text = text
        self.by = by
    }
}

// MARK: - Code versions and updates

/// The code an app is running: the git commit it was built from and when that commit was made.
public struct CodeVersion: Codable, Equatable, Sendable {
    public var version: String
    /// Full git commit hash, when built from a git checkout.
    public var commit: String?
    /// Commit time (ms since 1970).
    public var time: Double?
    public init(version: String, commit: String? = nil, time: Double? = nil) {
        self.version = version
        self.commit = commit
        self.time = time
    }

    public var shortCommit: String { commit.map { String($0.prefix(7)) } ?? "unknown" }
}

/// "2.1.0" → [2, 1, 0]; nil unless it's dot-separated numbers (an optional leading "v").
func versionNumbers(_ version: String) -> [Int]? {
    let v = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
    let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.compactMap { $0 }
}

public enum CodeComparison: String, Sendable {
    case same, behind, ahead, different, unknown
}

/// How `mine` compares with `theirs`: by release version when those differ ("2.1" is behind
/// "2.1.1", and "2.1" is "2.1.0"), otherwise by commit and commit time.
public func compareCode(_ mine: CodeVersion?, _ theirs: CodeVersion?) -> CodeComparison {
    if let va = mine.flatMap({ versionNumbers($0.version) }), let vb = theirs.flatMap({ versionNumbers($0.version) }) {
        let n = max(va.count, vb.count)
        let pa = va + Array(repeating: 0, count: n - va.count)
        let pb = vb + Array(repeating: 0, count: n - vb.count)
        if pa != pb { return pa.lexicographicallyPrecedes(pb) ? .behind : .ahead }
    }
    guard let a = mine?.commit, let b = theirs?.commit else { return .unknown }
    if a == b { return .same }
    guard let ta = mine?.time, let tb = theirs?.time else { return .different }
    if ta < tb { return .behind }
    if ta > tb { return .ahead }
    return .different
}

// MARK: - Commands

public enum Axis: String, Codable, Sendable, CaseIterable {
    case X, Y, Z
}

public enum OverrideKind: String, Codable, Sendable {
    case feed, rapid, spindle
}

public enum OverrideAction: String, Codable, Sendable {
    case reset, plus10, minus10, plus1, minus1, r50, r25
}

public enum UpdateTarget: String, Codable, Sendable {
    case hub, agent
}

/// Everything a window can ask for. Encoded as `{"type": "jog", "x": 1, "feed": 3000}` like 1.0.
public enum Command: Equatable, Sendable {
    // Machine (handled by whichever Mac has it on USB)
    case connect(port: String?)
    case disconnect
    case home
    /// Home one axis: `$HZ` (Z first for X and Y) where GRBL can, else a move back to the position the last full home left it at.
    case homeAxis(axis: Axis)
    case unlock
    case reset
    case hold
    case resume
    /// Pause a job and raise Z out of the way. GRBL can't move during a feed hold (without parking, which the
    /// FoxAlien's firmware lacks), so this stops at the current line, lifts Z to the top, and Resume restarts from there.
    case pauseLift
    case jog(x: Double?, y: Double?, z: Double?, feed: Double)
    case jogCancel
    case zero(axes: [Axis])
    case goToZero(axes: [Axis])
    case mdi(line: String)
    case runMacro(id: String)
    /// `group`: run the rest of the file's group after it. `fromLine`: resume from this stream line.
    /// `spindleOff`: the user confirmed running a program that cuts with the spindle off (see `spindleOffCut`).
    case start(fileId: String, group: Bool?, fromLine: Int?, spindleOff: Bool? = nil)
    case spindleStop
    case startNext
    case probeZ
    case stop
    case override(kind: OverrideKind, action: OverrideAction)
    case refreshSettings
    case clearJob
    // Library
    case deleteFile(fileId: String)
    case renameFile(fileId: String, name: String)
    case moveFile(fileId: String, folder: String)
    case createFolder(path: String)
    case renameFolder(path: String, to: String)
    case deleteFolder(path: String)
    case saveMacro(macro: Macro)
    case deleteMacro(id: String)
    case saveConfig(config: MachineConfigPatch)
    /// Pull the latest code, rebuild and relaunch that Mac's app.
    case update(target: UpdateTarget)

    /// The `type` it's encoded with.
    public var type: String {
        switch self {
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .home: "home"
        case .homeAxis: "homeAxis"
        case .unlock: "unlock"
        case .reset: "reset"
        case .hold: "hold"
        case .resume: "resume"
        case .pauseLift: "pauseLift"
        case .jog: "jog"
        case .jogCancel: "jogCancel"
        case .zero: "zero"
        case .goToZero: "goToZero"
        case .mdi: "mdi"
        case .runMacro: "runMacro"
        case .start: "start"
        case .spindleStop: "spindleStop"
        case .startNext: "startNext"
        case .probeZ: "probeZ"
        case .stop: "stop"
        case .override: "override"
        case .refreshSettings: "refreshSettings"
        case .clearJob: "clearJob"
        case .deleteFile: "deleteFile"
        case .renameFile: "renameFile"
        case .moveFile: "moveFile"
        case .createFolder: "createFolder"
        case .renameFolder: "renameFolder"
        case .deleteFolder: "deleteFolder"
        case .saveMacro: "saveMacro"
        case .deleteMacro: "deleteMacro"
        case .saveConfig: "saveConfig"
        case .update: "update"
        }
    }

    /// Library, macro and config commands (synced between the Macs rather than sent to the machine).
    public var isLibraryCommand: Bool {
        ["deleteFile", "renameFile", "moveFile", "createFolder", "renameFolder", "deleteFolder", "saveMacro", "deleteMacro", "saveConfig"]
            .contains(type)
    }

    /// Commands that move the machine.
    public var movesMachine: Bool {
        ["start", "startNext", "jog", "home", "homeAxis", "goToZero", "mdi", "runMacro", "probeZ"].contains(type)
    }
}

extension Command: Codable {
    private enum Key: String, CodingKey {
        case type, port, x, y, z, feed, axes, axis, line, id, fileId, group, fromLine, spindleOff, kind, action, name, folder, path, to, macro, config, target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        func s(_ k: Key) throws -> String { try c.decode(String.self, forKey: k) }
        switch type {
        case "connect": self = .connect(port: try c.decodeIfPresent(String.self, forKey: .port))
        case "disconnect": self = .disconnect
        case "home": self = .home
        case "homeAxis": self = .homeAxis(axis: try c.decode(Axis.self, forKey: .axis))
        case "unlock": self = .unlock
        case "reset": self = .reset
        case "hold": self = .hold
        case "resume": self = .resume
        case "pauseLift": self = .pauseLift
        case "jog":
            self = .jog(
                x: try c.decodeIfPresent(Double.self, forKey: .x), y: try c.decodeIfPresent(Double.self, forKey: .y),
                z: try c.decodeIfPresent(Double.self, forKey: .z), feed: try c.decode(Double.self, forKey: .feed))
        case "jogCancel": self = .jogCancel
        case "zero": self = .zero(axes: try c.decode([Axis].self, forKey: .axes))
        case "goToZero": self = .goToZero(axes: try c.decode([Axis].self, forKey: .axes))
        case "mdi": self = .mdi(line: try s(.line))
        case "runMacro": self = .runMacro(id: try s(.id))
        case "start":
            self = .start(
                fileId: try s(.fileId), group: try c.decodeIfPresent(Bool.self, forKey: .group),
                fromLine: try c.decodeIfPresent(Int.self, forKey: .fromLine),
                spindleOff: try c.decodeIfPresent(Bool.self, forKey: .spindleOff))
        case "spindleStop": self = .spindleStop
        case "startNext": self = .startNext
        case "probeZ": self = .probeZ
        case "stop": self = .stop
        case "override":
            self = .override(kind: try c.decode(OverrideKind.self, forKey: .kind), action: try c.decode(OverrideAction.self, forKey: .action))
        case "refreshSettings": self = .refreshSettings
        case "clearJob": self = .clearJob
        case "deleteFile": self = .deleteFile(fileId: try s(.fileId))
        case "renameFile": self = .renameFile(fileId: try s(.fileId), name: try s(.name))
        case "moveFile": self = .moveFile(fileId: try s(.fileId), folder: try s(.folder))
        case "createFolder": self = .createFolder(path: try s(.path))
        case "renameFolder": self = .renameFolder(path: try s(.path), to: try s(.to))
        case "deleteFolder": self = .deleteFolder(path: try s(.path))
        case "saveMacro": self = .saveMacro(macro: try c.decode(Macro.self, forKey: .macro))
        case "deleteMacro": self = .deleteMacro(id: try s(.id))
        case "saveConfig": self = .saveConfig(config: try c.decode(MachineConfigPatch.self, forKey: .config))
        case "update": self = .update(target: try c.decode(UpdateTarget.self, forKey: .target))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown command \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .connect(let port): try c.encodeIfPresent(port, forKey: .port)
        case .jog(let x, let y, let z, let feed):
            try c.encodeIfPresent(x, forKey: .x)
            try c.encodeIfPresent(y, forKey: .y)
            try c.encodeIfPresent(z, forKey: .z)
            try c.encode(feed, forKey: .feed)
        case .zero(let axes), .goToZero(let axes): try c.encode(axes, forKey: .axes)
        case .homeAxis(let axis): try c.encode(axis, forKey: .axis)
        case .mdi(let line): try c.encode(line, forKey: .line)
        case .runMacro(let id), .deleteMacro(let id): try c.encode(id, forKey: .id)
        case .start(let fileId, let group, let fromLine, let spindleOff):
            try c.encode(fileId, forKey: .fileId)
            try c.encodeIfPresent(group, forKey: .group)
            try c.encodeIfPresent(fromLine, forKey: .fromLine)
            try c.encodeIfPresent(spindleOff, forKey: .spindleOff)
        case .override(let kind, let action):
            try c.encode(kind, forKey: .kind)
            try c.encode(action, forKey: .action)
        case .deleteFile(let fileId): try c.encode(fileId, forKey: .fileId)
        case .renameFile(let fileId, let name):
            try c.encode(fileId, forKey: .fileId)
            try c.encode(name, forKey: .name)
        case .moveFile(let fileId, let folder):
            try c.encode(fileId, forKey: .fileId)
            try c.encode(folder, forKey: .folder)
        case .createFolder(let path), .deleteFolder(let path): try c.encode(path, forKey: .path)
        case .renameFolder(let path, let to):
            try c.encode(path, forKey: .path)
            try c.encode(to, forKey: .to)
        case .saveMacro(let macro): try c.encode(macro, forKey: .macro)
        case .saveConfig(let config): try c.encode(config, forKey: .config)
        case .update(let target): try c.encode(target, forKey: .target)
        case .disconnect, .home, .unlock, .reset, .hold, .resume, .jogCancel, .spindleStop, .startNext, .probeZ, .stop, .pauseLift,
            .refreshSettings, .clearJob:
            break
        }
    }
}

public let hubServiceType = "_gcodehub._tcp"
public let defaultHubPort = 8080
