// The file library (2.0): every G-code file's content lives in the blob store, and what the
// library knows about it (folder, name, group, source, history, Trash) lives in SQLite. The
// Finder folder ~/Documents/SwarfGRBL is a working copy of it, kept in step both ways:
// the library writes files there, and a scan turns Finder drops, renames, moves, edits and
// deletes into library changes. Each change to a file's fields gets a version stamp and an entry
// in the change log, which the Mac-to-Mac sync (phase 4) replays on the other Mac.
//
// Port of packages/hub/src/library.ts, with history, a Trash and stable ids added.

import Foundation
import SGCore

public struct LibraryOptions: Sendable {
    /// Database and blobs (the app uses ~/Library/Application Support/SwarfGRBL).
    public var dataDir: URL
    /// The Finder folder (the app uses ~/Documents/SwarfGRBL).
    public var root: URL
    /// A file changed more recently than this is still being written; look again later.
    public var settleMs: Double
    /// Non-G-code leftovers in a deleted folder go to the macOS Trash (else <root>/.Deleted).
    public var systemTrash: Bool
    /// 1.0's hub data, imported on the first start.
    public var importV1: V1Paths?

    public init(dataDir: URL, root: URL, settleMs: Double = 1000, systemTrash: Bool = false, importV1: V1Paths? = nil) {
        self.dataDir = dataDir
        self.root = root
        self.settleMs = settleMs
        self.systemTrash = systemTrash
        self.importV1 = importV1
    }
}

public struct V1Paths: Sendable {
    /// 1.0's ~/Library/Application Support/GCodeController/hub (macros.json, config.json).
    public var dataDir: URL
    /// 1.0's library folder (its index is .gcode-controller.json there).
    public var libraryDir: URL
    public init(dataDir: URL, libraryDir: URL) {
        self.dataDir = dataDir
        self.libraryDir = libraryDir
    }
}

public struct AddOptions: Sendable {
    public var name: String
    public var source: String?
    public var group: String?
    public var groupIndex: Int?
    /// Folder to save into. Default: the group's name for a group, otherwise the top level.
    public var folder: String?
    public init(name: String, source: String? = nil, group: String? = nil, groupIndex: Int? = nil, folder: String? = nil) {
        self.name = name
        self.source = source
        self.group = group
        self.groupIndex = groupIndex
        self.folder = folder
    }
}

public struct TrashItem: Sendable, Equatable {
    public var item: LibraryItem
    /// ms since 1970.
    public var deletedAt: Double
}

/// An earlier content of a file.
public struct FileVersion: Sendable, Equatable {
    public var sha256: String
    public var source: String
    public var size: Int
    /// When it stopped being the current content, ms since 1970.
    public var replacedAt: Double
}

public enum LibraryEvent: Sendable {
    case changed
}

/// One entry in the change log: a field of something in the library, its new value (JSON), and
/// the stamp of the value it replaced.
public struct LibraryChange: Sendable, Equatable {
    public var seq: Int
    public var stamp: Stamp
    public var entity: String
    public var id: String
    public var field: String
    public var value: String
    public var base: Stamp?
}

public let defaultMacros: [Macro] = [
    Macro(id: "lift-z", name: "Lift Z 10 mm", gcode: "G91 G0 Z10\nG90"),
    Macro(id: "park", name: "Park at back corner", gcode: "G53 G0 Z-2\nG53 G0 X-5 Y-5"),
    Macro(id: "spindle-off", name: "Spindle off", gcode: "M5"),
    Macro(id: "modal", name: "Show modal state", gcode: "$G"),
]

struct Entry {
    var id: String
    var folder: String
    var name: String
    var sha: String
    var source: String
    var group: String?
    var groupIndex: Int?
    var addedAt: Double
    var changedAt: Double
    var deletedAt: Double?
    var stamps: [String: String]
    /// Sync: a file from the other Mac waiting on a same-path conflict. Not listed or written out.
    var parked = false
    var path: String { joinPath(folder, name) }
    var isLive: Bool { deletedAt == nil && !parked }
}

/// What the library last wrote to (or read from) a path in the Finder folder.
struct DiskRow {
    var path: String
    var entryId: String
    var sha: String
    var size: Int64
    var mtime: Int64
}

