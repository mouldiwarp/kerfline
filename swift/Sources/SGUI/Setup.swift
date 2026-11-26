// How this Mac runs: Hub or Agent, its name, where its machine is, and (until the cut-over) whether
// it's a trial alongside 1.0. Kept in UserDefaults; chosen on first launch, changed in Settings.

import Foundation
import SGCore
import SGLibrary
import SGMachine
import SGNet

public enum MachineKind: String, Codable, CaseIterable, Sendable {
    /// The FoxAlien on a USB port of this Mac (found automatically).
    case usb
    /// The built-in GRBL simulator, for trying things out.
    case simulator
    /// No machine here; the other Mac has it.
    case none

    public var label: String {
        switch self {
        case .usb: "USB (FoxAlien plugged into this Mac)"
        case .simulator: "Simulator"
        case .none: "None (the other Mac has it)"
        }
    }
}

public struct AppSetup: Codable, Equatable, Sendable {
    public var role: Role
    public var name: String
    public var machine: MachineKind
    /// Agent: the hub as "host" or "host:port"; empty finds it with Bonjour.
    public var hubAddress: String
    /// Run alongside 1.0: its own port, folder, data and Bonjour service, so 1.0 is untouched.
    public var trial: Bool

    public init(role: Role, name: String, machine: MachineKind, hubAddress: String = "", trial: Bool = true) {
        self.role = role
        self.name = name
        self.machine = machine
        self.hubAddress = hubAddress
        self.trial = trial
    }

    /// A first guess for the role picker.
    public static func suggested() -> AppSetup {
        AppSetup(role: .hub, name: Host.current().localizedName ?? "This Mac", machine: .none)
    }

    static let key = "swarfgrbl.setup"

    /// Development: SG_HOME=<folder> puts every path (and the saved setup) under that folder, on its
    /// own port and Bonjour service, so it can run beside the installed app without either noticing.
    static let devHome: URL? = ProcessInfo.processInfo.environment["SG_HOME"].map { URL(filePath: $0) }
    public static var store: UserDefaults { devHome == nil ? .standard : UserDefaults(suiteName: "SwarfGRBL.dev")! }

