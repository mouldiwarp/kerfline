// Where a program expects Z zero to be taken, read from the plain words in its header. Zeroing on the material
// when the file expects the spoilboard (or the other way round) cuts the whole job a stock thickness too deep or in
// the air, so the main window shows it for the file about to run.

import Foundation

public enum ZZeroReference: String, Codable, Equatable, Sendable {
    /// The top surface of the material.
    case materialTop
    /// The spoilboard the material sits on (the bottom of the stock).
    case spoilboard

    /// Short, for the job panel.
    public var title: String { self == .materialTop ? "TOP of the material" : "SPOILBOARD" }
    /// Where the touch plate goes.
    public var advice: String {
        self == .materialTop ? "Touch off Z on the top surface of the material."
            : "Touch off Z on the spoilboard the material sits on, not on the material."
    }
}

/// The Z-zero reference a program's header states, if it states one. Reads the comment lines near the top:
/// - Fretboard Modeller: "Work origin: … Z0 = TOP of stock" / "Z0 = SPOILBOARD surface (bottom of the stock)",
///   inlays "Z0 = BOARD SURFACE at that point";
/// - SwarfPath (and Swarf before it): "Z0 = TOP of stock: …" / "Z0 = SPOILBOARD surface, the bottom of the stock: …", and before it said so in
///   words, "Work zero (stock space): X… Y… Z…" (stock space Z 0 is the bottom of the stock);
/// - anything else that says "Z0 = …", "Z zero …" or "zero Z on …" in words.
public func zZeroReference(_ text: String, headerLines: Int = 80) -> ZZeroReference? {
    // "Z0 = …" is the most specific; then "Z zero …"/"zero Z on …"; then older Swarf files' work-zero coordinates.
    var loose: ZZeroReference?, fromWorkZero: ZZeroReference?
    for raw in splitLines(text).prefix(headerLines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // Comment lines only (a comment may hold brackets of its own, so go by the first character).
        guard line.hasPrefix(";") || line.hasPrefix("(") else { continue }
        let lower = line.lowercased()
        for key in ["z0 =", "z0=", "z0:"] {
            if let r = lower.range(of: key), let ref = classify(lower[r.upperBound...]) { return ref }
        }
        if loose == nil {
            for key in ["z zero", "zero z"] {
                if let r = lower.range(of: key), let ref = classify(lower[r.upperBound...]) { loose = ref; break }
            }
        }
        if fromWorkZero == nil, let r = lower.range(of: "work zero"),
           let z = lower[r.upperBound...].range(of: #"z\s*-?[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
           let v = Double(lower[z].dropFirst().trimmingCharacters(in: .whitespaces)) {
            fromWorkZero = abs(v) < 1e-6 ? .spoilboard : .materialTop
        }
    }
    return loose ?? fromWorkZero
}

private func classify(_ s: Substring) -> ZZeroReference? {
    // Spoilboard words first: "SPOILBOARD surface" also says "surface".
    if ["spoilboard", "spoil board", "wasteboard", "bed", "bottom of the stock", "stock bottom", "table"].contains(where: s.contains) {
        return .spoilboard
    }
    if ["top", "surface", "material", "stock", "blank", "board"].contains(where: s.contains) { return .materialTop }
    return nil
}