struct Analysis: Codable {
    /// Bumped when the analysis gains something, so cached rows from an older build are worked out again.
    static let current = 3
    var version: Int?
    var size: Int
    var sourceLines: Int
    var streamLines: Int
    var bounds: Bounds?
    var cutBounds: Bounds?
    var estSeconds: Double
    var spindleOffCut: Int?
    var zZero: ZZeroReference?
}

public actor Library {
    /// History: a file keeps its last 5 earlier versions, none older than 30 days.
    public static let historyKeep = 5
    public static let historyDays = 30.0
    /// Deleted files stay in the Trash for 30 days.
    public static let trashDays = 30.0

    public nonisolated let options: LibraryOptions
    public nonisolated let replica: String
    public nonisolated var root: URL { options.root }

    let db: Database
    let blobs: BlobStore
    var clock: HybridClock
    /// Content a running job is using, by sha: never garbage-collected.
    var pinned: [String: Int] = [:]
    /// Files that aren't G-code, by path and mtime, so they aren't re-read every scan.
    var ignored: [String: Int64] = [:]
    var watcher: FolderWatcher?
    var tasks: [Task<Void, Never>] = []
    var retryTask: Task<Void, Never>?
    var listeners: [UUID: AsyncStream<LibraryEvent>.Continuation] = [:]

    /// Open (creating if needed) the library, import 1.0's on the first start, and catch up with
    /// whatever changed in the Finder folder while the app wasn't running.
    public static func open(_ options: LibraryOptions) async throws -> Library {
        let lib = try Library(options)
        try await lib.start()
        return lib
    }

    init(_ options: LibraryOptions) throws {
        self.options = options
        let fm = FileManager.default
        try fm.createDirectory(at: options.dataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: options.root, withIntermediateDirectories: true)
        let db = try Database(path: options.dataDir.appending(path: "library.sqlite").path)
        try migrate(db)
        let replica = try db.query("SELECT value FROM meta WHERE key='replica'").first?.string("value") ?? randomId(8)
        try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES('replica', ?)", [replica])
        let last = try db.query("SELECT value FROM meta WHERE key='clock'").first?.string("value").flatMap(Stamp.init)
        self.db = db
        self.replica = replica
        self.clock = HybridClock(replica: replica, last: last)
        self.blobs = try BlobStore(dir: options.dataDir.appending(path: "blobs"))
    }

    func start() throws {
        if let v1 = options.importV1 { try importV1IfNeeded(v1) }
        _ = try db.transaction { try scan() }
        _ = try db.transaction { try materialize() }
        if (try? db.query("SELECT 1 FROM config WHERE key='machine'").isEmpty) ?? true {
            try db.transaction { try storeConfig(MachineConfig.defaults) }
        }
    }

    // MARK: - Reading

    /// Every file, by folder, newest first within each.
    public func items() -> [LibraryItem] {
        sortItems(entries("deletedAt IS NULL AND parked=0").compactMap(item))
    }

    public func item(_ id: String) -> LibraryItem? {
        entry(id).flatMap { $0.isLive ? item($0) : nil }
    }

    public func content(_ id: String) -> Data? {
        guard let e = entry(id), e.isLive else { return nil }
        return blobs.get(e.sha)
    }

    /// Content by hash: a pinned job's file, or an earlier version.
    public func content(sha: String) -> Data? { blobs.get(sha) }

    public func folders() -> [String] {
        let rows = (try? db.query("SELECT path FROM folders WHERE deleted=0")) ?? []
        return rows.compactMap { $0.string("path") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func filesIn(_ folder: String) -> [LibraryItem] {
        items().filter { isInFolder($0.folder, folder) }
    }

    public func trash() -> [TrashItem] {
        entries("deletedAt IS NOT NULL ORDER BY deletedAt DESC").compactMap { e in
            item(e).map { TrashItem(item: $0, deletedAt: e.deletedAt!) }
        }
    }

    /// A file's earlier versions, newest first.
    public func versions(_ id: String) -> [FileVersion] {
        let rows = (try? db.query(
            "SELECT v.sha, v.source, v.replacedAt, a.json FROM versions v LEFT JOIN analysis a ON a.sha=v.sha WHERE entryId=? ORDER BY replacedAt DESC",
            [id])) ?? []
        return rows.map { r in
            let size = r.string("json").flatMap { try? JSONDecoder().decode(Analysis.self, from: Data($0.utf8)) }?.size ?? 0
            return FileVersion(sha256: r.string("sha")!, source: r.string("source")!, size: size, replacedAt: r.double("replacedAt")!)
        }
    }

    /// The change log since a sequence number (sync reads it; tests check it).
    public func changes(after seq: Int = 0) -> [LibraryChange] {
        let rows = (try? db.query("SELECT * FROM changes WHERE seq>? ORDER BY seq", [seq])) ?? []
        return rows.map { r in
            LibraryChange(
                seq: r.int("seq")!, stamp: Stamp(r.string("stamp")!)!, entity: r.string("entity")!, id: r.string("id")!,
                field: r.string("field")!, value: r.string("value")!, base: r.string("base").flatMap(Stamp.init))
        }
    }

    // MARK: - Files

    @discardableResult
    public func add(_ content: Data, _ o: AddOptions) throws -> LibraryItem {
        if content.isEmpty { throw LibraryError("The file is empty") }
        if content.contains(0) { throw LibraryError("That doesn't look like a G-code text file") }
        let folder = try o.folder.map { try checkFolder($0, allowRoot: true) } ?? o.group.map(folderName) ?? ""
        let name = withGcodeExtension(sanitizeName(o.name))
        let sha = sha256Hex(content)
        guard try analysis(sha, content) != nil else { throw LibraryError("The file has no G-code in it") }
        try blobs.put(content, sha: sha)
        let id: String = try mutate {
            try ensureFolder(folder)
            let now = nowMs()
            if var e = liveEntry(folder: folder, name: name) {
                // The same name again: a re-export replaces the content, keeping the old in history.
                if e.sha != sha { try replaceContent(&e, sha: sha, source: o.source ?? e.source, now: now) }
                if let s = o.source, s != e.source {
                    try change(&e, "source", s)
                    e.source = s
                }
                let group = o.group ?? e.group, index = o.groupIndex ?? e.groupIndex
                if group != e.group || index != e.groupIndex {
                    try change(&e, "group", GroupValue(group: group, index: index))
                    (e.group, e.groupIndex) = (group, index)
                }
                try change(&e, "added", now)
                e.addedAt = now
                try save(e)
                return e.id
            }
            let e = Entry(
                id: UUID().uuidString.lowercased(), folder: folder, name: name, sha: sha, source: o.source ?? "Upload",
                group: (o.group?.isEmpty ?? true) ? nil : o.group, groupIndex: o.groupIndex, addedAt: now, changedAt: now,
                deletedAt: nil, stamps: [:])
            try create(e)
            return e.id
        }
        return item(id)!
    }

    /// To the Trash.
    public func delete(_ id: String) throws {
        try mutate {
            var e = try requireLive(id)
            try setDeleted(&e, nowMs())
        }
    }

    /// Back from the Trash, under a new name if its old one has been taken since.
    public func restore(_ id: String) throws {
        try mutate {
            guard var e = entry(id), e.deletedAt != nil else { throw LibraryError("That file isn't in the Trash") }
            try ensureFolder(e.folder)
            if liveEntry(folder: e.folder, name: e.name) != nil {
                let name = freeName(e.name, in: e.folder)
                try setPath(&e, e.folder, name)
            }
            try setDeleted(&e, nil)
        }
    }

    /// Delete forever (from the Trash).
    public func purge(_ id: String) throws {
        try mutate {
            guard let e = entry(id), e.deletedAt != nil else { throw LibraryError("That file isn't in the Trash") }
            try purgeEntry(e)
        }
    }

    public func emptyTrash() throws {
        try mutate {
            for e in entries("deletedAt IS NOT NULL") { try purgeEntry(e) }
        }
        gcBlobs()
    }

    public func renameFile(_ id: String, _ newName: String) throws {
        try mutate {
            var e = try requireLive(id)
            var name = sanitizeName(newName)
            if !isGcodeName(name) {
                let ext = fileExtension(e.name)
                name += ext.isEmpty ? ".nc" : String(e.name.suffix(ext.count))
            }
            if name == e.name { return }
            if let other = liveEntry(folder: e.folder, name: name), other.id != e.id {
                throw LibraryError("There is already a file called \(name) in this folder")
            }
            try setPath(&e, e.folder, name)
        }
    }

    public func moveFile(_ id: String, to folder: String) throws {
        try mutate {
            var e = try requireLive(id)
            let target = try checkFolder(folder, allowRoot: true)
            if target == e.folder { return }
            if !target.isEmpty && !folderExists(target) { throw LibraryError("The folder \(target) doesn't exist") }
            try setPath(&e, target, freeName(e.name, in: target))
        }
    }

    /// Bring back an earlier version; the current one goes into history in its place.
    public func restoreVersion(_ id: String, sha: String) throws {
        try mutate {
            var e = try requireLive(id)
            guard let v = versions(id).first(where: { $0.sha256 == sha }) else { throw LibraryError("That version isn't kept any more") }
            guard blobs.has(sha) else { throw LibraryError("That version's content is missing") }
            try db.run("DELETE FROM versions WHERE entryId=? AND sha=?", [id, sha])
            try replaceContent(&e, sha: sha, source: v.source, now: nowMs())
            try save(e)
        }
    }

    // MARK: - Folders

    public func createFolder(_ path: String) throws {
        let folder = try checkFolder(path)
        try mutate {
            if folderExists(folder) { throw LibraryError("\(folder) already exists") }
            try ensureFolder(folder)
        }
    }

    /// Rename or move a folder (`to` is the full new path).
    public func renameFolder(_ path: String, to: String) throws {
        let from = try checkFolder(path)
        let target = try checkFolder(to)
        if from == target { return }
        if target.hasPrefix("\(from)/") { throw LibraryError("A folder can't be moved inside itself") }
        try mutate {
            if !folderExists(from) { throw LibraryError("The folder \(from) doesn't exist") }
            if folderExists(target) { throw LibraryError("\(target) already exists") }
            func moved(_ f: String) -> String { target + f.dropFirst(from.count) }
            try ensureFolder(target)
            for f in folders() where isInFolder(f, from) {
                try ensureFolder(moved(f))
                try setFolderDeleted(f, true)
            }
            for var e in entries("deletedAt IS NULL AND parked=0") where isInFolder(e.folder, from) {
                try setPath(&e, moved(e.folder), e.name)
            }
            for row in diskRows() where isInFolder((row.path as NSString).deletingLastPathComponent, from) {
                try db.run("UPDATE disk SET path=? WHERE path=?", [moved(row.path), row.path])
            }
            // Move the real folder, so anything else in it (notes, images) goes along too.
            let fm = FileManager.default
            let src = root.appending(path: from), dst = root.appending(path: target)
            if fm.fileExists(atPath: src.path) {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst) // throwing undoes the database changes above
            }
        }
    }

    /// The folder and everything in it go to the Trash.
    public func deleteFolder(_ path: String) throws {
        let folder = try checkFolder(path)
        try mutate {
            if !folderExists(folder) { throw LibraryError("The folder \(folder) doesn't exist") }
            let now = nowMs()
            for var e in entries("deletedAt IS NULL AND parked=0") where isInFolder(e.folder, folder) { try setDeleted(&e, now) }
            for f in folders() where isInFolder(f, folder) { try setFolderDeleted(f, true) }
        }
    }

    // MARK: - Macros and config

    public func macros() -> [Macro] {
        let rows = (try? db.query("SELECT id, name, gcode FROM macros WHERE deleted=0 ORDER BY position")) ?? []
        return rows.map { Macro(id: $0.string("id")!, name: $0.string("name")!, gcode: $0.string("gcode")!) }
    }

    public func saveMacro(_ m: Macro) throws {
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw LibraryError("The macro needs a name") }
        let macro = Macro(id: m.id.isEmpty ? randomId(8) : m.id, name: name, gcode: m.gcode)
        try db.transaction { try storeMacro(macro) }
        notify()
    }

    public func deleteMacro(_ id: String) throws {
        try db.transaction {
            guard let row = try db.query("SELECT stamp FROM macros WHERE id=? AND deleted=0", [id]).first else { return }
            let s = try record("macro", id, "deleted", true, base: row.string("stamp"))
            try db.run("UPDATE macros SET deleted=1, stamp=? WHERE id=?", [s, id])
        }
        notify()
    }

    public func config() -> MachineConfig {
        guard let json = try? db.query("SELECT value FROM config WHERE key='machine'").first?.string("value"),
              let c = try? JSONDecoder().decode(MachineConfig.self, from: Data(json.utf8))
        else { return .defaults }
        return c
    }

    @discardableResult
    public func saveConfig(_ patch: MachineConfigPatch) throws -> MachineConfig {
        var c = config()
        c.apply(patch)
        try db.transaction { try storeConfig(c) }
        notify()
        return c
    }

    // MARK: - Jobs, upkeep, watching

    /// Keep this content while a job runs from it, whatever happens to the file meanwhile.
    public func pin(_ sha: String) { pinned[sha, default: 0] += 1 }

    public func unpin(_ sha: String) {
        if let n = pinned[sha] { pinned[sha] = n > 1 ? n - 1 : nil }
    }

    /// Forget versions past the history limit and Trash past 30 days, then delete content nothing uses.
    public func maintenance(now: Double = nowMs()) throws {
        let day = 86_400_000.0
        try db.transaction {
            let ids = try db.query("SELECT DISTINCT entryId FROM versions").compactMap { $0.string("entryId") }
            for id in ids { try pruneVersions(id, now: now) }
        }
        let old = entries("deletedAt IS NOT NULL AND deletedAt < \(now - Library.trashDays * day)")
        if !old.isEmpty {
            try db.transaction { for e in old { try purgeEntry(e) } }
            notify()
        }
        gcBlobs()
    }

    /// Changes from the Finder folder, as they happen (FSEvents), and a full look every so often.
    public func watch(pollSeconds: Double = 15) {
        guard watcher == nil else { return }
        let w = FolderWatcher(path: root.path)
        w.start()
        watcher = w
        tasks.append(Task { [weak self] in
            for await _ in w.nudges {
                try? await Task.sleep(for: .milliseconds(300))
                await self?.backgroundRescan()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollSeconds))
                await self?.backgroundRescan()
            }
        })
    }

    public func close() {
        watcher?.stop()
        watcher = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        retryTask?.cancel()
        listeners.values.forEach { $0.finish() }
        listeners = [:]
    }

    /// `.changed` whenever the library changes, Finder edits included.
    public func events() -> AsyncStream<LibraryEvent> {
        let (stream, c) = AsyncStream.makeStream(of: LibraryEvent.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    func notify() { listeners.values.forEach { $0.yield(.changed) } }

    /// Bring the library in line with the Finder folder. Returns true if anything changed.
    @discardableResult
    public func rescan() -> Bool {
        let changed = (try? db.transaction { try scan() }) ?? false
        if changed { notify() }
        return changed
    }

    func backgroundRescan() { rescan() }

    func scheduleRetry() {
        guard retryTask == nil else { return }
        let ms = max(options.settleMs, 100) + 200
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            await self?.retryDone()
        }
    }

    private func retryDone() {
        retryTask = nil
        rescan()
    }

    // MARK: - Internals: entries and the change log

    /// Catch up with Finder, make the change, then write it out to the Finder folder.
    @discardableResult
    func mutate<T>(_ body: () throws -> T) throws -> T {
        _ = try? db.transaction { try scan() }
        let r = try db.transaction { try body() }
        _ = try db.transaction { try materialize() }
        notify()
        return r
    }

    func entries(_ whereClause: String, _ args: [Any?] = []) -> [Entry] {
        ((try? db.query("SELECT * FROM entries WHERE \(whereClause)", args)) ?? []).map(entry(row:))
    }

    func entry(_ id: String) -> Entry? { entries("id=?", [id]).first }

    func liveEntry(folder: String, name: String) -> Entry? {
        entries("deletedAt IS NULL AND parked=0 AND folder=? AND name=? COLLATE NOCASE", [folder, name]).first
    }

    func requireLive(_ id: String) throws -> Entry {
        guard let e = entry(id), e.isLive else { throw LibraryError("File not found") }
        return e
    }

    private func entry(row r: Row) -> Entry {
        Entry(
            id: r.string("id")!, folder: r.string("folder")!, name: r.string("name")!, sha: r.string("sha")!,
            source: r.string("source")!, group: r.string("grp"), groupIndex: r.int("grpIndex"), addedAt: r.double("addedAt")!,
            changedAt: r.double("changedAt")!, deletedAt: r.double("deletedAt"),
            stamps: (try? JSONDecoder().decode([String: String].self, from: Data(r.string("stamps")!.utf8))) ?? [:],
            parked: r.int("parked") == 1)
    }

    func save(_ e: Entry) throws {
        try db.run(
            """
            INSERT INTO entries(id, folder, name, sha, source, grp, grpIndex, addedAt, changedAt, deletedAt, stamps, parked)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET folder=excluded.folder, name=excluded.name, sha=excluded.sha,
              source=excluded.source, grp=excluded.grp, grpIndex=excluded.grpIndex, addedAt=excluded.addedAt,
              changedAt=excluded.changedAt, deletedAt=excluded.deletedAt, stamps=excluded.stamps, parked=excluded.parked
            """,
            [e.id, e.folder, e.name, e.sha, e.source, e.group, e.groupIndex, e.addedAt, e.changedAt, e.deletedAt, json(e.stamps), e.parked])
    }

    /// A new entry: one change carrying every field.
    func create(_ e: Entry) throws {
        var e = e
        let snapshot = EntrySnapshot(e)
        let s = try record("entry", e.id, "create", snapshot, base: nil)
        e.stamps = Dictionary(uniqueKeysWithValues: EntrySnapshot.fields.map { ($0, s) })
        try save(e)
    }

    /// Record a new value for one field of an entry (the caller sets the field and saves).
    func change(_ e: inout Entry, _ field: String, _ value: some Encodable) throws {
        e.stamps[field] = try record("entry", e.id, field, value, base: e.stamps[field])
        e.changedAt = nowMs()
    }

    func setPath(_ e: inout Entry, _ folder: String, _ name: String) throws {
        try change(&e, "path", PathValue(folder: folder, name: name))
        (e.folder, e.name) = (folder, name)
        try save(e)
    }

    func setDeleted(_ e: inout Entry, _ at: Double?) throws {
        try change(&e, "deleted", at)
        e.deletedAt = at
        try save(e)
    }

    /// New content for a file; what it had goes into its history.
    func replaceContent(_ e: inout Entry, sha: String, source: String, now: Double) throws {
        try db.run("INSERT INTO versions(entryId, sha, source, replacedAt) VALUES(?,?,?,?)", [e.id, e.sha, e.source, now])
        try change(&e, "content", sha)
        e.sha = sha
        if source != e.source {
            try change(&e, "source", source)
            e.source = source
        }
        try save(e)
        try pruneVersions(e.id, now: now)
    }

    func pruneVersions(_ id: String, now: Double) throws {
        let cutoff = now - Library.historyDays * 86_400_000
        try db.run(
            """
            DELETE FROM versions WHERE entryId=? AND (replacedAt < ? OR rowid NOT IN
              (SELECT rowid FROM versions WHERE entryId=? ORDER BY replacedAt DESC LIMIT ?))
            """, [id, cutoff, id, Library.historyKeep])
    }

    func purgeEntry(_ e: Entry) throws {
        _ = try record("entry", e.id, "purged", true, base: e.stamps["deleted"])
        try db.run("DELETE FROM entries WHERE id=?", [e.id])
        try db.run("DELETE FROM versions WHERE entryId=?", [e.id])
    }

    /// Append to the change log; returns the new stamp.
    func record(_ entity: String, _ id: String, _ field: String, _ value: some Encodable, base: String?) throws -> String {
        let s = clock.tick().description
        try db.run(
            "INSERT INTO changes(stamp, entity, id, field, value, base, origin) VALUES(?,?,?,?,?,?,?)",
            [s, entity, id, field, json(value), base, replica])
        try db.run("INSERT INTO meta(key, value) VALUES('clock', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [s])
        return s
    }

    func folderExists(_ path: String) -> Bool {
        ((try? db.query("SELECT 1 FROM folders WHERE path=? AND deleted=0", [path]))?.isEmpty == false)
    }

    /// The folder and its parents exist.
    func ensureFolder(_ path: String) throws {
        for f in folderAndAncestors(path) where !folderExists(f) { try setFolderDeleted(f, false) }
    }

    func setFolderDeleted(_ path: String, _ deleted: Bool) throws {
        let base = try db.query("SELECT stamp FROM folders WHERE path=?", [path]).first?.string("stamp")
        let s = try record("folder", path, "deleted", deleted, base: base)
        try db.run(
            "INSERT INTO folders(path, deleted, stamp) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET deleted=excluded.deleted, stamp=excluded.stamp",
            [path, deleted, s])
    }

    /// A name not used by another file in the folder (in the library or on disk).
    func freeName(_ name: String, in folder: String) -> String {
        uniqueName(name) { candidate in
            liveEntry(folder: folder, name: candidate) != nil
                || FileManager.default.fileExists(atPath: root.appending(path: joinPath(folder, candidate)).path)
        }
    }

    func storeMacro(_ m: Macro) throws {
        let existing = try db.query("SELECT position, stamp FROM macros WHERE id=?", [m.id]).first
        let position = try existing?.int("position")
            ?? (db.query("SELECT COALESCE(MAX(position), -1) + 1 AS p FROM macros").first?.int("p") ?? 0)
        let s = try record("macro", m.id, "value", m, base: existing?.string("stamp"))
        try db.run(
            """
            INSERT INTO macros(id, name, gcode, position, deleted, stamp) VALUES(?,?,?,?,0,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, gcode=excluded.gcode, deleted=0, stamp=excluded.stamp
            """, [m.id, m.name, m.gcode, position, s])
    }

    func storeConfig(_ c: MachineConfig) throws {
        let base = try db.query("SELECT stamp FROM config WHERE key='machine'").first?.string("stamp")
        let s = try record("config", "machine", "value", c, base: base)
        try db.run(
            "INSERT INTO config(key, value, stamp) VALUES('machine', ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, stamp=excluded.stamp",
            [json(c), s])
    }

    // MARK: - Internals: analysis and items

    /// Line counts, bounds and run time, worked out once per content.
    func analysis(_ sha: String, _ data: Data? = nil) throws -> Analysis? {
        let cached = try db.query("SELECT json FROM analysis WHERE sha=?", [sha]).first?.string("json")
            .flatMap { try? JSONDecoder().decode(Analysis.self, from: Data($0.utf8)) }
        if let cached, cached.version == Analysis.current { return cached }
        // An older build's row: work it out again, or keep it while the content hasn't arrived from the other Mac.
        guard let data = data ?? blobs.get(sha), !data.isEmpty, !data.contains(0) else { return cached }
        let text = String(decoding: data, as: UTF8.self)
        let a = analyzeProgram(text, options: InterpreterOptions(rapidRate: config().rapidRate), keepSegments: false)
        guard a.streamLines > 0 else { return nil }
        let result = Analysis(
            version: Analysis.current, size: data.count, sourceLines: a.sourceLines, streamLines: a.streamLines, bounds: a.bounds,
            cutBounds: a.cutBounds, estSeconds: a.estSeconds, spindleOffCut: a.spindleOffCut, zZero: a.zZero)
        try db.run("INSERT OR REPLACE INTO analysis(sha, json) VALUES(?, ?)", [sha, json(result)])
        return result
    }

    func item(_ e: Entry) -> LibraryItem? {
        guard let a = try? analysis(e.sha) else { return nil }
        return LibraryItem(
            id: e.id, name: e.name, folder: e.folder, source: e.source, size: a.size, sha256: e.sha, addedAt: e.addedAt,
            sourceLines: a.sourceLines, streamLines: a.streamLines, bounds: a.bounds, cutBounds: a.cutBounds,
            estSeconds: a.estSeconds, group: e.group, groupIndex: e.groupIndex, spindleOffCut: a.spindleOffCut, zZero: a.zZero)
    }

    func gcBlobs() {
        guard let rows = try? db.query(
            "SELECT sha FROM entries UNION SELECT sha FROM versions UNION SELECT sha FROM conflicts WHERE sha IS NOT NULL")
        else { return }
        var keep = Set(rows.compactMap { $0.string("sha") })
        keep.formUnion(pinned.keys)
        for sha in blobs.all() where !keep.contains(sha) { blobs.remove(sha) }
        _ = try? db.run("DELETE FROM analysis WHERE sha NOT IN (SELECT sha FROM entries UNION SELECT sha FROM versions)")
    }
}

/// Newest first within each folder; folders in name order.
func sortItems(_ items: [LibraryItem]) -> [LibraryItem] {
    items.sorted { a, b in
        if a.folder != b.folder { return a.folder.localizedStandardCompare(b.folder) == .orderedAscending }
        return a.addedAt > b.addedAt
    }
}

struct PathValue: Codable {
    var folder: String
    var name: String
}

struct GroupValue: Codable {
    var group: String?
    var index: Int?
}

/// Every syncable field of an entry, for its "create" change.
struct EntrySnapshot: Codable {
    static let fields = ["path", "content", "source", "group", "added", "deleted"]
    var folder: String
    var name: String
    var sha: String
    var source: String
    var group: String?
    var groupIndex: Int?
    var addedAt: Double
    init(_ e: Entry) {
        (folder, name, sha, source, group, groupIndex, addedAt) = (e.folder, e.name, e.sha, e.source, e.group, e.groupIndex, e.addedAt)
    }
}

func json(_ value: some Encodable) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    return (try? enc.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

func migrate(_ db: Database) throws {
    if db.userVersion < 1 { try migrate1(db) }
    if db.userVersion < 2 {
        // Sync (phase 4): who made each change (indexed, for "what haven't you seen"), parked
        // same-path arrivals, and what a conflict's other side is.
        try db.transaction {
            try db.exec(
                """
                ALTER TABLE changes ADD COLUMN origin TEXT;
                UPDATE changes SET origin=substr(stamp, 23);
                CREATE UNIQUE INDEX changes_stamp ON changes(stamp);
                CREATE INDEX changes_origin ON changes(origin, stamp);
                ALTER TABLE entries ADD COLUMN parked INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE conflicts ADD COLUMN otherId TEXT;
                ALTER TABLE conflicts ADD COLUMN sha TEXT;
                PRAGMA user_version = 2;
                """)
        }
    }
}

private func migrate1(_ db: Database) throws {
    try db.transaction {
        try db.exec(
            """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE entries(
              id TEXT PRIMARY KEY, folder TEXT NOT NULL, name TEXT NOT NULL, sha TEXT NOT NULL, source TEXT NOT NULL,
              grp TEXT, grpIndex INTEGER, addedAt REAL NOT NULL, changedAt REAL NOT NULL, deletedAt REAL,
              stamps TEXT NOT NULL DEFAULT '{}');
            CREATE INDEX entries_path ON entries(folder, name);
            CREATE TABLE analysis(sha TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE versions(entryId TEXT NOT NULL, sha TEXT NOT NULL, source TEXT NOT NULL, replacedAt REAL NOT NULL);
            CREATE INDEX versions_entry ON versions(entryId);
            CREATE TABLE folders(path TEXT PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0, stamp TEXT NOT NULL);
            CREATE TABLE macros(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, gcode TEXT NOT NULL, position INTEGER NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0, stamp TEXT NOT NULL);
            CREATE TABLE config(key TEXT PRIMARY KEY, value TEXT NOT NULL, stamp TEXT NOT NULL);
            CREATE TABLE changes(
              seq INTEGER PRIMARY KEY AUTOINCREMENT, stamp TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
              field TEXT NOT NULL, value TEXT NOT NULL, base TEXT);
            CREATE TABLE conflicts(
              id TEXT PRIMARY KEY, entryId TEXT, kind TEXT NOT NULL, detail TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE TABLE disk(
              path TEXT PRIMARY KEY, entryId TEXT NOT NULL, sha TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL);
            PRAGMA user_version = 1;
            """)
        // Built-in macros, stamped as the epoch so any real edit (from either Mac) wins.
        for (i, m) in defaultMacros.enumerated() {
            try db.run(
                "INSERT INTO macros(id, name, gcode, position, deleted, stamp) VALUES(?,?,?,?,0,?)",
                [m.id, m.name, m.gcode, i, Stamp(ms: 0, counter: 0, replica: "default").description])
        }
    }
}
