// The job panel: what's selected or running, Start/Pause/Resume/Stop, the bit-change steps, the
// paused box, and overrides, as 1.0's JobPanel.tsx. Phase 6 adds progress, probe and resume dialogs.

import GCCCore
import GCCNet
import SwiftUI

struct JobPanel: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        let job = s.job
        let next = s.nextGroupFile
        let active = s.jobActive
        let selected = model.selected
        let hint = s.startHint(selected: selected)
        let idle = s.machineReady && s.machine.status == .idle
        let nextZ = next.flatMap { n in s.library.first { $0.id == n.id }?.zZero }

        Panel("Job") {
            if [.done, .stopped, .error].contains(job.status) {
                Button("Clear") { model.send(.clearJob) }.gccButton(.ghost, .small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(next.map { "Next · file \($0.index + 1) of \($0.total)" } ?? (active ? "Running" : job.status == .stopped && job.lifted == true ? "Paused" : "Selected"))
                Text(next?.name ?? (active ? job.fileName ?? "—" : selected?.name ?? "—"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.offwhite).lineLimit(2)
                if let f = next.map({ n in s.library.first(where: { $0.id == n.id }) }) ?? (active ? s.library.first(where: { $0.id == job.fileId }) : selected) {
                    HStack(spacing: 8) {
                        if f.estSeconds > 0 { Text("~\(formatDuration(f.estSeconds))") }
                        Text(dims(f))
                        if let g = f.group { Text("group \(g)") }
                    }
                    .font(.system(size: 12)).foregroundStyle(Color.steel)
                    ZZeroBadge(ref: f.zZero).padding(.top, 4)
                }
                if active || [.done, .stopped, .error].contains(job.status) {
                    progress(job)
                }
                if let e = job.error, job.status == .error {
                    Text(e).font(.system(size: 12)).foregroundStyle(Color.danger)
                }
            }

            if next != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. The spindle is off. Fit the bit for this file.")
                    HStack {
                        Text(nextZ.map { "2. Re-probe Z on the \($0 == .spoilboard ? "SPOILBOARD" : "TOP of the material")." } ?? "2. Re-probe Z.")
                        Button("Probe Z…") { model.openProbe() }.gccButton(.outlineGold, .small).disabled(!idle)
                    }
                    Text("3. Start the next file.")
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.offwhite)
                HStack(spacing: 8) {
                    Button("Start next") { model.confirmStart = StartRequest(fileId: next!.id, next: true) }
                        .gccButton(.primary, .large).wide().disabled(!idle)
                    Button("End group") { model.send(.clearJob) }.gccButton(.normal, .large).wide()
                        .help("Stop here and skip the remaining files")
                }
            } else if !active, job.status == .stopped, job.lifted == true, job.resumeLine != nil,
                      s.library.contains(where: { $0.id == job.fileId }) {
                HStack(spacing: 8) {
                    Button("Resume…") { model.dialog = .resume }.gccButton(.primary, .large).wide().disabled(!idle)
                        .help("Spins up, moves back over the cut, lowers and carries on from the line it paused on")
                    Button("Stop") { model.send(.clearJob) }.gccButton(.danger, .large).wide()
                        .help("End the job here")
                }
            } else if !active {
                Button("Start") {
                    if let f = selected { model.confirmStart = StartRequest(fileId: f.id, next: false) }
                }
                .gccButton(.primary, .large).wide()
                .disabled(hint != nil)
                .help(hint ?? "Run the selected file")
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Color.steel).frame(maxWidth: .infinity) }
            } else {
                HStack(spacing: 8) {
                    if job.status == .paused {
                        Button("Resume") { model.send(.resume) }.gccButton(.primary, .large).wide().disabled(!s.machineReady)
                    } else {
                        Button("Pause") { model.send(.pauseLift) }.gccButton(.warn, .large).wide().disabled(!s.machineReady || job.status != .running)
                            .help("Stop at the current line, spindle off, and raise Z to the top. Resume carries on from that line.")
                    }
                    Button("Stop") { model.send(.stop) }.gccButton(.danger, .large).wide().disabled(!s.machineReady || job.status == .stopping)
                }
            }

            if job.status == .paused { PausedBox(s: s) }

            if !active, next == nil, [.stopped, .error].contains(job.status), let line = job.resumeLine, s.library.contains(where: { $0.id == job.fileId }) {
                VStack(alignment: .leading, spacing: 6) {
                    if job.lifted == true {
                        Text("Paused at line \(line + 1) of \(job.totalLines). The spindle is off and Z is raised.").font(.system(size: 12.5))
                        Text("Clear chips or fix the problem (don't move work zero), then Resume: it spins up, moves back over and lowers to carry on.")
                            .font(.system(size: 12)).foregroundStyle(Color.steel)
                    } else {
                        Text("Stopped at line \(line + 1) of \(job.totalLines) of \(job.fileName ?? "the file").").font(.system(size: 12.5))
                        Text("Deal with the problem (jog, clear chips, change the bit), then carry on from where it stopped.")
                            .font(.system(size: 12)).foregroundStyle(Color.steel)
                        Button("Resume from line \(line + 1)…") { model.dialog = .resume }
                        .gccButton(.outlineGold).disabled(!idle)
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
            }

            Eyebrow("Overrides").padding(.top, 6)
            OverrideRow(label: "Feed", kind: .feed, value: s.machine.overrides.feed, disabled: !s.machineReady)
            OverrideRow(label: "Spindle", kind: .spindle, value: s.machine.overrides.spindle, disabled: !s.machineReady)
            HStack(spacing: 4) {
                Text("Rapid").font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 56, alignment: .leading)
                ForEach([(OverrideAction.r25, 25.0), (.r50, 50), (.reset, 100)], id: \.1) { action, v in
                    Button("\(Int(v))%") { model.send(.override(kind: .rapid, action: action)) }
                        .gccButton(.normal, .small, active: s.machine.overrides.rapid == v).wide()
                }
            }
            .disabled(!s.machineReady)
        }
    }

    @ViewBuilder private func progress(_ job: JobState) -> some View {
        let fraction: Double =
            if let t = job.totalSeconds, t > 0, let d = job.doneSeconds { min(1, d / t) } else if job.totalLines > 0 {
                Double(job.ackedLines) / Double(job.totalLines)
            } else { 0 }
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: job.status == .done ? 1 : fraction).tint(job.status == .error ? .danger : .gold)
            HStack {
                Text("\(Int((job.status == .done ? 1 : fraction) * 100))%")
                Spacer()
                Text("line \(max(0, job.ackedLines)) of \(job.totalLines)")
                if let t = job.totalSeconds, let d = job.doneSeconds, job.status.isActive {
                    Text("· \(formatDuration(max(0, t - d))) left")
                }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.steel)
        }
        .padding(.top, 4)
    }
}

