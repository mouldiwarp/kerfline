// The centre of the window: the toolpath of the selected (or running) file in 3D, with what's
// been cut in gold, the tool, the machine's travel and work zero, as 1.0's Visualizer.tsx.

import GCCCore
import GCCNet
import MetalKit
import SwiftUI

/// Owns the renderer so SwiftUI updates can reach it.
@MainActor @Observable
final class VizController {
    @ObservationIgnored var renderer: ToolpathRenderer?
    var view: ViewName = .iso
    var program: LoadedProgram?
    var loadingId: String?
    var error: String?
    @ObservationIgnored var plannerSize = 15
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var lastEnvelope: Bounds??

    /// Load and draw `item` (nil clears the view). Analysis runs off the main actor.
    func show(_ item: LibraryItem?, model: AppModel, rapidRate: Double) async {
        let key = item.map { "\($0.id)/\($0.sha256)" }
        guard key != loadedKey else { return }
        loadedKey = key
        error = nil
        guard let item else {
            program = nil
            renderer?.setProgram(nil, bounds: nil)
            return
        }
        if program?.sha == item.sha256 { return }
        loadingId = item.id
        defer { if loadingId == item.id { loadingId = nil } }
        guard let lib = model.instance?.library, let data = await lib.content(item.id) else {
            if loadedKey == key { error = "Could not load the file" }
            return
        }
        let sha = item.sha256
        let loaded = await Task.detached(priority: .userInitiated) {
            LoadedProgram(sha: sha, text: String(decoding: data, as: UTF8.self), rapidRate: rapidRate)
        }.value
        guard loadedKey == key else { return }
        program = loaded
        renderer?.setProgram(loaded.analysis.segments, bounds: loaded.analysis.bounds)
    }

    func setEnvelope(_ b: Bounds?) {
        if let last = lastEnvelope, last == b { return }
        lastEnvelope = .some(b)
        renderer?.setEnvelope(b)
    }

    func pick(_ v: ViewName) {
        view = v
        renderer?.setView(v)
    }
}

struct MetalToolpathView: NSViewRepresentable {
    let controller: VizController

    func makeNSView(context: Context) -> ToolpathMTKView {
        let v = ToolpathMTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 4
        v.clearColor = MTLClearColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1)
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        if let device = v.device, let r = ToolpathRenderer(device: device, sampleCount: v.sampleCount) {
            r.view = v
            v.delegate = r
            v.renderer = r
            controller.renderer = r
            if let p = controller.program { r.setProgram(p.analysis.segments, bounds: p.analysis.bounds) }
        }
        return v
    }

    func updateNSView(_ v: ToolpathMTKView, context: Context) {}
}

