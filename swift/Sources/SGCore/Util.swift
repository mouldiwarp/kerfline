// Small helpers shared by the core. Port of packages/shared/src/util.ts plus the number
// formatting the TypeScript did inline (toFixed and JS number-to-string).

import Foundation

/// `n.toFixed(digits)`.
public func fixed(_ n: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", n)
}

/// A G-code number: three decimals, trailing zeros dropped, no "-0" (`10.500` → `10.5`, `-0.0001` → `0`).
public func gnum(_ n: Double) -> String {
    var s = fixed(n, 3)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

/// How JavaScript prints a number: `6`, `1.5`, `0.1`.
public func jsNumber(_ n: Double) -> String {
    if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
    return "\(n)"
}

/// `mm:ss`, or `h:mm:ss` from an hour.
public func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    let pad = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
    return h > 0 ? "\(h):\(pad(m)):\(pad(sec))" : "\(pad(m)):\(pad(sec))"
}

public func randomId(_ length: Int = 10) -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<length).map { _ in chars.randomElement()! })
}

/// Milliseconds since 1970, the time unit the 1.0 data uses.
public func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }
