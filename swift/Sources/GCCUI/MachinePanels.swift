// The left column: the DRO (positions, Zero, →0) and the jog pad, as 1.0's Dro.tsx and Jog.tsx.
// Arrow keys jog X/Y, Page Up/Down jog Z and Escape cancels a jog, unless a text field has focus.

import AppKit
import GCCCore
import GCCNet
import SwiftUI

struct DroPanel: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var confirmXYZ0 = false

    var body: some View {
        let idle = s.machineReady && s.machine.status == .idle && !s.jobActive
        // Single-axis homing works from ALARM too; the fallback move needs a full home first.
        let canHomeAxis = s.machineReady && !s.jobActive && s.machine.status != .home
            && (s.machine.homeAxes == true ? [.idle, .alarm].contains(s.machine.status) : idle && s.machine.homed == true)
        Panel("Position") {
            Text(s.machine.homed == true ? "homed" : "not homed").font(.system(size: 11)).foregroundStyle(s.machine.homed == true ? Color.ok : Color.steel)
        } content: {
            VStack(spacing: 6) {
                ForEach(Array(Axis.allCases.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 8) {
                        Text(a.rawValue).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(axisColor(a)).frame(width: 18)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(fixed(s.machine.wpos[i], 3)).font(.system(size: 22, weight: .medium, design: .monospaced)).foregroundStyle(Color.offwhite)
                            Text("M \(fixed(s.machine.mpos[i], 3))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.steelDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Zero") { model.send(.zero(axes: [a])) }.gccButton(.normal, .small).disabled(!idle)
                            .help("Set work \(a.rawValue) zero here")
                        Button("→0") { model.send(.goToZero(axes: [a])) }.gccButton(.normal, .small).disabled(!idle)
                            .help(a == .Z ? "Move Z to work zero" : "Move \(a.rawValue) to work zero (lifting Z to safe height first)")
                        Button("Home") { model.send(.homeAxis(axis: a)) }.gccButton(.outlineGold, .small)
                            .disabled(!canHomeAxis).help(homeHelp(a))
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
                }
                HStack(spacing: 6) {
                    Button("Zero XY") { model.send(.zero(axes: [.X, .Y])) }.gccButton(.normal, .small).wide()
                    Button("Zero Z") { model.send(.zero(axes: [.Z])) }.gccButton(.normal, .small).wide()
                    Button("Zero all") { model.send(.zero(axes: [.X, .Y, .Z])) }.gccButton(.normal, .small).wide()
                }
                .disabled(!idle)
                HStack(spacing: 6) {
                    Button { model.send(.goToZero(axes: [.X, .Y])) } label: { Text("Go to XY0").frame(maxWidth: .infinity) }
                        .gccButton(.amber).wide().help("Move to work X0 Y0, lifting Z to safe height first")
                    Button { confirmXYZ0 = true } label: { Text("Go to XYZ0…").frame(maxWidth: .infinity) }
                        .gccButton(.red).wide().help("Move to work X0 Y0, then lower Z to work Z zero (asks first)")
                }
                .disabled(!idle)
                .alert("Lower Z to work Z zero?", isPresented: $confirmXYZ0) {
                    Button("Go to XYZ0", role: .destructive) { model.send(.goToZero(axes: [.X, .Y, .Z])) }
                    Button("Go to XY0 only") { model.send(.goToZero(axes: [.X, .Y])) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(xyz0Warning)
                }
                Button { model.openProbe() } label: {
                    Text("↧  Probe Z…").font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity)
                }
                .gccButton(.go, .large).wide().padding(.top, 4)
                .disabled(!s.machineReady || s.jobActive).help("Set Z zero with the touch plate")
                HStack {
                    Text("Feed \(Int(s.machine.feed))").monospaced()
                    Spacer()
                    Text("Spindle \(Int(s.machine.spindle))").monospaced()
                }
                .font(.system(size: 11)).foregroundStyle(Color.steel)
            }
        }
    }
}

extension DroPanel {
    /// The file in the job panel: the job's, or the one selected in the library.
    var currentFile: LibraryItem? {
        if let id = s.job.fileId, s.jobActive || [.stopped, .done, .error].contains(s.job.status),
           let f = s.library.first(where: { $0.id == id }) { return f }
        return model.selected
    }

    var xyz0Warning: String {
        let f = currentFile
        let where_ = switch f?.zZero {
        case .spoilboard: "\(f!.name) takes Z zero on the SPOILBOARD. If that's where you zeroed, Z0 over the stock is inside the material: the bit will drive into it."
        case .materialTop: "\(f!.name) takes Z zero on the TOP of the material, so Z0 should be the stock's surface."
        case nil: f.map { "\($0.name) doesn't say where Z zero is." } ?? "No file is selected to say where Z zero is."
        }
        return "The bit moves over X0 Y0, then down to work Z zero.\n\n\(where_)\n\nCheck where Z was zeroed before going down. Go to XY0 only keeps Z at a safe height."
    }

