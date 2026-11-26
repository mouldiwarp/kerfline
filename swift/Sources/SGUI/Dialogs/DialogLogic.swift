// The decisions behind the dialogs, apart from the views so they can be tested: when probing and
// resuming are allowed, how the travel settings map to an envelope, and what a group runs next.
// Ports of the logic in 1.0's ProbeDialog, ResumeDialog, Settings, SurfacingDialog and StartDialog.

import Foundation
import SGCore
import SGNet

/// Where homing puts machine 0,0,0.
public enum HomeCorner: String, CaseIterable, Sendable {
    /// X and Y count up from it (FoxAlien, $23=3).
    case frontLeft
    /// X and Y count down from it (GRBL's default, $23=0).
    case backRight

    public init(_ envelope: Bounds) {
        self = envelope.min.x >= 0 && envelope.min.y >= 0 ? .frontLeft : .backRight
    }

    /// From GRBL's homing direction mask, $23 (nil: mixed corners).
    public init?(dirMask: Int) {
        switch dirMask & 3 {
        case 3: self = .frontLeft
        case 0: self = .backRight
        default: return nil
        }
    }

    public func envelope(travel t: Vec3) -> Bounds {
        switch self {
        case .frontLeft: Bounds(min: Vec3(0, 0, -t.z), max: Vec3(t.x, t.y, 0))
        case .backRight: Bounds(min: Vec3(-t.x, -t.y, -t.z), max: .zero)
        }
    }
}

/// "0.1, 1 10" → [0.1, 1, 10]: positive numbers, smallest first.
public func parseJogSteps(_ text: String) -> [Double] {
    text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }.filter { $0 > 0 }.sorted()
}

extension AppState {
    /// Why Probe Z can't run now (nil: it can).
    public var probeBlocked: String? {
        let m = machine
        if !machineReady { return "The machine is not connected" }
        if config.probe.plateThickness <= 0 { return "Measure the touch plate and enter its thickness in Settings first" }
        if m.status == .alarm { return "Unlock the machine first" }
        if jobActive { return "A job is running" }
        if m.status != .idle { return "The machine is \(m.status.rawValue)" }
        if probeTouching { return "The probe input is closed. Move the plate away from the bit" }
        return nil
    }

    /// The probe circuit is closed (the plate touches the bit).
    public var probeTouching: Bool { machine.pins?.contains("P") == true }

    /// Why the machine can't take a resume or a start right now (nil: it can).
    public var notIdleReason: String? {
        if !machineReady { return "The machine is not connected" }
        if jobActive { return "A job is running" }
        if machine.status == .alarm { return "Home or unlock the machine first" }
        if machine.status != .idle { return "The machine is \(machine.status.rawValue)" }
        return nil
    }

    /// The files after `item` in its group, in run order.
    public func groupFollowing(_ item: LibraryItem) -> [LibraryItem] {
        guard let g = item.group else { return [] }
        let files = library.filter { $0.group == g }.sorted { ($0.groupIndex ?? 0) < ($1.groupIndex ?? 0) }
        guard let i = files.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(files[(i + 1)...])
    }

    /// The controller's settings differ from the FoxAlien's (not checked on the simulator).
    public var settingProblems: [SettingProblem] {
        guard let st = machine.settings, !st.isEmpty, !machine.simulated else { return [] }
        return checkSettings(st, foxAlien)
    }

    /// The controller's travel, when it differs from the app's.
    public var controllerEnvelopeIfDifferent: Bounds? {
        guard let st = machine.settings, let e = envelopeFromSettings(st), !sameEnvelope(e, config.envelope) else { return nil }
        return e
    }
}

/// The axes in which `bounds` (work) leaves `envelope` (machine) from work offset `wco`.
public func axesOutside(_ bounds: Bounds, envelope env: Bounds, wco: Vec3) -> [String] {
    ["X", "Y", "Z"].enumerated().compactMap { i, n in
        bounds.min[i] + wco[i] < env.min[i] - 0.01 || bounds.max[i] + wco[i] > env.max[i] + 0.01 ? n : nil
    }
}

/// The surfacing parameters, remembered on this Mac.
public enum SurfacingStore {
    static let key = "swarfgrbl.surfacing"

    public static func load(_ d: UserDefaults = AppSetup.store) -> SurfacingParams {
        guard let data = d.data(forKey: key), let p = try? JSONDecoder().decode(SurfacingParams.self, from: data) else { return .defaults }
        return p
    }

    public static func save(_ p: SurfacingParams, _ d: UserDefaults = AppSetup.store) {
        if let data = try? JSONEncoder().encode(p) { d.set(data, forKey: key) }
    }
}

/// "X 1.000 · Y 2.000 · Z 3.000"
func xyz(_ v: Vec3, _ places: Int = 3) -> String {
    "X \(fixed(v.x, places)) · Y \(fixed(v.y, places)) · Z \(fixed(v.z, places))"
}

/// Shortest form of a number for a field: 3, 0.5, 12.25.
func short(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
}
