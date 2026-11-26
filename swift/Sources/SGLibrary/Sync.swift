// Library sync, the library side: what this Mac has seen (a version vector), the changes the other
// Mac hasn't, applying the other Mac's changes, and the conflicts that can't be applied silently.
//
// Every change in the log keeps the stamp it was made with, on whichever Mac made it, and the
// stamp of the value it replaced (its base). A change whose base is the value here now simply
// applies. One whose base isn't was made while this Mac changed the same field:
//
//   path, content           a conflict (rename vs move; edited on both), unless both ended equal
//   source, group, added    newest wins
//   deleted                 newest wins, except a delete of a file edited here that the other
//                           Mac hadn't seen yet: that's an edit-vs-delete conflict (and the
//                           reverse: an edit arriving for a file deleted here)
//   create                  a different file already at that path: a same-path conflict, and
//                           the arrival is parked (kept, not listed) until it's resolved
//
// Folders, macros and the machine config are newest-wins. While a conflict is open each Mac keeps
// its own version. Resolving it on either Mac records a "resolve" change carrying the file's whole
// state, which the other Mac adopts, clearing the conflict there too.

import Foundation
import SGCore

public typealias VersionVector = [String: Stamp]

/// One change in the log, as sent to the other Mac.
public struct SyncChange: Codable, Sendable, Equatable {
    public var stamp: Stamp
    public var entity: String
    public var id: String
    public var field: String
    /// JSON.
    public var value: String
    public var base: Stamp?
}

public enum ConflictKind: String, Codable, Sendable {
    /// The file's content was changed on both Macs.
    case content
    /// Renamed or moved differently on each Mac.
    case path
    /// Edited here, deleted on the other Mac.
    case editDelete
    /// Deleted here, edited on the other Mac.
    case deleteEdit
    /// A different file was added at the same path on each Mac.
    case samePath
}

public enum ConflictChoice: String, Codable, Sendable {
    case keepMine, keepTheirs, keepBoth
}

/// One side of a conflict, for showing both side by side.
public struct ConflictSide: Sendable, Equatable {
    public var name: String
    public var folder: String
    public var sha256: String
    public var source: String
    /// Nil until the other Mac's content has arrived.
    public var size: Int?
    public var estSeconds: Double?
    /// When this side changed, ms since 1970.
    public var changedAt: Double
    public var deleted: Bool
}

public struct LibraryConflict: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ConflictKind
    /// The file (this Mac's) the conflict is about.
    public var entryId: String
    /// The other Mac's name.
    public var peer: String
    public var mine: ConflictSide
    public var theirs: ConflictSide
}

/// What a conflict remembers about the other Mac's side.
struct ConflictDetail: Codable {
    var field: String
    /// The other Mac's value (JSON).
    var theirs: String
    var stamp: Stamp
    var peer: String
}

/// The whole state of a file, as a conflict resolution leaves it.
struct ResolveValue: Codable {
    var snapshot: EntrySnapshot
    var deletedAt: Double?
}

/// Who sent a batch of changes, and how far they had seen this Mac's changes.
struct SyncPeer {
    var name: String
    var seenMine: Stamp?
}

private func decode<T: Decodable>(_ text: String, as: T.Type = T.self) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(text.utf8))
}

extension Library {
    // MARK: - What each side has

    /// The newest change seen from each Mac.
    public func versionVector() -> VersionVector {
        let rows = (try? db.query("SELECT origin, MAX(stamp) AS s FROM changes GROUP BY origin")) ?? []
        var v: VersionVector = [:]
        for r in rows {
            if let o = r.string("origin"), let s = r.string("s").flatMap(Stamp.init) { v[o] = s }
        }
        return v
    }

    /// The oldest `limit` changes not covered by `vector`, in stamp order (so a change always
    /// arrives after the ones it builds on).
    public func syncChanges(after vector: VersionVector, limit: Int = 500) -> [SyncChange] {
        let origins = ((try? db.query("SELECT DISTINCT origin FROM changes")) ?? []).compactMap { $0.string("origin") }
        var out: [SyncChange] = []
        for o in origins {
            let rows = (try? db.query(
                "SELECT * FROM changes WHERE origin=? AND stamp>? ORDER BY stamp LIMIT ?",
                [o, vector[o]?.description ?? "", limit])) ?? []
            out += rows.map { r in
                SyncChange(
                    stamp: Stamp(r.string("stamp")!)!, entity: r.string("entity")!, id: r.string("id")!,
                    field: r.string("field")!, value: r.string("value")!, base: r.string("base").flatMap(Stamp.init))
            }
        }
        return Array(out.sorted { $0.stamp < $1.stamp }.prefix(limit))
    }