    public static func load(_ defaults: UserDefaults = store) -> AppSetup? {
        if defaults === UserDefaults.standard { migrateDefaults(from: oldBundleIds, to: defaults) }
        return defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSetup.self, from: $0) }
    }

    /// The names this app ran under before SwarfGRBL: KerfLine releases and GCode Controller 2.0 builds from git.
    static let oldBundleIds = ["io.github.mouldiwarp.kerfline", "io.github.mouldiwarp.gcodecontroller2"]
    /// Their settings were `gcc.*`.
    static let oldPrefix = "gcc."

    /// The first time SwarfGRBL runs on a Mac that ran KerfLine or GCode Controller 2.0, bring its
    /// settings across (role, name, jog step, surfacing, open folders), so it carries on with the
    /// same library and link. Of several old apps, the one used last wins. Returns whether it did.
    @discardableResult
    static func migrateDefaults(from oldDomains: [String], to defaults: UserDefaults) -> Bool {
        guard devHome == nil, defaults.data(forKey: key) == nil else { return false }
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        func used(_ domain: String) -> Date {
            let a = try? FileManager.default.attributesOfItem(atPath: prefs.appending(path: domain + ".plist").path)
            return a?[.modificationDate] as? Date ?? .distantPast
        }
        let candidates = oldDomains.filter { $0 != Bundle.main.bundleIdentifier }.compactMap { d in
            UserDefaults.standard.persistentDomain(forName: d).flatMap { $0[oldPrefix + "setup"] != nil ? (d, $0) : nil }
        }
        guard let (_, old) = candidates.max(by: { used($0.0) < used($1.0) }) else { return false }
        for (k, v) in old where k.hasPrefix(oldPrefix) { defaults.set(v, forKey: "swarfgrbl." + k.dropFirst(oldPrefix.count)) }
        return true
    }

    /// The first time SwarfGRBL starts, move GCode Controller's library, data and inbox to their
    /// new names (paths in the database are relative to the library folder, so they carry over).
    /// Only when the old data exists and the new doesn't; 1.0's data (`hub`) stays where it was.
    /// The library folders go first and the data last, so if a move fails (Documents access refused,
    /// say) this run keeps to the old places and the next launch tries again. Returns what it moved.
    @discardableResult
    public static func migrateFolders(home: URL? = nil) -> [String] {
        let home = home ?? self.home
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: home.appending(path: p).path) }
        let data = [("\(oldSupportPath)/app", "\(supportPath)/app"), ("\(oldSupportPath)/app-trial", "\(supportPath)/app-trial")]
        guard data.contains(where: { exists($0.0) }), !exists(supportPath) else { return [] }
        let folders = [
            ("Documents/GCode Controller", "Documents/SwarfGRBL"), ("Documents/GCode Controller 2.0 Trial", "Documents/SwarfGRBL Trial"),
            ("GCode Inbox", "SwarfGRBL Inbox"), ("GCode Inbox 2.0 Trial", "SwarfGRBL Inbox Trial"),
        ]
        var moved: [String] = []
        for (from, to) in folders + data where exists(from) && !exists(to) {
            let b = home.appending(path: to)
            do {
                try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: home.appending(path: from), to: b)
                moved.append(to)
            } catch {
                // Nothing moved yet: stay on the old names this run, and try again next launch.
                if moved.isEmpty {
                    if home == self.home { legacyPaths = true }
                    return []
                }
            }
        }
        return moved
    }

    /// Set when the move to the new folder names failed part way: this run uses the old names.
    nonisolated(unsafe) static var legacyPaths = false

    /// build-app.sh leaves the old app names as links to SwarfGRBL, so a copy still running under an
    /// old name relaunches into it after updating itself. Once SwarfGRBL is running they're done with.
    public static func removeOldAppLinks() {
        guard devHome == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let fm = FileManager.default
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        for dir in [Bundle.main.bundleURL.deletingLastPathComponent(), fm.homeDirectoryForCurrentUser.appending(path: "Applications")] {
            for old in ["GCode Controller 2.0.app", "KerfLine.app"] {
                let link = dir.appending(path: old)
                guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                    link.resolvingSymlinksInPath().standardizedFileURL == me
                else { continue }
                try? fm.removeItem(at: link)
            }
        }
    }

    public func save(_ defaults: UserDefaults = AppSetup.store) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: AppSetup.key) }
    }

    // MARK: Where things live

    private static var home: URL { devHome ?? FileManager.default.homeDirectoryForCurrentUser }
    static let supportPath = "Library/Application Support/SwarfGRBL"
    /// GCode Controller's data folder: where 2.0 kept its data before SwarfGRBL, and 1.0 still does.
    static let oldSupportPath = "Library/Application Support/GCodeController"
    private static var support: URL { home.appending(path: legacyPaths ? oldSupportPath : supportPath) }

    /// The database and content blobs.
    public var dataDir: URL { AppSetup.support.appending(path: trial ? "app-trial" : "app") }
    /// The Finder folder.
    public var libraryRoot: URL { AppSetup.home.appending(path: AppSetup.legacyPaths ? (trial ? "Documents/GCode Controller 2.0 Trial" : "Documents/GCode Controller") : trial ? "Documents/SwarfGRBL Trial" : "Documents/SwarfGRBL") }
    /// Hub: files dropped here are imported.
    public var inbox: URL { AppSetup.home.appending(path: AppSetup.legacyPaths ? (trial ? "GCode Inbox 2.0 Trial" : "GCode Inbox") : trial ? "SwarfGRBL Inbox Trial" : "SwarfGRBL Inbox") }
    public var port: Int { AppSetup.devHome != nil ? defaultHubPort + 10 : trial ? defaultHubPort + 1 : defaultHubPort }
    public var serviceType: String { AppSetup.devHome != nil ? "_swarfgrbl-dev._tcp" : trial ? "_swarfgrbl-try._tcp" : hubServiceType }

    /// 1.0's hub library, imported (read only) on the hub's first start.
    public var v1: V1Paths? {
        guard role == .hub else { return nil }
        let p = V1Paths(dataDir: AppSetup.home.appending(path: AppSetup.oldSupportPath).appending(path: "hub"), libraryDir: AppSetup.home.appending(path: "Documents/GCode Controller"))
        return FileManager.default.fileExists(atPath: p.libraryDir.path) ? p : nil
    }

    /// Agent: the hub's link, or nil to find it with Bonjour.
    public var hubURL: URL? {
        let a = hubAddress.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return nil }
        if a.contains("://") { return URL(string: a) }
        let hostPort = a.contains(":") ? a : "\(a):\(port)"
        return URL(string: "ws://\(hostPort)/link")
    }

    public var machineOption: MachineOption {
        switch machine {
        case .usb: .serial(path: nil)
        case .simulator: .simulator(FakeGrblOptions())
        case .none: .none
        }
    }

    public var instanceOptions: InstanceOptions {
        InstanceOptions(
            name: name, role: role, port: port, serviceType: serviceType, hubURL: role == .agent ? hubURL : nil, machine: machineOption,
            inbox: role == .hub ? inbox : nil)
    }

    public var libraryOptions: LibraryOptions {
        LibraryOptions(dataDir: dataDir, root: libraryRoot, systemTrash: true, importV1: v1)
    }
}
