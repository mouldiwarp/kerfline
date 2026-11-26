// Restart a stopped job part way through, from the line it stopped on or one you pick. As 1.0's
// ResumeDialog: the plan (lift, spin up, X, Y, lower) comes from SGCore's planResume.

import SGCore
import SGNet
import SwiftUI

struct ResumeDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var lines: [StreamLine] = []
    @State private var error: String?
    /// 1-based.
    @State private var line = 1.0
    @State private var busy = false
    /// Source lines that cut with the spindle off.
    @State private var offCuts: [Int] = []
    @State private var spindleByHand = false

    var body: some View {
        if let s = model.state { content(s) }
    }

    private func content(_ s: AppState) -> some View {
        let job = s.job
        let n = Int(line)
        let index = n - 1
        let plan: Result<ResumePlan, Error>? = text.flatMap { t in
            guard index >= 1, index < lines.count else { return nil }
            return Result { try planResume(t, index, ResumeOptions(machine: s.machine, config: s.config)) }
        }
        let planned = try? plan?.get()
        let offCut = index >= 0 && index < lines.count ? offCuts.first { $0 >= lines[index].source } : nil
        let blocked = s.notIdleReason ?? (job.fileId == nil ? "No job to resume" : nil) ?? planFailure(plan)
            ?? (offCut != nil && !spindleByHand ? "The program cuts with the spindle off" : nil)
        return DialogFrame(eyebrow: "Resume job", title: job.fileName ?? "Job", width: 640) {
            if let error { Note(.danger, error) }
            if text == nil, error == nil { Muted("Loading the file…") }
            if text != nil {
                HStack(alignment: .bottom, spacing: 10) {
                    Field(label: "Resume from line") { NumberField(value: $line).frame(width: 110) }
                    Text("of \(lines.count.formatted())").font(.system(size: 12)).foregroundStyle(Color.steel).padding(.bottom, 7)
                    if let r = job.resumeLine, n != r + 1 {
                        Button("back to where it stopped (\(r + 1))") { line = Double(r + 1) }.gccButton(.ghost, .small).padding(.bottom, 3)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    let lo = max(0, index - 2)
                    ForEach(lo..<max(lo, min(lines.count, index + 3)), id: \.self) { i in
                        Text(String(repeating: " ", count: max(0, 6 - String(i + 1).count)) + "\(i + 1) \(i == index ? "▶" : " ") \(lines[i].text)")
                            .font(.mono).foregroundStyle(i == index ? Color.goldBright : Color.steel).lineLimit(1)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.obsidian))
                Muted("Going back a line or two is safe: it re-cuts a little of the same path.")
            }
            if let p = planned {
                Steps {
                    Text(s.machine.homed == true
                        ? "Lift straight up to Z\(fixed(p.travelZ, 1)), just under the top of travel."
                        : "Lift straight up to Z\(fixed(p.travelZ, 1)) (the machine isn't homed, so the top of travel isn't known).")
                    if p.state.spindle != "M5" {
                        Text("Start the spindle (\(p.state.spindle == "M3" ? "clockwise" : "counter-clockwise"), S\(short(p.state.speed))) and wait 4 s for it to reach speed.")
                    }
                    Text("Move along X to X\(fixed(p.start.x, 2)), then along Y to Y\(fixed(p.start.y, 2)), where line \(n) starts.")
                    if p.start.z < p.travelZ {
                        Text((p.clearZ < p.travelZ ? "Drop to Z\(fixed(p.clearZ, 1)), then lower" : "Lower")
                            + " to Z\(fixed(p.start.z, 2)) at \(short(min(300, s.config.jogFeedZ))) mm/min, then carry on with the program.")
                    } else {
                        Text("Carry on with the program.")
                    }
                }
                if !p.state.warnings.isEmpty { Note(.warn, p.state.warnings.joined(separator: ". ") + ".") }
            }
            if let offCut, let name = job.fileName { SpindleOffConfirm(cuts: [(name, offCut)], byHand: $spindleByHand) }
            Muted("Before resuming: the same bit is fitted, nothing is in the way, and work zero hasn't changed. If the machine was switched off or raised an alarm, home it first (work zero is kept).")
            BlockedHint(text: blocked)
        } actions: {
            Button("Cancel") { dismiss() }.gccButton().keyboardShortcut(.cancelAction)
            Button(busy ? "Starting…" : "▶ Resume from line \(n)") {
                guard let id = job.fileId else { return }
                busy = true
                Task {
                    let ok = await model.run(.start(fileId: id, group: nil, fromLine: index, spindleOff: offCut == nil ? nil : true))
                    busy = false
                    if ok { dismiss() }
                }
            }
            .gccButton(.primary, .large).keyboardShortcut(.defaultAction).disabled(blocked != nil || busy)
        }
        .task(id: job.fileId) { await load(job) }
        .onChange(of: line) { _, v in
            let c = Double(min(max(1, Int(v)), max(1, lines.count)))
            if c != v, !lines.isEmpty { line = c }
        }
    }

    private func planFailure(_ plan: Result<ResumePlan, Error>?) -> String? {
        switch plan {
        case nil: text == nil ? "Loading the file" : "Pick a line from 2 to \(lines.count)"
        case .failure(let e): (e as? ResumeError)?.description ?? e.localizedDescription
        case .success: nil
        }
    }

    private func load(_ job: JobState) async {
        guard let id = job.fileId, let lib = model.instance?.library else { return }
        guard let data = await lib.content(id), let t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            error = "Could not load the file"
            return
        }
        let (ls, off) = await Task.detached { (streamableLines(t), spindleOffCuts(t)) }.value
        lines = ls
        offCuts = off
        text = t
        line = Double((job.resumeLine ?? 0) + 1)
    }
}