/// While paused: stop the spindle (GRBL restarts it, and waits for it, on Resume), or Stop to move away.
struct PausedBox: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        let m = s.machine
        let settled = m.status == .hold && m.subState == 0
        let spinning = m.accessories.map { $0.contains("S") || $0.contains("C") } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(!settled ? "Slowing to a stop…" : spinning ? "Paused. The spindle is still running." : "Paused, spindle stopped.")
                    .font(.system(size: 12.5))
                Spacer()
                Button(spinning || !settled ? "Stop spindle" : "Start spindle") { model.send(.spindleStop) }
                    .gccButton(.normal, .small).disabled(!settled)
            }
            Text(
                (spinning || !settled ? "Resume carries on from here." : "Resume starts the spindle and waits for it to reach speed before moving.")
                    + " GRBL can't jog while paused: to move the cutter away, press Stop, then resume from the line afterwards."
            )
            .font(.system(size: 12)).foregroundStyle(Color.steel)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
    }
}

struct OverrideRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    let kind: OverrideKind
    let value: Double
    let disabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 56, alignment: .leading)
            Button("−10") { model.send(.override(kind: kind, action: .minus10)) }.gccButton(.normal, .small)
            Button("−1") { model.send(.override(kind: kind, action: .minus1)) }.gccButton(.normal, .small)
            Button("\(Int(value))%") { model.send(.override(kind: kind, action: .reset)) }
                .gccButton(.ghost, .small).font(.mono).wide().help("Reset to 100%")
            Button("+1") { model.send(.override(kind: kind, action: .plus1)) }.gccButton(.normal, .small)
            Button("+10") { model.send(.override(kind: kind, action: .plus10)) }.gccButton(.normal, .small)
        }
        .disabled(disabled)
    }
}
