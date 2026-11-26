// Z probe with a touch plate: put the plate on the stock under the bit, clip the lead on, and the
// controller touches down twice and sets work Z0 to the stock surface. As 1.0's ProbeDialog.

import SGCore
import SGNet
import SwiftUI

struct ProbeDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Shown above the start or surfacing dialog.
    var nested = false
    @State private var started: Double?

    var body: some View {
        if let s = model.state { content(s) }
    }

    private func content(_ s: AppState) -> some View {
        let m = s.machine
        let p = s.config.probe
        let probing = m.probing == true
        let result = started.flatMap { t in m.lastProbe.flatMap { $0.t >= t ? $0 : nil } }
        let blocked = s.probeBlocked
        return DialogFrame(eyebrow: "Probe Z", title: "Touch plate") {
            Steps {
                Text("Jog the bit over the stock, within \(short(p.maxTravel)) mm of the plate's top.")
                Text("Put the plate flat on the stock under the bit and clip the lead to the bit.")
                HStack(spacing: 8) {
                    Text("Test the circuit: touch the plate to the bit. The light should turn gold.")
                    HStack(spacing: 5) {
                        Circle().fill(s.probeTouching ? Color.gold : Color.steelDim).frame(width: 9, height: 9)
                        Text(s.probeTouching ? "Touching" : "Open").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(s.probeTouching ? Color.goldBright : Color.steel)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Plate thickness").foregroundStyle(Color.steel)
                    HStack(spacing: 8) {
                        if p.plateThickness > 0 { Text("\(short(p.plateThickness)) mm") } else { Text("not set").foregroundStyle(Color.danger) }
                        if nested {
                            Muted("(change it in Settings)")
                        } else {
                            Button("Change") {
                                dismiss()
                                model.dialog = .settings
                            }
                            .gccButton(.ghost, .small)
                        }
                    }
                }
                GridRow {
                    Text("Sequence").foregroundStyle(Color.steel)
                    Text("Down at \(short(p.seekFeed)) mm/min (up to \(short(p.maxTravel)) mm), lift 2 mm, touch again at \(short(p.latchFeed)) mm/min, set Z, then lift to Z\(short(p.plateThickness + p.retract))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Tool now at (work Z)").foregroundStyle(Color.steel)
                    Text(fixed(m.wpos.z, 3)).font(.mono)
                }
            }
            if probing { Note(.info, "Probing… Press Stop probing below (or STOP at the top) to halt it.") }
            if let r = result {
                Note(kind: r.ok ? .ok : .danger) { Text(r.ok ? "Done. " : "Failed. ").bold() + Text(r.message) }
            }
            if !probing { BlockedHint(text: blocked) }
        } actions: {
            if probing { Button("Stop probing") { model.send(.stop) }.gccButton(.danger, .large) }
            Button(result?.ok == true ? "Close" : "Cancel") { close() }.gccButton().keyboardShortcut(.cancelAction).disabled(probing)
            Button(probing ? "Probing…" : result?.ok == true ? "Probe again" : "↧ Probe") {
                started = nowMs() - 50
                model.send(.probeZ)
            }
            .gccButton(.primary, .large).keyboardShortcut(.defaultAction)
            .disabled(blocked != nil || probing).help(blocked ?? "")
        }
        .interactiveDismissDisabled(probing)
    }

    private func close() {
        if nested { model.probeOver = false } else { dismiss() }
    }
}
