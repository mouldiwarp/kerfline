// One-time import of 1.0's hub library on 2.0's first start: the files in its folder (with the ids,
// sources, groups and dates its index remembers), its folder tree, its macros and machine config.
// 1.0's files and data are only read, never changed, so 1.0 keeps working until the cut-over.

import Foundation
import SGCore

private struct V1Item: Decodable {
    var id: String
    var name: String
    var folder: String?
    var source: String?
    var addedAt: Double?
    var group: String?
    var groupIndex: Int?
}

private struct V1Index: Decodable {
    var items: [V1Item]?
}

extension Library {
    func importV1IfNeeded(_ v1: V1Paths) throws {
        if try db.query("SELECT 1 FROM meta WHERE key='v1Imported'").first != nil { return }
        let fm = FileManager.default
        let index = (try? Data(contentsOf: v1.libraryDir.appending(path: ".gcode-controller.json")))
            .flatMap { try? JSONDecoder().decode(V1Index.self, from: $0) }

        try db.transaction {
            for it in index?.items ?? [] {
                guard let folder = try? checkFolder(it.folder ?? "", allowRoot: true), entry(it.id) == nil,
                      liveEntry(folder: folder, name: it.name) == nil,
                      let data = try? Data(contentsOf: v1.libraryDir.appending(path: joinPath(folder, it.name)))
                else { continue }
                let sha = sha256Hex(data)
                guard try analysis(sha, data) != nil else { continue }
                try blobs.put(data, sha: sha)
                try ensureFolder(folder)
                let added = it.addedAt ?? nowMs()
                try create(Entry(
                    id: it.id, folder: folder, name: it.name, sha: sha, source: it.source ?? "Upload", group: it.group,
                    groupIndex: it.groupIndex, addedAt: added, changedAt: added, deletedAt: nil, stamps: [:]))
            }
            // Empty folders too.
            if let walker = fm.enumerator(at: v1.libraryDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let rel = String(url.standardizedFileURL.path.dropFirst(v1.libraryDir.standardizedFileURL.path.count + 1))
                    if let f = try? checkFolder(rel) { try ensureFolder(f) }
                }
            }

            if let data = try? Data(contentsOf: v1.dataDir.appending(path: "macros.json")),
               let macros = try? JSONDecoder().decode([Macro].self, from: data) {
                for m in self.macros() where !macros.contains(where: { $0.id == m.id }) {
                    try db.run("UPDATE macros SET deleted=1 WHERE id=?", [m.id])
                }
                for m in macros { try storeMacro(m) }
            }
            if let data = try? Data(contentsOf: v1.dataDir.appending(path: "config.json")),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = mergedConfig(saved) {
                try storeConfig(config)
            }
            try db.run("INSERT INTO meta(key, value) VALUES('v1Imported', ?)", [String(nowMs())])
        }
        // Write the files out, adopting those already in place (1.0 and 2.0 usually share the folder).
        _ = try db.transaction { try materialize() }
    }
}

/// 1.0 saved its whole config, but older saves may lack newer fields: fill them from the defaults.
func mergedConfig(_ saved: [String: Any]) -> MachineConfig? {
    guard let defData = try? JSONEncoder().encode(MachineConfig.defaults),
          var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
    else { return nil }
    for (k, v) in saved {
        if let sub = v as? [String: Any], var base = merged[k] as? [String: Any] {
            for (k2, v2) in sub { base[k2] = v2 }
            merged[k] = base
        } else if merged[k] != nil {
            merged[k] = v
        }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
    return try? JSONDecoder().decode(MachineConfig.self, from: data)
}
