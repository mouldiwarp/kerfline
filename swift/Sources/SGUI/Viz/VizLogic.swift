// The decisions behind the toolpath view and progress panel, kept apart from the views so they
// can be tested: which source line has been cut, where a program leaves the machine's travel,
// and how long is left. Ports of the logic in 1.0's Visualizer.tsx and Progress.tsx.

import SGCore
import SGNet

/// A program loaded for drawing.
public struct LoadedProgram: Sendable {
    public var sha: String
    public var analysis: ProgramAnalysis
    /// Source line of each streamed line, to turn a streamed-line count into a source line.
    public var streamSources: [Int]

    public init(sha: String, text: String, rapidRate: Double) {
        self.sha = sha
        analysis = analyzeProgram(text, options: InterpreterOptions(rapidRate: rapidRate))
        streamSources = streamableLines(text).map(\.source)
    }
}

/// The last source line that has been cut (-1: none; Int.max: all), as 1.0's Visualizer.
/// GRBL acknowledges lines when they're planned, not cut, so without `cuttingLine` step back by
/// the blocks still in the planner (`plannerSize` is the most free blocks it has reported).
public func doneSourceLine(_ job: JobState, _ program: LoadedProgram, plannerFree: Int?, plannerSize: Int) -> Int {
    let src = program.streamSources
    func source(ofStreamed n: Int) -> Int { n > 0 && !src.isEmpty ? src[min(n, src.count) - 1] : -1 }
    if job.status == .done { return Int.max }
    if [.stopped, .error].contains(job.status), let r = job.resumeLine { return source(ofStreamed: r) }
    if let c = job.cuttingLine { return source(ofStreamed: c) }
    let inPlanner = plannerFree.map { max(0, plannerSize - $0) } ?? 0
    return source(ofStreamed: max(0, job.ackedLines - inPlanner))
}

/// Where `bounds` (work coordinates) leaves `envelope` (machine coordinates) from work offset `wco`.
public func travelOverruns(_ bounds: Bounds, envelope env: Bounds, wco: Vec3) -> [String] {
    let names = ["X", "Y", "Z"]
    let lo = ["left of", "in front of", "below"]
    let hi = ["right of", "behind", "above"]
    var out: [String] = []
    for i in 0..<3 {
        let under = env.min[i] - (bounds.min[i] + wco[i])
        let over = bounds.max[i] + wco[i] - env.max[i]
        if over > 0.01 { out.append("\(names[i]) goes \(fixed(over, 1)) mm \(hi[i]) the machine's travel") }
        if under > 0.01 { out.append("\(names[i]) goes \(fixed(under, 1)) mm \(lo[i]) the machine's travel") }
    }
    return out
}

/// What to do about an overrun, from where work zero is.
public func overrunAdvice(envelope env: Bounds, wco: Vec3) -> String {
    if wco == .zero {
        return "Work zero hasn't been set, so it's at the home corner. Jog to the job's origin on the stock, then Zero XY and Zero Z."
    }
    if wco.z > env.max.z + 0.01 {
        return "Z zero is \(fixed(wco.z, 1)) mm above the top of Z travel. Jog Z down to the stock surface and Zero Z again."
    }
    return "Move work zero so the part fits on the bed, or check the file."
}

/// Seconds left, blending the plan with how this run is actually going (nil: unknown).
public func remainingSeconds(_ job: JobState, now: Double = nowMs()) -> Double? {
    guard job.status == .running || job.status == .paused else { return nil }
    let elapsed = job.elapsedSeconds(now: now)
    if let total = job.totalSeconds, total > 0, let done = job.doneSeconds {
        // The plan leaves out acceleration, so scale it by this run's pace once there's enough to go on.
        let left = max(0, total - done)
        let doneThisRun = done - (job.startSeconds ?? 0)
        guard doneThisRun > min(60, total * 0.03), elapsed > 5 else { return left }
        let pace = elapsed / doneThisRun
        return left * (doneThisRun < total * 0.2 ? (pace + 1) / 2 : pace)
    }
    let pct = job.percent
    let byRate = pct > 3 ? elapsed / pct * (100 - pct) : nil
    let byEst = job.estSeconds.map { max($0 - elapsed, 0) }
    if let r = byRate, let e = byEst { return pct < 20 ? (r + e) / 2 : r }
    return byRate ?? byEst
}

public func jobStatusLabel(_ s: JobStatus) -> String {
    switch s {
    case .idle: "Ready"
    case .loading: "Sending file to the machine"
    case .running: "Running"
    case .paused: "Paused"
    case .stopping: "Stopping"
    case .toolchange: "Bit change"
    case .done: "Complete"
    case .stopped: "Stopped"
    case .error: "Failed"
    }
}

public func boundsDims(_ b: Bounds?) -> String {
    guard let b else { return "" }
    let d = b.max - b.min
    return "\(fixed(d.x, 1)) × \(fixed(d.y, 1)) × \(fixed(d.z, 1)) mm"
}

extension Bounds {
    /// Shifted by `-offset`: machine coordinates into work coordinates.
    public func shifted(by offset: Vec3) -> Bounds { Bounds(min: min - offset, max: max - offset) }
}
