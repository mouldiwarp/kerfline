// What the two Macs say to each other over the instance link (a WebSocket from the agent to the
// hub's /link), and the state a window renders.
//
//   hello      who I am (sent first by both sides)
//   snapshot   my machine, job and console, sent after hello; then machine/job/console as they change.
//              Whichever Mac has the FoxAlien on USB is the authority; the other mirrors it.
//   cmd        "do this on your machine", answered by result (the other Mac owns the machine)
//   toast      a notification to show
//   sync       library sync (LibrarySync's conversation)
//
// This is 2.0's protocol, not wire-compatible with 1.0's: both Macs move to 2.0 together.

import Foundation
import SGCore
import SGLibrary
import SGMachine

public let linkProtocolVersion = 2

public enum Role: String, Codable, Sendable {
    case hub, agent
}

public struct Hello: Codable, Sendable, Equatable {
    public var name: String
    public var role: Role
    public var version: Int
    /// The library replica, so a Mac never links to itself.
    public var replica: String
    /// The code it runs (to offer updating whichever Mac is behind).
    public var code: CodeVersion? = nil
}

/// One Mac's machine, as its MachineSession sees it.
public struct MachineView: Codable, Sendable, Equatable {
    public var machine: MachineState
    public var job: JobState
    public var console: [ConsoleLine]

    public init(machine: MachineState, job: JobState = JobState(), console: [ConsoleLine] = []) {
        self.machine = machine
        self.job = job
        self.console = console
    }

    /// The machine is on USB here (connected, or on its way).
    public var hasMachine: Bool { machine.connection != .disconnected }
}

public struct CommandResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
    public static let success = CommandResult(ok: true)
    public static func failure(_ message: String) -> CommandResult { CommandResult(ok: false, error: message) }
}

public enum LinkMessage: Codable, Sendable {
    case hello(Hello)
    case snapshot(MachineView)
    case machine(MachineState)
    case job(JobState)
    /// New console lines.
    case console([ConsoleLine])
    case cmd(id: String, command: Command, by: String)
    case result(id: String, result: CommandResult)
    case toast(Toast)
    case sync(SyncMessage)
}

// MARK: - The state a window renders (also GET /api/state, shaped like 1.0's AppState)

public struct LinkState: Codable, Sendable, Equatable {
    public var hubConnected: Bool
    public var agentConnected: Bool
    /// Which Mac this is.
    public var via: Role
    public var hubName: String?
    public var agentName: String?
    /// The Mac the machine is plugged into, when it's connected.
    public var machineOn: String?
    /// The code the other Mac runs, while linked.
    public var peerCode: CodeVersion?

    public init(
        hubConnected: Bool, agentConnected: Bool, via: Role, hubName: String? = nil, agentName: String? = nil, machineOn: String? = nil, peerCode: CodeVersion? = nil
    ) {
        self.peerCode = peerCode
        self.hubConnected = hubConnected
        self.agentConnected = agentConnected
        self.via = via
        self.hubName = hubName
        self.agentName = agentName
        self.machineOn = machineOn
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public var link: LinkState
    public var machine: MachineState
    public var job: JobState
    public var library: [LibraryItem]
    public var folders: [String]
    public var libraryRoot: String?
    public var macros: [Macro]
    public var config: MachineConfig
    public var console: [ConsoleLine]

    public init(
        link: LinkState, machine: MachineState, job: JobState, library: [LibraryItem], folders: [String], libraryRoot: String?, macros: [Macro],
        config: MachineConfig, console: [ConsoleLine]
    ) {
        self.link = link
        self.machine = machine
        self.job = job
        self.library = library
        self.folders = folders
        self.libraryRoot = libraryRoot
        self.macros = macros
        self.config = config
        self.console = console
    }
}
