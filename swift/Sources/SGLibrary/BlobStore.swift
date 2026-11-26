// File contents, addressed by SHA-256: blobs/<sha256>. A blob is written once and never edited,
// so identical content is stored (and later synced) once, and a running job can pin what it runs.

import CryptoKit
import Foundation

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct BlobStore {
    let dir: URL

    init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func url(_ sha: String) -> URL { dir.appending(path: sha) }

    func has(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: url(sha).path) }

    /// Store content; returns its sha. Writing what's already there costs nothing.
    @discardableResult
    func put(_ data: Data, sha known: String? = nil) throws -> String {
        let sha = known ?? sha256Hex(data)
        if has(sha) { return sha }
        let tmp = dir.appending(path: ".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if rename(tmp.path, url(sha).path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw LibraryError("Couldn't store the file: \(String(cString: strerror(errno)))")
        }
        return sha
    }

    func get(_ sha: String) -> Data? { try? Data(contentsOf: url(sha)) }

    func all() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    func remove(_ sha: String) { try? FileManager.default.removeItem(at: url(sha)) }
}