    func homeHelp(_ a: Axis) -> String {
        let lift = a == .Z ? "" : " Z homes first, to lift the bit clear."
        if s.machine.homeAxes == true { return "Home \(a.rawValue) on its limit switch ($H\(a.rawValue)).\(lift)" }
        return "Move \(a.rawValue) back to where the last full home left it (this GRBL can't home one axis).\(a == .Z ? "" : " Z goes up first.") Home all once first."
    }
}

func axisColor(_ a: Axis) -> Color {
    switch a {
    case .X: .axisX
    case .Y: .axisY
    case .Z: .axisZ
    }
}

struct JogPanel: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        @Bindable var model = model
        let can = s.canJog
        Panel("Jog") {
            Text("← → ↑ ↓ · PgUp/PgDn").font(.system(size: 11)).foregroundStyle(Color.steel)
        } content: {
            if s.machineReady, s.machine.homed != true {
                Text("Not homed: moves aren't held within the machine's travel. Home first.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.warn)
                    .help("Until the machine is homed its position isn't known, so jogs and typed commands can run into the limit switches (ALARM)")
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    jogButton("↖", -1, 1, 0)
                    jogButton("Y+", 0, 1, 0)
                    jogButton("↗", 1, 1, 0)
                    Color.clear.frame(width: 4)
                    jogButton("Z+", 0, 0, 1)
                }
                GridRow {
                    jogButton("X−", -1, 0, 0)
                    Text("\(fixed(model.jogStep, model.jogStep < 1 ? 1 : 0)) mm").font(.mono).foregroundStyle(Color.steel).wide()
                    jogButton("X+", 1, 0, 0)
                    Color.clear.frame(width: 4)
                    Button("■") { model.send(.jogCancel) }.gccButton(.ghost).wide().disabled(!s.machineReady).help("Cancel jog (Esc)")
                }
                GridRow {
                    jogButton("↙", -1, -1, 0)
                    jogButton("Y−", 0, -1, 0)
                    jogButton("↘", 1, -1, 0)
                    Color.clear.frame(width: 4)
                    jogButton("Z−", 0, 0, -1)
                }
            }
            .disabled(!can)
            Eyebrow("Step (mm)").padding(.top, 4)
            HStack(spacing: 6) {
                ForEach(s.config.jogSteps, id: \.self) { v in
                    Button(fixed(v, v < 1 ? 1 : 0)) { model.jogStep = v }.gccButton(.normal, .small, active: v == model.jogStep)
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("XY feed (mm/min)").font(.system(size: 11)).foregroundStyle(Color.steel)
                    TextField("", value: $model.jogFeedXY, format: .number).monospaced().gccField()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Z feed (mm/min)").font(.system(size: 11)).foregroundStyle(Color.steel)
                    TextField("", value: $model.jogFeedZ, format: .number).monospaced().gccField()
                }
            }
        }
    }

    private func jogButton(_ label: String, _ x: Double, _ y: Double, _ z: Double) -> some View {
        Button(label) { model.jog(x, y, z) }
            .gccButton()
            .font(.system(size: 14, weight: .semibold))
            .wide()
    }
}

/// Arrow keys, Page Up/Down and Escape while the window (not a text field or a sheet) has the keyboard.
@MainActor
final class JogKeys {
    private var monitor: Any?

    func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
            guard let model, JogKeys.wantsKey(e) else { return e }
            if e.keyCode == 53 {  // Escape
                guard model.state?.machineReady == true, model.state?.machine.status == .jog else { return e }
                model.send(.jogCancel)
                return nil
            }
            guard let d = JogKeys.direction(e.keyCode) else { return e }
            if !e.isARepeat { model.jog(d.0, d.1, d.2) }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func direction(_ keyCode: UInt16) -> (Double, Double, Double)? {
        switch keyCode {
        case 123: (-1, 0, 0)  // ←
        case 124: (1, 0, 0)  // →
        case 126: (0, 1, 0)  // ↑
        case 125: (0, -1, 0)  // ↓
        case 116: (0, 0, 1)  // Page Up
        case 121: (0, 0, -1)  // Page Down
        default: nil
        }
    }

    /// Not while typing, not in a sheet or another window, not with ⌘/⌥/⌃.
    static func wantsKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        guard let w = e.window, w.isKeyWindow, w.attachedSheet == nil, !w.isSheet, w.identifier?.rawValue.hasPrefix("main") ?? true else { return false }
        if w.firstResponder is NSText || w.firstResponder is NSTextView { return false }
        return true
    }
}
