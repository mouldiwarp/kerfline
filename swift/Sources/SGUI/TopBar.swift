// The top bar (who's connected, the machine's state, Home/Unlock/Reset/Hold/Stop) and the banners
// under it, as 1.0's TopBar.tsx and Banners.tsx.

import SGCore
import SGNet
import SwiftUI

struct TopBar: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text("SWARFGRBL").font(.custom("Helvetica", size: 13).weight(.bold)).tracking(3).foregroundStyle(Color.gold)
            if model.setup?.trial == true { Badge(text: "2.0 TRIAL", color: .warn) }
            Pill {
                Dot(ok: s.link.hubConnected)
                Text(s.link.via == .hub ? "Hub (this Mac)" : "Hub \(s.link.hubName ?? "")")
            }
            Pill {
                Dot(ok: s.link.agentConnected)
                Text(s.link.via == .agent ? "Agent (this Mac)" : s.link.agentName.map { "Agent \($0)" } ?? "Agent")
            }
            Pill(tint: statusTint) {
                Dot(ok: s.machineReady && s.machine.status != .alarm)
                Text(s.machineLabel).foregroundStyle(statusColor)
                if let on = s.link.machineOn { Text("on \(on)").foregroundStyle(Color.steel) }
                if s.machine.simulated { Badge(text: "SIM", color: .info) }
            }
            if s.machine.connection == .disconnected, model.setup?.machine != MachineKind.none {
                Button("Connect") { model.send(.connect(port: nil)) }.gccButton(.outlineGold, .small)
            }
            Spacer()
            Button("Home") { model.send(.home) }.gccButton()
                .disabled(!s.machineReady || s.jobActive || ![.idle, .alarm].contains(s.machine.status))
                .help("Run the homing cycle ($H)")
            Button("Unlock") { model.send(.unlock) }.gccButton()
                .disabled(!s.machineReady || s.machine.status != .alarm)
                .help("Clear the alarm without homing ($X)")
            Button("Reset") { model.send(.reset) }.gccButton(.warn)
                .disabled(!s.machineReady)
                .help("Soft reset (Ctrl-X): stops everything at once")
            Button(s.machine.status == .hold ? "Resume" : "Hold") { model.send(s.machine.status == .hold ? .resume : .hold) }
                .gccButton(.warn)
                .disabled(!s.machineReady)
                .help("Feed hold / resume (⇧⌘H)")
            Button("STOP") { model.send(.stop) }.gccButton(.danger)
                .disabled(!s.machineReady)
                .help("Stop the job or motion (⌘.)")
            Button {
                model.dialog = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .gccButton(.ghost).help("Machine settings (⇧⌘,)")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.slate)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    private var statusColor: Color {
        switch s.machine.status {
        case .alarm: .danger
        case .hold, .door: .warn
        case .run, .jog, .home: .gold
        case .idle: s.machineReady ? .ok : .steel
        default: .offwhite
        }
    }

    private var statusTint: Color { s.machine.status == .alarm ? .dangerDim : .slate2 }
}

struct Banners: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    private var simulatorButton: some View {
        Button("Use the simulator") { model.useSimulator(true) }.gccButton(.primary, .small)
            .help("Run the built-in GRBL simulator until you switch back or restart; the saved setup isn't changed")
    }

    var body: some View {
        VStack(spacing: 0) {
            StartupCheck(s: s)
            UpdateBanner(s: s)
            if s.link.via == .agent, !s.link.hubConnected {
                Banner(kind: .info, text: "Hub offline: working on this Mac's copy of the library. Changes sync when it's back.")
            }
            if model.simulating {
                Banner(kind: .info, text: "Simulator: nothing here moves a real machine\(model.setup?.machine == .usb ? ", and the machine on USB is left alone" : "").") {
                    Button("Back to the machine") { model.useSimulator(false) }.gccButton(.normal, .small).disabled(s.jobActive)
                }
            } else if s.link.via == .hub, !s.link.agentConnected, s.link.machineOn == nil, model.setup?.machine == MachineKind.none {
                Banner(kind: .info, text: "The garage Mac isn't connected. Open SwarfGRBL there to use the machine, or try things out on the simulator.") {
                    simulatorButton
                }
            } else if model.setup?.machine == .usb, s.link.machineOn == nil, model.settledAfterLaunch {
                Banner(kind: .info, text: "No machine found on USB. Plug the FoxAlien in (it connects by itself), or try things out on the simulator.") {
                    simulatorButton
                }
            }
            if let a = s.machine.alarm {
                Banner(kind: .danger, text: "ALARM \(a.code): \(a.message)") {
                    Button("Home") { model.send(.home) }.gccButton(.normal, .small)
                    Button("Unlock") { model.send(.unlock) }.gccButton(.normal, .small)
                }
            } else if s.machine.status == .alarm {
                Banner(kind: .danger, text: "Machine is locked. Home it, or Unlock to move without homing.") {
                    Button("Home") { model.send(.home) }.gccButton(.normal, .small)
                    Button("Unlock") { model.send(.unlock) }.gccButton(.normal, .small)
                }
            }
            if s.job.status == .toolchange {
                Banner(kind: .warn, text: bitChangeText) {
                    Button("Probe Z…") { model.openProbe() }.gccButton(.normal, .small).disabled(s.machine.status != .idle)
                    if s.nextGroupFile != nil {
                        Button("Start next") { model.confirmStart = StartRequest(fileId: s.nextGroupFile!.id, next: true) }
                            .gccButton(.primary, .small).disabled(s.machine.status != .idle)
                    }
                    Button("End group") { model.send(.clearJob) }.gccButton(.ghost, .small)
                }
            }
            if s.job.status == .paused, s.job.error != nil {
                Banner(kind: .warn, text: "Paused on an error: \(s.job.error ?? ""). Resume to carry on, or Stop.")
            }
            if !model.conflicts.isEmpty {
                Banner(kind: .warn, text: "\(model.conflicts.count) library \(model.conflicts.count == 1 ? "conflict" : "conflicts") between the Macs.") {
                    Button("Resolve…") { model.conflictsOpen = true }.gccButton(.normal, .small)
                }
            }
        }
    }

    private var bitChangeText: String {
        guard let n = s.nextGroupFile else { return "Group finished." }
        return "Bit change: \(s.job.fileName ?? "") is done. Fit the bit for \(n.name) (\(n.index + 1) of \(n.total)), re-probe Z, then start it."
    }
}

extension Banner where Actions == EmptyView {
    init(kind: Kind, text: String) { self.init(kind: kind, text: text) { EmptyView() } }
}

struct Banner<Actions: View>: View {
    enum Kind { case info, warn, danger }
    let kind: Kind
    let text: String
    @ViewBuilder var actions: Actions

    init(kind: Kind, text: String, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        let c: Color = kind == .danger ? .danger : kind == .warn ? .warn : .info
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.offwhite)
            Spacer()
            actions
        }
        .frame(minHeight: 34)
        .padding(.leading, 13).padding(.trailing, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(c.opacity(0.12))
        .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}