struct Visualizer: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var viz = VizController()

    var body: some View {
        let job = s.job
        let next = s.nextGroupFile
        let showingJob = job.status != .idle && next == nil && job.fileId != nil
        let fileId = next?.id ?? (showingJob ? job.fileId : model.previewId)
        let item = fileId.flatMap { id in s.library.first { $0.id == id } }
        let connected = s.machineReady
        let env = s.config.envelope
        let wco = s.machine.wco

        ZStack(alignment: .topLeading) {
            MetalToolpathView(controller: viz)
            overlay(item: item, showingJob: showingJob, connected: connected, env: env, wco: wco)
            if item == nil {
                VStack(spacing: 6) {
                    Text("No toolpath loaded").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.offwhite)
                    Text("Pick a file in the library, or send one from Swarf.").font(.system(size: 12.5)).foregroundStyle(Color.steel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            if viz.loadingId != nil || viz.error != nil {
                Text(viz.error ?? "Loading toolpath…")
                    .font(.system(size: 12.5)).foregroundStyle(viz.error != nil ? Color.danger : .steel)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.slate2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
        .task(id: item.map { "\($0.id)/\($0.sha256)" } ?? "") {
            await viz.show(item, model: model, rapidRate: s.config.rapidRate)
        }
        .onChange(of: progressKey(showingJob), initial: true) { updateProgress(showingJob) }
        .onChange(of: viz.program?.sha) { updateProgress(showingJob) }
        .onChange(of: connected ? s.machine.wpos : nil, initial: true) { _, p in viz.renderer?.setTool(p) }
        .onChange(of: connected ? env.shifted(by: wco) : nil, initial: true) { _, b in viz.setEnvelope(b) }
    }

    private func progressKey(_ showingJob: Bool) -> [Int] {
        let j = s.job
        return [showingJob ? 1 : 0, j.status.hashValue, j.ackedLines, j.resumeLine ?? -2, j.cuttingLine ?? -2, s.machine.buffer?.planner ?? -1]
    }

    private func updateProgress(_ showingJob: Bool) {
        if let p = s.machine.buffer?.planner { viz.plannerSize = max(viz.plannerSize, p) }
        guard showingJob, let p = viz.program else {
            viz.renderer?.setProgress(-1)
            return
        }
        viz.renderer?.setProgress(doneSourceLine(s.job, p, plannerFree: s.machine.buffer?.planner, plannerSize: viz.plannerSize))
    }

    @ViewBuilder
    private func overlay(item: LibraryItem?, showingJob: Bool, connected: Bool, env: Bounds, wco: Vec3) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let item {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(showingJob ? "Job" : "Preview")
                        Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.offwhite).lineLimit(1)
                        Text("\(boundsDims(item.cutBounds ?? item.bounds)) · ~\(formatDuration(item.estSeconds)) · \(item.streamLines.formatted()) lines")
                            .font(.system(size: 12)).foregroundStyle(Color.steel)
                        ZZeroBadge(ref: item.zZero, compact: true).padding(.top, 2)
                        let overruns = connected ? item.bounds.map { travelOverruns($0, envelope: env, wco: wco) } ?? [] : []
                        if !overruns.isEmpty {
                            Text("⚠ From this work zero the toolpath leaves the machine's travel: \(overruns.joined(separator: "; ")). \(overrunAdvice(envelope: env, wco: wco))")
                                .font(.system(size: 12)).foregroundStyle(Color.warn)
                                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian.opacity(0.85)))
                                .frame(maxWidth: 440, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.slate.opacity(0.8)))
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(ViewName.allCases, id: \.self) { v in
                        Button(v.rawValue.capitalized) { viz.pick(v) }
                            .gccButton(viz.view == v ? .normal : .ghost, .small, active: viz.view == v)
                    }
                }
            }
            Spacer()
            HStack(spacing: 14) {
                Legend(color: Color(hex: 0x9a9a9a), text: "To cut")
                Legend(color: .gold, text: "Cut")
                Legend(color: Color(hex: 0x4a4a4a), text: "Rapid")
                if connected {
                    Legend(color: Color(hex: 0x5a5a5a), text: "Machine travel", box: true)
                        .help("Everywhere the spindle can reach, from homing and the travel in Settings")
                    HStack(spacing: 2) {
                        Rectangle().fill(Color.axisX).frame(width: 6, height: 2)
                        Rectangle().fill(Color.axisY).frame(width: 6, height: 2)
                        Rectangle().fill(Color.axisZ).frame(width: 6, height: 2)
                        Text("Work zero").padding(.leading, 4)
                    }
                    .help("The job's 0,0,0. Set it with Zero XY and Zero Z")
                }
                Spacer()
                Text("Drag to orbit · ⌥-drag to pan · scroll to zoom · double-click to refit").foregroundStyle(Color.steelDim)
            }
            .font(.system(size: 11)).foregroundStyle(Color.steel)
        }
        .padding(10)
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var box = false
    var body: some View {
        HStack(spacing: 5) {
            if box {
                RoundedRectangle(cornerRadius: 1).strokeBorder(color, lineWidth: 1).frame(width: 10, height: 10)
            } else {
                Rectangle().fill(color).frame(width: 12, height: 3)
            }
            Text(text)
        }
    }
}

/// Under the 3D view: what the job is doing, how far through, elapsed and remaining.
struct ProgressPanel: View {
    let s: AppState

    var body: some View {
        let job = s.job
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date.timeIntervalSince1970 * 1000
            let pct = job.percent
            let elapsed = job.elapsedSeconds(now: now)
            let remaining = remainingSeconds(job, now: now)
            let lineNow = job.status == .done ? job.totalLines : job.cuttingLine.map { $0 + 1 } ?? job.ackedLines
            HStack(spacing: 18) {
                Text(pct < 10 && pct > 0 ? fixed(pct, 1) + "%" : "\(Int(pct.rounded()))%")
                    .font(.system(size: 28, weight: .light, design: .rounded)).foregroundStyle(Color.offwhite)
                    .frame(minWidth: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text((job.status == .stopped && job.lifted == true ? "Paused" : jobStatusLabel(job.status)).uppercased()).font(.heading).tracking(1.4)
                            .foregroundStyle(job.status == .error ? Color.danger : [.paused, .toolchange].contains(job.status) ? .warn : .gold)
                        Text(
                            (job.group.map { "\($0.name) \($0.index + 1)/\($0.files.count) · " } ?? "") + (job.fileName ?? "No job")
                                + (job.startedBy.map { " · started by \($0)" } ?? "")
                        )
                        .font(.system(size: 12)).foregroundStyle(Color.steel).lineLimit(1).truncationMode(.middle)
                    }
                    ProgressView(value: min(1, max(0, pct / 100)))
                        .tint(job.status == .error ? .danger : job.status == .paused ? .warn : .gold)
                    HStack(spacing: 4) {
                        Text("Line \(lineNow.formatted()) / \(job.totalLines.formatted())")
                        if job.cuttingLine != nil, job.ackedLines > lineNow, [.running, .paused].contains(job.status) {
                            Text("· queued to \(job.ackedLines.formatted())").foregroundStyle(Color.steelDim)
                                .help("Lines GRBL has accepted into its queue, ahead of the one it is cutting")
                        }
                        Spacer()
                        if let e = job.error { Text(e).foregroundStyle(Color.danger).lineLimit(1) }
                    }
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.steel)
                }
                Stat(label: "Elapsed", value: job.startedAt != nil ? formatDuration(elapsed) : "--:--")
                Stat(label: "Remaining", value: remaining.map(formatDuration) ?? "--:--")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.slate))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(label)
            Text(value).font(.system(size: 17, design: .monospaced)).foregroundStyle(Color.offwhite)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}
