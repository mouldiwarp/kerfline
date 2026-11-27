// Questions the window asks of the state, as 1.0's store.ts and libraryUtil.ts.

import Foundation
import SGCore
import SGLibrary
import SGNet

public struct NextFile: Equatable, Sendable {
    public var id: String
    public var name: String
    /// 0-based index in the group.
    public var index: Int
    public var total: Int
}

extension AppState {
    /// The machine is connected (here or on the other Mac) and can take commands.
    public var machineReady: Bool { machine.connection == .connected }

    /// A job is streaming (not counting a group waiting for a bit change).
    public var jobActive: Bool { [.loading, .running, .paused, .stopping].contains(job.status) }

    /// The next file of a group waiting for a bit change.
    public var nextGroupFile: NextFile? {
        guard job.status == .toolchange, let g = job.group, g.index + 1 < g.files.count else { return nil }
        let f = g.files[g.index + 1]
        return NextFile(id: f.id, name: f.name, index: g.index + 1, total: g.files.count)
    }

    /// Moving, or probing (which counts as moving between its moves), so Hold and Stop stay available.
    public var moving: Bool { [.run, .jog, .home].contains(machine.status) || machine.probing == true }

    /// The machine is connected and in the middle of something: a job under way (paused or waiting for a bit
    /// change too), or GRBL moving, holding, homing or probing. "Keep the screen on during jobs" holds then.
    public var machineBusy: Bool { machineReady && (job.status.isActive || moving || machine.status == .hold) }

    /// Jog and the jog keys work.
    public var canJog: Bool { machineReady && !jobActive && [.idle, .jog].contains(machine.status) }

    /// The machine pill's text.
    public var machineLabel: String {
        switch machine.connection {
        case .connected: machine.status.rawValue
        case .connecting: "Connecting"
        case .disconnected: "No machine"
        }
    }

    /// Why Start is unavailable for the selected file, if it is.
    public func startHint(selected: LibraryItem?) -> String? {
        if !machineReady { return "Machine not connected" }
        if jobActive { return "A job is running" }
        if machine.status != .idle {
            return switch machine.status {
            case .alarm: "Machine is in alarm: Home or Unlock first"
            case .hold: "Machine is on hold"
            case .door: "The door is open"
            case .home: "Machine is homing"
            case .jog, .run: "Machine is moving"
            case .check: "Machine is in check mode"
            case .sleep: "Machine is asleep"
            default: "Machine isn't ready"
            }
        }
        if selected == nil { return "Select a file in the library" }
        return nil
    }
}

// MARK: The library tree

func baseName(_ folder: String) -> String {
    folder.split(separator: "/").last.map(String.init) ?? folder
}

func parentOf(_ folder: String) -> String {
    guard let i = folder.lastIndex(of: "/") else { return "" }
    return String(folder[..<i])
}

/// Folders directly inside `parent`.
func childFolders(_ folders: [String], _ parent: String) -> [String] {
    folders.filter { !$0.isEmpty && parentOf($0) == parent }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// Files directly in `folder`: groups together in run order, newest first otherwise.
func filesIn(_ library: [LibraryItem], _ folder: String) -> [LibraryItem] {
    library.filter { $0.folder == folder }.sorted { a, b in
        if let g = a.group, g == b.group { return (a.groupIndex ?? 0) < (b.groupIndex ?? 0) }
        return a.addedAt > b.addedAt
    }
}

/// Files in a folder and everything below it.
func countIn(_ library: [LibraryItem], _ folder: String) -> Int {
    library.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.count
}

/// "220×180×12.5"
func dims(_ f: LibraryItem) -> String {
    guard let b = f.cutBounds ?? f.bounds else { return "" }
    let d = b.max - b.min
    return "\(fixed(d.x, 0))×\(fixed(d.y, 0))×\(fixed(d.z, 1))"
}

func ago(_ ms: Double, now: Double = nowMs()) -> String {
    let s = (now - ms) / 1000
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
}

func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

extension ConflictKind {
    /// What happened, for the conflict list.
    public var summary: String {
        switch self {
        case .content: "Changed on both Macs"
        case .path: "Renamed or moved differently on each Mac"
        case .editDelete: "Changed here, deleted on the other Mac"
        case .deleteEdit: "Deleted here, changed on the other Mac"
        case .samePath: "A different file was added with the same name on each Mac"
        }
    }
}

/// SwiftUI's DeveloperToolsSupport also has a LibraryItem; ours wins in this module.
public typealias LibraryItem = SGCore.LibraryItem
/// SwiftUI has an Axis too; in this module it's the machine's.
public typealias Axis = SGCore.Axis
