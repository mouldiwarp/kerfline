// The FoxAlien XE-Ultra 8080 this app drives: the GRBL settings it has been checked and set up
// with, and the hardware checks the software can't see. When the controller connects and its
// settings are read, they're compared with the profile so a reset board or a changed setting is
// caught before it causes trouble. Port of packages/shared/src/machineCheck.ts.

import Foundation

public struct ExpectedSetting: Sendable {
    public var key: String
    public var value: String
    /// What it is, and why it has this value.
    public var why: String
}

public struct MachineProfile: Sendable {
    public var name: String
    /// In setting-number order.
    public var settings: [ExpectedSetting]
    /// Things to check by hand at start-up (switches and wiring the controller can't report).
    public var hardware: [String]
    /// Shown before a job that runs the spindle.
    public var spindleReminder: String?

    public func expected(_ key: String) -> ExpectedSetting? { settings.first { $0.key == key } }
}

public let foxAlien = MachineProfile(
    name: "FoxAlien XE-Ultra 8080, 1.5 kW spindle",
    settings: [
        .init(key: "20", value: "1", why: "Soft limits on: GRBL itself refuses moves past the travel instead of hitting a limit switch"),
        .init(key: "21", value: "1", why: "Hard limits on: the limit switches stop the machine"),
        .init(key: "22", value: "1", why: "Homing on"),
        .init(key: "23", value: "3", why: "Homes to the front-left corner (X and Y count up from it)"),
        .init(key: "27", value: "3", why: "Backs 3 mm off the switches after homing"),
        .init(key: "30", value: "24000", why: "Spindle top speed: S24000 is full PWM for the 1.5 kW spindle"),
        .init(key: "32", value: "0", why: "Laser mode off: the spindle keeps running between moves"),
        .init(key: "130", value: "800", why: "X travel, mm"),
        .init(key: "131", value: "800", why: "Y travel, mm"),
        .init(key: "132", value: "100", why: "Z travel, mm"),
    ],
    hardware: ["The controller's Laser/Spindle switch is set to LASER: the 1.5 kW spindle takes its PWM from the laser port"],
    spindleReminder: "The Laser/Spindle switch on the controller must be on LASER for the 1.5 kW spindle."
)

public struct SettingProblem: Equatable, Sendable {
    public var key: String
    public var expected: String
    /// Nil if the controller didn't report it.
    public var actual: String?
    public var why: String
}

private func number(_ s: String) -> Double? {
    Double(s.trimmingCharacters(in: .whitespaces))
}

private func same(_ a: String, _ b: String) -> Bool {
    if let x = number(a), let y = number(b), x.isFinite, y.isFinite { return abs(x - y) < 1e-6 }
    return a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
}

/// Settings that differ from the profile's (numbers compared as numbers: 3 = 3.000).
public func checkSettings(_ actual: [String: String], _ profile: MachineProfile) -> [SettingProblem] {
    profile.settings
        .filter { e in actual[e.key].map { !same($0, e.value) } ?? true }
        .map { SettingProblem(key: $0.key, expected: $0.value, actual: actual[$0.key], why: $0.why) }
}

/// The travel envelope the controller's settings describe ($130-$132 and the homing corner, $23).
public func envelopeFromSettings(_ st: [String: String]) -> Bounds? {
    let t = ["130", "131", "132"].map { st[$0].flatMap(number) ?? .nan }
    guard t.allSatisfy({ $0 > 0 }) else { return nil }
    let dir = Int(st["23"].flatMap(number) ?? 0) & 3
    // Bits set: X and Y home towards their minimum, so machine coordinates count up from it.
    if dir == 3 { return Bounds(min: Vec3(0, 0, -t[2]), max: Vec3(t[0], t[1], 0)) }
    if dir == 0 { return Bounds(min: Vec3(-t[0], -t[1], -t[2]), max: Vec3(0, 0, 0)) }
    return nil // mixed corners: leave it to Settings
}

public func sameEnvelope(_ a: Bounds, _ b: Bounds) -> Bool {
    (0..<3).allSatisfy { abs(a.min[$0] - b.min[$0]) < 0.01 && abs(a.max[$0] - b.max[$0]) < 0.01 }
}
