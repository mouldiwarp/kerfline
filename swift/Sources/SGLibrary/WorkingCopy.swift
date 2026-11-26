// The Finder folder as a working copy of the library.
//
// `disk` remembers, for each path, which entry the library last wrote (or read) there, with its
// sha, size and modification time. A file that still matches is unchanged, so the library's own
// writes never come back as changes; one that doesn't was changed outside the app.
//
//   scan()        Finder → library: new files, edits, moves/renames (same content reappearing
//                 elsewhere keeps its id), deletions (to the Trash), folders made or removed.
//   materialize() library → Finder: write, move and remove files and folders to match.

import Darwin
import Foundation
import SGCore

struct FoundFile {
    var folder: String
    var name: String
    var size: Int64
    var mtime: Int64
    var path: String { joinPath(folder, name) }
}

func fileStat(_ path: String) -> (size: Int64, mtime: Int64, isDir: Bool, isFile: Bool)? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let kind = st.st_mode & S_IFMT
    let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    return (Int64(st.st_size), mtime, kind == S_IFDIR, kind == S_IFREG)
}

func nowNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_REALTIME)) }

extension Library {
    func diskRows() -> [DiskRow] {
        ((try? db.query("SELECT * FROM disk")) ?? []).map { r in
            DiskRow(path: r.string("path")!, entryId: r.string("entryId")!, sha: r.string("sha")!, size: r.int64("size")!, mtime: r.int64("mtime")!)
        }
    }

    func setDiskRow(_ path: String, entry: String, sha: String) throws {
        guard let st = fileStat(root.appending(path: path).path) else {
            try db.run("DELETE FROM disk WHERE path=?", [path])
            return
        }
        try db.run(
            "INSERT OR REPLACE INTO disk(path, entryId, sha, size, mtime) VALUES(?,?,?,?,?)", [path, entry, sha, st.size, st.mtime])
    }

    /// Every visible folder and G-code-named file under the root.
    func walk() -> (dirs: [String], files: [FoundFile]) {
        var dirs: [String] = [], files: [FoundFile] = []
        func visit(_ folder: String) {
            let abs = root.appending(path: folder).path
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: abs) else { return }
            for name in names where !name.hasPrefix(".") {
                let rel = joinPath(folder, name)
                guard let st = fileStat("\(abs)/\(name)") else { continue }
                if st.isDir {
                    dirs.append(rel)
                    visit(rel)
                } else if st.isFile && isGcodeName(name) {
                    files.append(FoundFile(folder: folder, name: name, size: st.size, mtime: st.mtime))
                }
            }
        }
        visit("")
        return (dirs, files)
    }

    /// Finder → library. Returns true if anything changed. Call inside a transaction.
    func scan() throws -> Bool {
        let (dirs, files) = walk()
        let rows = Dictionary(diskRows().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let onDisk = Set(files.map(\.path))
        // Tracked paths gone from disk: deleted, or moved (claimed below by matching content).
        var missing = rows.filter { !onDisk.contains($0.key) }
        var changed = false
        var later = false
        let settleNs = Int64(options.settleMs * 1_000_000)

        for f in files.sorted(by: { $0.path < $1.path }) {
            let row = rows[f.path]
            if let row, row.size == f.size, row.mtime == f.mtime { continue }
            if ignored[f.path] == f.mtime { continue }
            if nowNs() - f.mtime < settleNs {
                later = true // still being written (a Finder copy, say)
                continue
            }
            guard let data = try? Data(contentsOf: root.appending(path: f.path)) else { continue }
            let sha = sha256Hex(data)
            if let row, row.sha == sha {
                try setDiskRow(f.path, entry: row.entryId, sha: sha) // touched, not changed
                continue
            }
            guard try analysis(sha, data) != nil else {
                ignored[f.path] = f.mtime
                if let row { missing[f.path] = row } // no longer G-code: as good as gone
                continue
            }
            try blobs.put(data, sha: sha)

            // Edited in place.
            if let row, var e = entry(row.entryId), e.isLive {
                try replaceContent(&e, sha: sha, source: e.source, now: nowMs())
                try setDiskRow(f.path, entry: e.id, sha: sha)
                changed = true
                continue
            }
            // A file the library has an entry for but hadn't written yet (an import, say).
            if var e = liveEntry(folder: f.folder, name: f.name), !rows.values.contains(where: { $0.entryId == e.id }) {
                if e.sha != sha {
                    try replaceContent(&e, sha: sha, source: e.source, now: nowMs())
                    changed = true
                }
                if e.name != f.name { try setPath(&e, f.folder, f.name) } // case differs
                try setDiskRow(f.path, entry: e.id, sha: sha)
                continue
            }
            // Moved or renamed: the same content disappeared from somewhere else.
            if let (oldPath, old) = missing.first(where: { $0.value.sha == sha }), var e = entry(old.entryId), e.isLive {
                missing[oldPath] = nil
                try db.run("DELETE FROM disk WHERE path=?", [oldPath])
                try ensureFolder(f.folder)
                try setPath(&e, f.folder, f.name)
                try setDiskRow(f.path, entry: e.id, sha: sha)
                changed = true
                continue
            }
            // New.
            try ensureFolder(f.folder)
            let now = nowMs()
            let e = Entry(
                id: UUID().uuidString.lowercased(), folder: f.folder, name: f.name, sha: sha, source: "Finder", group: nil,
                groupIndex: nil, addedAt: now, changedAt: now, deletedAt: nil, stamps: [:])
            try create(e)
            try setDiskRow(f.path, entry: e.id, sha: sha)
            changed = true
        }

        for (path, row) in missing {
            try db.run("DELETE FROM disk WHERE path=?", [path])
            if var e = entry(row.entryId), e.isLive, e.path == path {
                try setDeleted(&e, nowMs())
                changed = true
            }
        }

        let live = Set(folders())
        for d in dirs where !live.contains(d) {
            try ensureFolder(d)
            changed = true
        }
        let dirSet = Set(dirs)
        for f in live where !dirSet.contains(f) && fileStat(root.appending(path: f).path)?.isDir != true {
            try setFolderDeleted(f, true)
            changed = true
        }
        if later { scheduleRetry() }
        return changed
    }

    /// Library → Finder. Call inside a transaction, after `scan()`.
    @discardableResult
    func materialize() throws -> Bool {
        let fm = FileManager.default
        var changed = false
        let live = Dictionary(entries("deletedAt IS NULL AND parked=0").map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rowFor: [String: DiskRow] = [:]

        for row in diskRows() {
            if live[row.entryId] == nil || rowFor[row.entryId] != nil {
                // Deleted (its content is kept in the Trash): remove the file, unless it changed
                // since the library last saw it, in which case set it aside.
                let url = root.appending(path: row.path)
                if let st = fileStat(url.path) {
                    if st.size == row.size && st.mtime == row.mtime { try? fm.removeItem(at: url) } else { discard(url) }
                }
                try db.run("DELETE FROM disk WHERE path=?", [row.path])
                changed = true
            } else {
                rowFor[row.entryId] = row
            }
        }

        // Moves go through temporary names first, so files can swap places.
        var staged: [String: String] = [:] // entry id → temp path
        for (id, row) in rowFor where live[id]!.path != row.path {
            let tmp = ".sg-move-\(UUID().uuidString)"
            if rename(root.appending(path: row.path).path, root.appending(path: tmp).path) == 0 { staged[id] = tmp }
            try db.run("DELETE FROM disk WHERE path=?", [row.path])
            if staged[id] == nil { rowFor[id] = nil }
        }

        for f in folders() { try fm.createDirectory(at: root.appending(path: f), withIntermediateDirectories: true) }

        for var e in live.values.sorted(by: { $0.path < $1.path }) {
            let row = rowFor[e.id]
            if let row, row.path == e.path, row.sha == e.sha { continue }
            changed = true
            let target = root.appending(path: e.path)
            if let tmp = staged[e.id] {
                if fm.fileExists(atPath: target.path) {
                    try setPath(&e, e.folder, freeName(e.name, in: e.folder))
                }
                try fm.createDirectory(at: root.appending(path: e.folder), withIntermediateDirectories: true)
                if rename(root.appending(path: tmp).path, root.appending(path: e.path).path) != 0 {
                    throw LibraryError("Couldn't move \(e.name): \(String(cString: strerror(errno)))")
                }
                if row?.sha == e.sha {
                    try setDiskRow(e.path, entry: e.id, sha: e.sha)
                    continue
                }
            } else if row == nil, fm.fileExists(atPath: target.path) {
                // Something is already there: the same content is adopted; anything else keeps its place.
                if let data = try? Data(contentsOf: target), sha256Hex(data) == e.sha {
                    try setDiskRow(e.path, entry: e.id, sha: e.sha)
                    continue
                }
                try setPath(&e, e.folder, freeName(e.name, in: e.folder))
            }
            guard let data = blobs.get(e.sha) else { continue } // content still to come (sync)
            try writeAtomically(data, to: e.path)
            try setDiskRow(e.path, entry: e.id, sha: e.sha)
        }

        // Folders that were deleted: deepest first, and only what the library put there goes quietly.
        let liveFolders = folders()
        let dead = ((try? db.query("SELECT path FROM folders WHERE deleted=1")) ?? []).compactMap { $0.string("path") }
        for f in dead.sorted(by: { $0.count > $1.count }) where !liveFolders.contains(where: { isInFolder($0, f) }) {
            let url = root.appending(path: f)
            guard fileStat(url.path)?.isDir == true else { continue }
            let rest = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
            if rest.isEmpty { try? fm.removeItem(at: url) } else { discard(url) }
            changed = true
        }
        return changed
    }

    func writeAtomically(_ data: Data, to path: String) throws {
        let target = root.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = root.appending(path: ".sg-tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if rename(tmp.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw LibraryError("Couldn't write \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Something that isn't the library's to delete: to the macOS Trash, or <root>/.Deleted.
    func discard(_ url: URL) {
        let fm = FileManager.default
        if options.systemTrash, (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        let dir = root.appending(path: ".Deleted")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = uniqueName(url.lastPathComponent) { fm.fileExists(atPath: dir.appending(path: $0).path) }
        try? fm.moveItem(at: url, to: dir.appending(path: name))
    }
}
