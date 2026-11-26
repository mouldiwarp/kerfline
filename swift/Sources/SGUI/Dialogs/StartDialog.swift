// Confirm before starting a job: the machine may be in another room. As 1.0's StartDialog.

import SGCore
import SGNet
import SwiftUI

struct StartDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let req: StartRequest
    @State private var wholeGroup = true
    @State private var busy = false
    @State private var spindleByHand = false

    var body: some View {
        @Bindable var model = model
        if let s = model.state, let item = s.library.first(where: { $0.id == req.fileId }) {
            content(s, item)
                .sheet(isPresented: $model.probeOver) { ProbeDialog(nested: true).environment(model) }
        } else {
            DialogFrame(eyebrow: "Start job", title: "File not found") {
                Muted("The file is no longer in the library.")
            } actions: {
                Button("Close") { dismiss() }.gccButton().keyboardShortcut(.cancelAction)
            }
        }
    }

    private func content(_ s: AppState, _ item: LibraryItem) -> some View {
        let m = s.machine
        let remote = s.link.machineOn != nil && s.link.machineOn != model.name
        let following = req.next ? [] : s.groupFollowing(item)
        let b = item.cutBounds ?? item.bounds
        let problems = s.settingProblems
        var eyebrow = req.next && s.job.group != nil ? "Start file \(s.job.group!.index + 2) of \(s.job.group!.files.count)" : "Start job"
        if remote { eyebrow += " on \(s.link.machineOn ?? "the machine")" }
        var rows = [("Estimated time", formatDuration(item.estSeconds)), ("Lines", item.streamLines.formatted())]
        if let b {
            rows.append(("Cut extents", "X \(fixed(b.min.x, 1)) → \(fixed(b.max.x, 1)) · Y \(fixed(b.min.y, 1)) → \(fixed(b.max.y, 1)) · Z \(fixed(b.min.z, 1)) → \(fixed(b.max.z, 1))"))
        }
        rows += [("Work zero (machine)", xyz(m.wco)), ("Tool now at (work)", xyz(m.wpos))]
        let overruns = b.map { travelOverruns($0, envelope: s.config.envelope, wco: m.wco) } ?? []
        let probed = m.lastProbe?.ok == true && (s.job.finishedAt.map { m.lastProbe!.t > $0 } ?? false)
        // "Start next" runs a group that was checked (and confirmed) when it started.
        let offCuts = req.next ? [] : ([item] + (wholeGroup ? following : [])).compactMap { f in f.spindleOffCut.map { (f.name, $0) } }
        let blocked = !offCuts.isEmpty && !spindleByHand

        return DialogFrame(eyebrow: eyebrow, title: item.name, width: 600) {
            if !following.isEmpty {
                Toggle(isOn: $wholeGroup) {
                    (Text("Then run the rest of ") + Text(item.group ?? "").bold() + Text(" in order, pausing for a bit change before each: ")
                        + Text(following.map(\.name).joined(separator: " → ")).foregroundStyle(Color.steel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            KV(rows: rows, mono: ["Cut extents", "Work zero (machine)", "Tool now at (work)"])
            ZZeroBadge(ref: item.zZero)
            if !overruns.isEmpty, m.homed == true {
                Note(kind: .warn) {
                    Text("⚠ " + overruns.joined(separator: "; ") + ".")
                    Text(overrunAdvice(envelope: s.config.envelope, wco: m.wco)).foregroundStyle(Color.steel)
                }
            }
            if !problems.isEmpty {
                Note(.warn, "⚠ \(problems.count == 1 ? "A controller setting differs" : "\(problems.count) controller settings differ") from \(foxAlien.name): "
                    + problems.map { "$\($0.key) is \($0.actual ?? "?") (should be \($0.expected))" }.joined(separator: ", ") + ". Fix them in the banner at the top first.")
            }
            if let c = model.conflict(for: item.id) {
                Note(.warn, "This file has a conflict (\(c.kind.summary.lowercased())): this Mac's version will run.")
            }
            if !offCuts.isEmpty {
                SpindleOffConfirm(cuts: offCuts, byHand: $spindleByHand)
            }
            if m.homed != true { Note(.info, "The machine isn't homed, so moves aren't checked against its travel.") }
            Muted(m.homed == true
                ? "Before the program runs, the cutter lifts to the top of Z, then moves along X, then Y, to the program's first point; the program lowers it there."
                : "Before the program runs, the cutter lifts to the program's highest Z (not knowing the top of travel), then moves along X, then Y, to its first point.")
            VStack(alignment: .leading, spacing: 6) {
                check("Stock clamped and the right bit fitted and tight")
                if req.next {
                    HStack(spacing: 8) {
                        check("Z re-probed with the new bit, " + zZeroCheck(item.zZero).prefix(1).lowercased() + zZeroCheck(item.zZero).dropFirst())
                        if probed { Text("(done)").foregroundStyle(Color.gold) } else {
                            Button("Probe Z") { model.openProbe() }.gccButton(.outlineGold, .small)
                        }
                    }
                } else {
                    check("Work zero set for this file (X, Y and Z)")
                    check(zZeroCheck(item.zZero))
                }
                if let r = foxAlien.spindleReminder, !m.simulated { check(r) }
                check("Dust collection on, and nobody near the machine")
                if remote { check("Someone can reach the machine's emergency stop") }
            }
        } actions: {
            Button("Cancel") { dismiss() }.gccButton().keyboardShortcut(.cancelAction).disabled(busy)
            Button(busy ? "Starting…" : req.next ? "▶ Start next" : "▶ Start") {
                busy = true
                Task {
                    let ok = await model.run(req.next ? .startNext : .start(
                        fileId: item.id, group: following.isEmpty ? nil : wholeGroup, fromLine: nil, spindleOff: offCuts.isEmpty ? nil : true))
                    busy = false
                    if ok { dismiss() }
                }
            }
            .gccButton(.primary, .large).keyboardShortcut(.defaultAction).disabled(busy || blocked)
        }
    }

    private func check(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "square").font(.system(size: 11)).foregroundStyle(Color.gold)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A program that cuts with the spindle off: GRBL would drive a still cutter into the work, and the spindle button
/// can't start a spindle the program never turned on. Starting needs the box ticked.
struct SpindleOffConfirm: View {
    /// File name and 0-based source line of its first spindle-off cut.
    let cuts: [(String, Int)]
    @Binding var byHand: Bool

    var body: some View {
        Note(kind: .danger) {
            Text("⚠ " + cuts.map { "\($0.0) cuts with the spindle off from line \($0.1 + 1)" }.joined(separator: "; ")
                + ": the program never starts the spindle (M3 with an S speed) before it. SwarfGRBL's spindle button can't start it either.")
            Text("Add M3 S… to the program (in Fretboard Modeller: set Max spindle above 0) and send it again.")
                .foregroundStyle(Color.steel)
            Toggle("The spindle is started by hand for this job", isOn: $byHand)
        }
    }
}
