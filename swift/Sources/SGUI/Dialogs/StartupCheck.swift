// On connecting, compare the controller's $$ settings with the FoxAlien's and offer to fix them.
// As 1.0's StartupCheck banner.

import SGCore
import SGNet
import SwiftUI

struct StartupCheck: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        let m = s.machine
        if m.connection == .connected, !m.simulated, let st = m.settings, !st.isEmpty {
            let problems = s.settingProblems
            let env = s.controllerEnvelopeIfDifferent
            let writeBlocked: String? = m.status == .idle ? nil : m.status == .alarm ? "Home or unlock first" : "The machine is \(m.status.rawValue)"
            if problems.isEmpty, env == nil {
                if !model.settingsOKDismissed {
                    Banner(kind: .info, text: "All \(foxAlien.settings.count) settings match the \(foxAlien.name).") {
                        Button("OK") { model.settingsOKDismissed = true }.gccButton(.normal, .small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("⚠ Controller settings to check").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.warn)
                        Spacer()
                        if let writeBlocked { Text(writeBlocked).font(.system(size: 12)).foregroundStyle(Color.steel) }
                        if problems.count > 1 {
                            Button("Set all") { set(problems) }.gccButton(.warn, .small).disabled(writeBlocked != nil)
                        }
                    }
                    ForEach(problems, id: \.key) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("$\(p.key) is \(p.actual ?? "not reported"), should be \(p.expected)").font(.mono)
                            Text(p.why).font(.system(size: 12)).foregroundStyle(Color.steel).lineLimit(2)
                            Spacer()
                            Button("Set $\(p.key)=\(p.expected)") { set([p]) }.gccButton(.normal, .small).disabled(writeBlocked != nil)
                        }
                    }
                    if let env {
                        HStack(spacing: 10) {
                            Text("The controller's travel (\(boundsDims(env))) differs from Settings (\(boundsDims(s.config.envelope))).")
                            Spacer()
                            Button("Use the controller's") {
                                Task {
                                    if await model.run(.saveConfig(config: MachineConfigPatch(envelope: env))) { model.toast(.info, "Travel updated from the controller") }
                                }
                            }
                            .gccButton(.normal, .small).disabled(!s.link.hubConnected)
                        }
                    }
                    ForEach(foxAlien.hardware, id: \.self) { h in
                        Text("☐ Check by hand: \(h)").font(.system(size: 12)).foregroundStyle(Color.steel)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(Color.offwhite)
                .background(Color.warn.opacity(0.1))
                .background(Color.slate)
                .overlay(alignment: .leading) { Rectangle().fill(Color.warn).frame(width: 3) }
            }
        } else {
            Color.clear.frame(height: 0).onAppear { model.settingsOKDismissed = false }
        }
    }

    private func set(_ ps: [SettingProblem]) {
        let lines = ps.map { "$\($0.key)=\($0.expected)" }
        Task {
            if await model.run(.mdi(line: lines.joined(separator: "\n"))) {
                await model.run(.refreshSettings)
                model.toast(.info, "Set " + ps.map { "$\($0.key)" }.joined(separator: ", "))
            }
        }
    }
}