    /// Content the library refers to but doesn't have yet: files (Trash included) and the other
    /// side of open conflicts.
    public func missingBlobs() -> [String] {
        let rows = (try? db.query("SELECT sha FROM entries UNION SELECT sha FROM conflicts WHERE sha IS NOT NULL")) ?? []
        return rows.compactMap { $0.string("sha") }.filter { !blobs.has($0) }.sorted()
    }

    /// Content from the other Mac: checked against its hash, stored, and written out.
    public func receiveBlob(_ data: Data, sha: String) throws {
        guard sha256Hex(data) == sha else { throw LibraryError("The file was corrupted in transfer (checksum mismatch)") }
        if blobs.has(sha) { return }
        try blobs.put(data, sha: sha)
        _ = try db.transaction { try materialize() }
        notify()
    }

    // MARK: - Applying the other Mac's changes

    /// Apply a batch of changes from the other Mac. Changes already here are skipped.
    func applySync(_ batch: [SyncChange], peer: SyncPeer) throws {
        _ = try? db.transaction { try scan() } // record Finder edits first, so they're compared, not lost
        try db.transaction {
            for c in batch {
                let s = c.stamp.description
                if try !db.query("SELECT 1 FROM changes WHERE stamp=?", [s]).isEmpty { continue }
                clock.observe(c.stamp)
                try db.run(
                    "INSERT INTO changes(stamp, entity, id, field, value, base, origin) VALUES(?,?,?,?,?,?,?)",
                    [s, c.entity, c.id, c.field, c.value, c.base?.description, c.stamp.replica])
                switch c.entity {
                case "entry": try applyEntry(c, peer)
                case "folder": try applyFolder(c)
                case "macro": try applyMacro(c)
                case "config": try applyConfig(c)
                default: break
                }
            }
            try db.run(
                "INSERT INTO meta(key, value) VALUES('clock', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [clock.last.description])
            // A folder deleted there while a file was added to it here stays.
            for folder in Set(entries("deletedAt IS NULL AND parked=0").map(\.folder)) { try ensureFolder(folder) }
        }
        _ = try db.transaction { try materialize() }
        notify()
    }

    private func applyEntry(_ c: SyncChange, _ peer: SyncPeer) throws {
        let s = c.stamp.description
        if c.field == "create" {
            guard entry(c.id) == nil, let snap = decode(c.value, as: EntrySnapshot.self) else { return }
            var e = Entry(
                id: c.id, folder: snap.folder, name: snap.name, sha: snap.sha, source: snap.source, group: snap.group,
                groupIndex: snap.groupIndex, addedAt: snap.addedAt, changedAt: Double(c.stamp.ms), deletedAt: nil,
                stamps: Dictionary(uniqueKeysWithValues: EntrySnapshot.fields.map { ($0, s) }))
            if var other = liveEntry(folder: e.folder, name: e.name) {
                if other.sha == e.sha {
                    // The same file added on both Macs: one entry, chosen the same way on both, stays.
                    if e.id < other.id {
                        other.parked = true
                        try save(other)
                    } else {
                        e.parked = true
                    }
                    try save(e)
                    return
                }
                e.parked = true
                try save(e)
                try addConflict(.samePath, entry: other.id, otherId: e.id, field: "create", theirs: c.value, sha: e.sha, c, peer)
            } else {
                try ensureFolder(e.folder)
                try save(e)
            }
            return
        }
        guard var e = entry(c.id) else { return } // purged here
        switch c.field {
        case "purged":
            if e.deletedAt != nil {
                try db.run("DELETE FROM entries WHERE id=?", [e.id])
                try db.run("DELETE FROM versions WHERE entryId=?", [e.id])
                try clearConflicts(e.id)
            }
            return
        case "resolve":
            guard let r = decode(c.value, as: ResolveValue.self) else { return }
            try adopt(&e, r, stamp: c.stamp)
            return
        default: break
        }

        let cur = e.stamps[c.field].flatMap(Stamp.init)
        let concurrent = c.base != cur
        let newer = cur.map { c.stamp > $0 } ?? true
        func adoptStamp() { if newer { e.stamps[c.field] = s } }

        switch c.field {
        case "content":
            guard let sha = decode(c.value, as: String.self) else { return }
            if e.deletedAt != nil, unseenHere(e.stamps["deleted"], by: c, peer) {
                try addConflict(.deleteEdit, entry: e.id, field: "content", theirs: c.value, sha: sha, c, peer)
            }
            if !concurrent {
                setContent(&e, sha)
                e.stamps["content"] = s
            } else if sha == e.sha {
                adoptStamp()
            } else {
                try addConflict(.content, entry: e.id, field: "content", theirs: c.value, sha: sha, c, peer)
                return
            }
        case "path":
            guard let p = decode(c.value, as: PathValue.self) else { return }
            if !concurrent {
                (e.folder, e.name) = (p.folder, p.name)
                e.stamps["path"] = s
            } else if p.folder == e.folder && p.name == e.name {
                adoptStamp()
            } else {
                try addConflict(.path, entry: e.id, field: "path", theirs: c.value, sha: nil, c, peer)
                return
            }
        case "deleted":
            let at = decode(c.value, as: Double.self) // "null": restored
            if at != nil, e.deletedAt == nil, unseenHere(e.stamps["content"], by: c, peer) {
                try addConflict(.editDelete, entry: e.id, field: "deleted", theirs: c.value, sha: nil, c, peer)
                return
            }
            guard !concurrent || newer else { return }
            e.deletedAt = at
            e.stamps["deleted"] = s
        case "source":
            guard newer, let v = decode(c.value, as: String.self) else { return }
            e.source = v
            e.stamps["source"] = s
        case "group":
            guard newer, let v = decode(c.value, as: GroupValue.self) else { return }
            (e.group, e.groupIndex) = (v.group, v.index)
            e.stamps["group"] = s
        case "added":
            guard newer, let v = decode(c.value, as: Double.self) else { return }
            e.addedAt = v
            e.stamps["added"] = s
        default:
            return
        }
        e.changedAt = max(e.changedAt, Double(c.stamp.ms))
        try save(e)
    }

    /// A change made here that the other Mac hadn't seen when it sent its own.
    /// Whether this Mac's change `stamp` was unknown to the other Mac when it made `c`.
    private func unseenHere(_ stamp: String?, by c: SyncChange, _ peer: SyncPeer) -> Bool {
        guard let st = stamp.flatMap(Stamp.init), st.replica == replica else { return false }
        // A Mac's clock passes every stamp it receives, so a change stamped earlier than ours was
        // made before it saw ours, even if it has acknowledged ours since (its ack can arrive first).
        if c.stamp < st { return true }
        return peer.seenMine.map { st > $0 } ?? true
    }

    /// New content; the old goes into history.
    private func setContent(_ e: inout Entry, _ sha: String) {
        guard sha != e.sha else { return }
        let now = nowMs()
        _ = try? db.run("INSERT INTO versions(entryId, sha, source, replacedAt) VALUES(?,?,?,?)", [e.id, e.sha, e.source, now])
        e.sha = sha
        try? pruneVersions(e.id, now: now)
    }

    /// Take on a resolution's state, field by field where it's newer, and close the conflicts.
    private func adopt(_ e: inout Entry, _ r: ResolveValue, stamp: Stamp) throws {
        let s = stamp.description
        func newer(_ f: String) -> Bool { e.stamps[f].flatMap(Stamp.init).map { stamp > $0 } ?? true }
        let snap = r.snapshot
        if newer("path") { (e.folder, e.name) = (snap.folder, snap.name) }
        if newer("content") { setContent(&e, snap.sha) }
        if newer("source") { e.source = snap.source }
        if newer("group") { (e.group, e.groupIndex) = (snap.group, snap.groupIndex) }
        if newer("added") { e.addedAt = snap.addedAt }
        if newer("deleted") { e.deletedAt = r.deletedAt }
        for f in EntrySnapshot.fields where newer(f) { e.stamps[f] = s }
        e.parked = false
        e.changedAt = max(e.changedAt, Double(stamp.ms))
        try save(e)
        try clearConflicts(e.id)
    }

    private func applyFolder(_ c: SyncChange) throws {
        guard let deleted = decode(c.value, as: Bool.self) else { return }
        let cur = try db.query("SELECT stamp FROM folders WHERE path=?", [c.id]).first?.string("stamp").flatMap(Stamp.init)
        guard cur.map({ c.stamp > $0 }) ?? true else { return }
        try db.run(
            "INSERT INTO folders(path, deleted, stamp) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET deleted=excluded.deleted, stamp=excluded.stamp",
            [c.id, deleted, c.stamp.description])
    }

    private func applyMacro(_ c: SyncChange) throws {
        let row = try db.query("SELECT stamp FROM macros WHERE id=?", [c.id]).first
        guard row?.string("stamp").flatMap(Stamp.init).map({ c.stamp > $0 }) ?? true else { return }
        let s = c.stamp.description
        if c.field == "deleted" {
            try db.run("UPDATE macros SET deleted=1, stamp=? WHERE id=?", [s, c.id])
        } else if let m = decode(c.value, as: Macro.self) {
            let position = try row == nil
                ? db.query("SELECT COALESCE(MAX(position), -1) + 1 AS p FROM macros").first?.int("p") ?? 0
                : db.query("SELECT position FROM macros WHERE id=?", [c.id]).first?.int("position") ?? 0
            try db.run(
                """
                INSERT INTO macros(id, name, gcode, position, deleted, stamp) VALUES(?,?,?,?,0,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, gcode=excluded.gcode, deleted=0, stamp=excluded.stamp
                """, [m.id, m.name, m.gcode, position, s])
        }
    }

    private func applyConfig(_ c: SyncChange) throws {
        let cur = try db.query("SELECT stamp FROM config WHERE key=?", [c.id]).first?.string("stamp").flatMap(Stamp.init)
        guard cur.map({ c.stamp > $0 }) ?? true, decode(c.value, as: MachineConfig.self) != nil else { return }
        try db.run(
            "INSERT INTO config(key, value, stamp) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, stamp=excluded.stamp",
            [c.id, c.value, c.stamp.description])
    }

    // MARK: - Conflicts

    private func addConflict(
        _ kind: ConflictKind, entry: String, otherId: String? = nil, field: String, theirs: String, sha: String?,
        _ c: SyncChange, _ peer: SyncPeer
    ) throws {
        let detail = json(ConflictDetail(field: field, theirs: theirs, stamp: c.stamp, peer: peer.name))
        if let id = try db.query("SELECT id FROM conflicts WHERE entryId=? AND kind=?", [entry, kind.rawValue]).first?.string("id") {
            try db.run("UPDATE conflicts SET detail=?, otherId=?, sha=? WHERE id=?", [detail, otherId, sha, id])
        } else {
            try db.run(
                "INSERT INTO conflicts(id, entryId, kind, detail, createdAt, otherId, sha) VALUES(?,?,?,?,?,?,?)",
                [randomId(8), entry, kind.rawValue, detail, nowMs(), otherId, sha])
        }
    }

    private func clearConflicts(_ entryId: String) throws {
        try db.run("DELETE FROM conflicts WHERE entryId=? OR otherId=?", [entryId, entryId])
    }

    /// Open conflicts, oldest first.
    public func conflicts() -> [LibraryConflict] {
        let rows = (try? db.query("SELECT * FROM conflicts ORDER BY createdAt")) ?? []
        return rows.compactMap { r in
            guard let kind = r.string("kind").flatMap { ConflictKind(rawValue: $0) }, let entryId = r.string("entryId"),
                  let e = entry(entryId), let d = r.string("detail").flatMap({ decode($0, as: ConflictDetail.self) })
            else { return nil }
            let mine = side(e)
            var theirs = mine
            theirs.changedAt = Double(d.stamp.ms)
            switch kind {
            case .content:
                theirs = side(e, sha: r.string("sha") ?? e.sha, changedAt: Double(d.stamp.ms))
            case .path:
                if let p = decode(d.theirs, as: PathValue.self) { (theirs.folder, theirs.name) = (p.folder, p.name) }
            case .editDelete:
                theirs.deleted = true
            case .deleteEdit:
                theirs = side(e, sha: r.string("sha") ?? e.sha, changedAt: Double(d.stamp.ms))
                theirs.deleted = false
            case .samePath:
                guard let other = r.string("otherId").flatMap({ entry($0) }) else { return nil }
                theirs = side(other)
            }
            return LibraryConflict(id: r.string("id")!, kind: kind, entryId: entryId, peer: d.peer, mine: mine, theirs: theirs)
        }
    }

    private func side(_ e: Entry, sha: String? = nil, changedAt: Double? = nil) -> ConflictSide {
        let sha = sha ?? e.sha
        let a = try? analysis(sha)
        return ConflictSide(
            name: e.name, folder: e.folder, sha256: sha, source: e.source, size: a?.size, estSeconds: a?.estSeconds,
            changedAt: changedAt ?? e.changedAt, deleted: e.deletedAt != nil)
    }

    /// Settle a conflict. The losing content stays in the file's history; "keep both" keeps the
    /// other Mac's version as a copy named after that Mac and the day, `part (Garage, 18 Nov).nc`.
    public func resolve(_ conflictId: String, _ choice: ConflictChoice) throws {
        try mutate {
            guard let r = try db.query("SELECT * FROM conflicts WHERE id=?", [conflictId]).first,
                  let kind = r.string("kind").flatMap { ConflictKind(rawValue: $0) },
                  let d = r.string("detail").flatMap({ decode($0, as: ConflictDetail.self) }),
                  var e = entry(r.string("entryId")!)
            else { throw LibraryError("That conflict has already been resolved") }
            let theirSha = r.string("sha")
            let now = nowMs()
            func needTheirs() throws -> String {
                guard let sha = theirSha, blobs.has(sha) else {
                    throw LibraryError("The other Mac's version hasn't arrived yet. Try again once it's connected")
                }
                return sha
            }
            func copyName(in folder: String) -> String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_GB")
                f.dateFormat = "d MMM"
                let day = f.string(from: Date(timeIntervalSince1970: Double(d.stamp.ms) / 1000))
                let ext = fileExtension(e.name)
                let stem = ext.isEmpty ? e.name : String(e.name.dropLast(ext.count))
                return freeName("\(stem) (\(d.peer), \(day))\(ext.isEmpty ? "" : String(e.name.suffix(ext.count)))", in: folder)
            }
            func copy(sha: String, folder: String) throws {
                try ensureFolder(folder)
                try create(Entry(
                    id: UUID().uuidString.lowercased(), folder: folder, name: copyName(in: folder), sha: sha, source: e.source,
                    group: e.group, groupIndex: nil, addedAt: now, changedAt: now, deletedAt: nil, stamps: [:]))
            }

            switch (kind, choice) {
            case (.content, .keepTheirs):
                setContent(&e, try needTheirs())
            case (.content, .keepBoth):
                try copy(sha: try needTheirs(), folder: e.folder)
            case (.path, .keepTheirs):
                if let p = decode(d.theirs, as: PathValue.self) {
                    try ensureFolder(p.folder)
                    let taken = liveEntry(folder: p.folder, name: p.name).map { $0.id != e.id } ?? false
                    (e.folder, e.name) = (p.folder, taken ? freeName(p.name, in: p.folder) : p.name)
                }
            case (.path, .keepBoth):
                if let p = decode(d.theirs, as: PathValue.self) {
                    try ensureFolder(p.folder)
                    let name = liveEntry(folder: p.folder, name: p.name) == nil ? p.name : freeName(p.name, in: p.folder)
                    try create(Entry(
                        id: UUID().uuidString.lowercased(), folder: p.folder, name: name, sha: e.sha, source: e.source,
                        group: e.group, groupIndex: nil, addedAt: now, changedAt: now, deletedAt: nil, stamps: [:]))
                }
            case (.editDelete, .keepTheirs):
                e.deletedAt = decode(d.theirs, as: Double.self) ?? now
            case (.deleteEdit, .keepTheirs), (.deleteEdit, .keepBoth):
                if let sha = theirSha, blobs.has(sha) { setContent(&e, sha) }
                if liveEntry(folder: e.folder, name: e.name) != nil { e.name = freeName(e.name, in: e.folder) }
                e.deletedAt = nil
            case (.samePath, _):
                guard var other = r.string("otherId").flatMap({ entry($0) }) else { break }
                switch choice {
                case .keepMine:
                    other.deletedAt = now
                case .keepTheirs:
                    // This Mac's file leaves the path first, so the other one finds it free.
                    e.deletedAt = now
                    e.changedAt = now
                    try settle(&e)
                case .keepBoth:
                    other.name = copyName(in: other.folder) // the other Mac's file takes the dated name
                }
                try settle(&other)
                if choice == .keepTheirs {
                    try db.run("DELETE FROM conflicts WHERE id=?", [conflictId])
                    return
                }
            default:
                break // keep mine: this Mac's state, as it is, becomes both Macs'
            }
            e.changedAt = now
            try settle(&e)
            try db.run("DELETE FROM conflicts WHERE id=?", [conflictId])
        }
    }

    /// Record a file's whole state as authoritative (the other Mac adopts it) and close its conflicts.
    private func settle(_ e: inout Entry) throws {
        let s = try record("entry", e.id, "resolve", ResolveValue(snapshot: EntrySnapshot(e), deletedAt: e.deletedAt), base: nil)
        for f in EntrySnapshot.fields { e.stamps[f] = s }
        e.parked = false
        try save(e)
        try clearConflicts(e.id)
    }
}
