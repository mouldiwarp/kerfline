// Machine settings: the connection, travel, jog and probe-plate settings (shared by both Macs and
// stored on the hub), and the controller's own $$ table. As 1.0's Settings.

import SGCore
import SGNet
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var travel = Vec3.zero
    @State private var corner = HomeCorner.frontLeft
    @State private var safeZ = 0.0
    @State private var jogXY = 0.0
    @State private var jogZ = 0.0
    @State private var rapid = 0.0
    @State private var steps = ""
    @State private var probe = ProbeConfig(plateThickness: 0, maxTravel: 25, seekFeed: 100, latchFeed: 25, retract: 5)

    var body: some View {
        if let s = model.state { content(s).onAppear { load(s.config) } }
    }

    private func content(_ s: AppState) -> some View {
        let m = s.machine
        let canConnect = (s.link.agentConnected || model.setup?.machine != MachineKind.none) && !s.jobActive
        return DialogFrame(eyebrow: "Settings", title: "Machine", width: 640, height: 560) {
            section("Connection") {
                HStack(spacing: 8) {
                    Dot(ok: s.machineReady)
                    Text(m.simulated ? "Simulator" : m.port ?? "Not connected")
                    if let f = m.firmware { Text(f).foregroundStyle(Color.steel) }
                    Spacer()
                    Button(m.connection == .connected ? "Reconnect" : "Connect") { model.send(.connect(port: nil)) }
                        .gccButton(.normal, .small).disabled(!canConnect)
                    Button("Disconnect") { model.send(.disconnect) }.gccButton(.ghost, .small).disabled(!s.machineReady || s.jobActive)
                }
            }
            section("This Mac") {
                Toggle("Keep the screen on during jobs", isOn: Binding(get: { model.keepScreenOn }, set: { model.keepScreenOn = $0 }))
                    .font(.system(size: 12))
                Muted("While the machine is connected and busy (a job running, paused or waiting for a bit change, or jogging, homing or probing), this Mac's screen stays on and it doesn't sleep. Saved straight away, for this Mac only. Closing a laptop's lid still sleeps it.")
            }
            section("Machine travel (mm)") {
                HStack(spacing: 12) {
                    Field(label: "X") { NumberField(value: $travel.x) }
                    Field(label: "Y") { NumberField(value: $travel.y) }
                    Field(label: "Z") { NumberField(value: $travel.z) }
                }
                Picker("Homing sets machine 0,0,0 at the", selection: $corner) {
                    Text("front-left-top corner: X and Y count up from it (FoxAlien, $23=3)").tag(HomeCorner.frontLeft)
                    Text("back-right-top corner: X and Y count down from it (GRBL default, $23=0)").tag(HomeCorner.backRight)
                }
                .font(.system(size: 12))
                Muted("Check after homing: MACH under the position should read 0,0,0, and jogging right and back should make X and Y \(corner == .frontLeft ? "go up" : "go down"). This places the machine travel in the 3D view and the out-of-travel checks.")
            } accessory: {
                Button("Read from GRBL") { fromGrbl(m.settings ?? [:]) }.gccButton(.ghost, .small).disabled(m.settings == nil)
                    .help("Use $130, $131 and $132 from the controller")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Field(label: "Safe Z for Go to XY0") { NumberField(value: $safeZ) }
                    Field(label: "Jog XY feed") { NumberField(value: $jogXY) }
                    Field(label: "Jog Z feed") { NumberField(value: $jogZ) }
                }
                GridRow {
                    Field(label: "Rapid rate (for estimates)") { NumberField(value: $rapid) }
                    Field(label: "Jog steps (mm)") { TextField("", text: $steps).font(.mono).gccField() }.gridCellColumns(2)
                }
            }
            section("Touch plate (Probe Z)") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Field(label: "Plate thickness", unit: "mm") { NumberField(value: $probe.plateThickness, placeholder: "measure it", zeroEmpty: true) }
                        Field(label: "Search distance", unit: "mm") { NumberField(value: $probe.maxTravel) }
                        Field(label: "Lift after", unit: "mm") { NumberField(value: $probe.retract) }
                    }
                    GridRow {
                        Field(label: "Fast touch", unit: "mm/min") { NumberField(value: $probe.seekFeed) }
                        Field(label: "Slow touch", unit: "mm/min") { NumberField(value: $probe.latchFeed) }
                    }
                }
                Muted("Measure the plate with calipers. Z zero ends up exactly this far below where the bit touches, so an error here is an error in every cut depth.")
            }
            if let st = m.settings, !st.isEmpty {
                section("GRBL settings ($$)") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(st.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { k in
                            let info = Int(k).flatMap { grblSettings[$0] }
                            HStack(spacing: 10) {
                                Text("$\(k)").font(.mono).foregroundStyle(Color.gold).frame(width: 44, alignment: .leading)
                                Text(info?.name ?? "").foregroundStyle(Color.steel).frame(maxWidth: .infinity, alignment: .leading)
                                Text(st[k] ?? "").font(.mono)
                                Text(info?.unit ?? "").foregroundStyle(Color.steel).frame(width: 60, alignment: .leading)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    Muted("Change a setting from the console, e.g. $110=5000.")
                } accessory: {
                    Button("Refresh") { model.send(.refreshSettings) }.gccButton(.ghost, .small).disabled(!s.machineReady || s.jobActive)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }.gccButton().keyboardShortcut(.cancelAction)
            Button("Save") { save() }.gccButton(.primary, .large).keyboardShortcut(.defaultAction)
                .disabled(!s.link.hubConnected).help(s.link.hubConnected ? "" : "Settings are stored on the hub")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        section(title, c) { EmptyView() }
    }

    private func section<C: View, A: View>(_ title: String, @ViewBuilder _ c: () -> C, @ViewBuilder accessory: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(title)
                Spacer()
                accessory()
            }
            c()
        }
        .padding(.bottom, 6)
    }

    private func load(_ c: MachineConfig) {
        guard !loaded else { return }
        loaded = true
        travel = c.envelope.max - c.envelope.min
        corner = HomeCorner(c.envelope)
        safeZ = c.safeZ
        jogXY = c.jogFeedXY
        jogZ = c.jogFeedZ
        rapid = c.rapidRate
        steps = c.jogSteps.map(short).joined(separator: ", ")
        probe = c.probe
    }

    private func fromGrbl(_ st: [String: String]) {
        let t = ["130", "131", "132"].map { st[$0].flatMap { Double($0) } ?? 0 }
        if t.allSatisfy({ $0 > 0 }) { travel = Vec3(t[0], t[1], t[2]) }
        if let c = st["23"].flatMap({ Double($0) }).flatMap({ HomeCorner(dirMask: Int($0)) }) { corner = c }
    }

    private func save() {
        let js = parseJogSteps(steps)
        let patch = MachineConfigPatch(
            envelope: corner.envelope(travel: travel), safeZ: safeZ, jogSteps: js.isEmpty ? nil : js,
            jogFeedXY: jogXY > 0 ? jogXY : nil, jogFeedZ: jogZ > 0 ? jogZ : nil, rapidRate: rapid > 0 ? rapid : nil, probe: probe)
        Task {
            if await model.run(.saveConfig(config: patch)) {
                model.toast(.info, "Settings saved")
                dismiss()
            }
        }
    }
}
