// File and folder name rules, as 1.0 (packages/hub/src/library.ts).

import Foundation

public let gcodeExtensions: Set<String> = [".nc", ".gcode", ".ngc", ".tap", ".gc", ".cnc", ".txt", ".g"]

/// ".nc" for "part.NC", "" without an extension.
func fileExtension(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[dot...].lowercased()
}

public func isGcodeName(_ name: String) -> Bool { gcodeExtensions.contains(fileExtension(name)) }

private func dropControls(_ s: some StringProtocol, also: Set<Character>) -> String {
    String(s.filter { c in !also.contains(c) && !c.unicodeScalars.allSatisfy { $0.value < 0x20 } })
}

/// A safe file name from whatever the sender called it.
public func sanitizeName(_ name: String) -> String {
    let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    var clean = dropControls(base, also: [":"])
    while clean.hasPrefix(".") { clean.removeFirst() }
    clean = String(clean.trimmingCharacters(in: .whitespaces).prefix(120))
    if !clean.isEmpty { return clean }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return "upload-\(f.string(from: Date())).nc"
}

public func withGcodeExtension(_ name: String) -> String {
    isGcodeName(name) ? name : "\(name).nc"
}

/// A single safe folder name from free text (a Swarf group name, say).
public func folderName(_ text: String) -> String {
    var s = String(text.map { c in
        c == "/" || c == "\\" || c == ":" || c.unicodeScalars.allSatisfy({ $0.value < 0x20 }) ? "-" : c
    })
    while s.hasPrefix(".") { s.removeFirst() }
    s = String(s.trimmingCharacters(in: .whitespaces).prefix(100))
    return s.isEmpty ? "Untitled" : s
}

/// Validate a "/"-separated folder path inside the library.
public func checkFolder(_ path: String, allowRoot: Bool = false) throws -> String {
    var clean = path.trimmingCharacters(in: .whitespaces)
    while clean.hasPrefix("/") { clean.removeFirst() }
    while clean.hasSuffix("/") { clean.removeLast() }
    if clean.isEmpty {
        if allowRoot { return "" }
        throw LibraryError("The folder needs a name")
    }
    let parts = clean.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    for p in parts {
        let bad = p.isEmpty || p.hasPrefix(".") || p.count > 100
            || p.contains(where: { $0 == "\\" || $0 == ":" || $0.unicodeScalars.allSatisfy { $0.value < 0x20 } })
        if bad { throw LibraryError("\"\(clean)\" isn't a usable folder name") }
    }
    return parts.joined(separator: "/")
}

func joinPath(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : "\(folder)/\(name)" }

/// The folder and everything inside it.
func isInFolder(_ itemFolder: String, _ folder: String) -> Bool {
    itemFolder == folder || itemFolder.hasPrefix("\(folder)/")
}

/// "part.nc" → "part (2).nc", "part (3).nc"… until `taken` says no.
public func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
    if !taken(name) { return name }
    let ext = fileExtension(name)
    let stem = ext.isEmpty ? name : String(name.dropLast(ext.count))
    let realExt = ext.isEmpty ? "" : String(name.suffix(ext.count))
    var n = 2
    while true {
        let candidate = "\(stem) (\(n))\(realExt)"
        if !taken(candidate) { return candidate }
        n += 1
    }
}

/// Every ancestor of a folder path, outermost first, including itself: "a/b" → ["a", "a/b"].
func folderAndAncestors(_ path: String) -> [String] {
    guard !path.isEmpty else { return [] }
    var out: [String] = []
    var acc = ""
    for p in path.split(separator: "/") {
        acc = acc.isEmpty ? String(p) : "\(acc)/\(p)"
        out.append(acc)
    }
    return out
}
