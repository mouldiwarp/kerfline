// The window's model: the running Instance, the latest AppState from it, toasts, and what's open.
// Every button sends a Command through `run`, which shows a refusal as a toast (as 1.0's store).

import AppKit
import Foundation
import SGCore
import SGLibrary
import SGMachine
import SGNet
import Observation
import UserNotifications

public enum Dialog: String, Identifiable, Sendable {
    case probe, resume, surfacing, settings
    public var id: String { rawValue }
}

public struct ToastItem: Identifiable, Equatable {
    public let id = UUID()
    public var level: Toast.Level
    public var text: String
}

/// A file waiting for the start confirmation.
public struct StartRequest: Identifiable, Equatable {
    public var id: String { fileId }
    public var fileId: String
    /// The next file of a group, after a bit change.
    public var next: Bool
}

/// Where updating this Mac's app has got to.
public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case available(UpdateCheck)
    case running(String)
    /// Pulled and rebuilt: restart to run it (held while a job runs here).
    case ready
    case failed(String)
}

@MainActor @Observable
public final class AppModel {
    public private(set) var setup: AppSetup?
    public internal(set) var state: AppState?
    public private(set) var instance: Instance?
    /// Why the app couldn't start (a busy port, an unreadable library).
    public private(set) var launchError: String?
    /// Running the built-in simulator for now, in place of the machine the setup names (until
    /// "Back to the machine" or the next launch; the saved setup isn't changed).
    public private(set) var simulating = false
    /// A few seconds after launch: long enough for a plugged-in machine to connect, or the other
    /// Mac to say it has it, so "no machine" isn't offered while it's still being found.
    public private(set) var settledAfterLaunch = false
    private var settleTask: Task<Void, Never>?
    public private(set) var toasts: [ToastItem] = []
    /// "All settings match" was acknowledged for this connection (shown again after a reconnect).
    public var settingsOKDismissed = false
    public private(set) var conflicts: [LibraryConflict] = []
    public private(set) var trash: [TrashItem] = []

    /// The library file selected (shown in the 3D view when no job is loaded).
    public var previewId: String?
    public var confirmStart: StartRequest?
    public var managerOpen = false { didSet { if managerOpen { Task { await refreshTrash() } } } }
    public var conflictsOpen = false
    public var uploadOpen = false
    /// The machine dialogs (one at a time; the start confirmation is `confirmStart`).
    public var dialog: Dialog?
    /// Probe Z opened from inside the start or surfacing dialog, shown above it.
    public var probeOver = false

    // Jog settings for this Mac (the step is remembered; the feeds start from the shared config).
    public var jogStep: Double = UserDefaults.standard.double(forKey: "swarfgrbl.jogStep") {
        didSet { UserDefaults.standard.set(jogStep, forKey: "swarfgrbl.jogStep") }
    }
    public var jogFeedXY: Double = 0
    public var jogFeedZ: Double = 0

    private var eventTask: Task<Void, Never>?
    private var refreshPending = false
    private var lastJob: JobStatus?
    private var lastAlarm: Int?
    private let notifications: Bool

    // MARK: Updates and keep-awake
    public let build: BuildInfo
    public private(set) var update: UpdateStatus = .idle
    /// This Mac's commit, short, when it isn't on GitHub yet (committed here but not pushed): the other Mac can't
    /// update to it. Set by each update check.
    public private(set) var unpublishedCode: String?
    private var checkTask: Task<Void, Never>?
    /// A release build's updater (Sparkle); nil for a build from git.
    private var release: ReleaseUpdater?
    private let keepAwake = KeepAwake()
    /// Keeping this Mac awake because it owns the machine.
    public var keepingAwake: Bool { keepAwake.isOn }
    /// This Mac's setting: keep the screen on (and the Mac awake) while the machine is busy, whichever Mac has it.
    public var keepScreenOn: Bool = UserDefaults.standard.bool(forKey: AppModel.keepScreenOnKey) {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: AppModel.keepScreenOnKey)
            if let state { applyKeepAwake(state) }
        }
    }
    static let keepScreenOnKey = "swarfgrbl.keepScreenOn"
    /// Holding the screen on now.
    public var keepingScreenOn: Bool { keepAwake.screenOn }

    private func applyKeepAwake(_ s: AppState) {
        keepAwake.set(s.link.machineOn == name && s.machine.connection != .disconnected)
        keepAwake.setScreen(keepScreenOn && s.machineBusy)
    }

    public init(build: BuildInfo = .current) {
        self.build = build
        // Notifications need an app bundle (not `swift run`).
        notifications = Bundle.main.bundleIdentifier != nil
        if notifications { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    public var name: String { setup?.name ?? "This Mac" }

    // MARK: Lifecycle

    /// Start as `setup` says (first launch: after the role picker), or with the simulator in place
    /// of its machine.
    public func launch(_ setup: AppSetup, simulate: Bool = false) async {
        await shutdown()
        setup.save()
        self.setup = setup
        simulating = simulate
        launchError = nil
        settledAfterLaunch = false
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.settledAfterLaunch = true }
        }
        do {
            try FileManager.default.createDirectory(at: setup.dataDir, withIntermediateDirectories: true)
            if setup.role == .hub { try FileManager.default.createDirectory(at: setup.inbox, withIntermediateDirectories: true) }
            let library = try await Library.open(setup.libraryOptions)
            await library.watch()
            var options = setup.instanceOptions
            options.code = build.code
            if simulate { options.machine = .simulator(FakeGrblOptions()) }
            try await attach(Instance(options, library: library))
            startUpdateChecks()
            // Take the machine if it's plugged in here (and keep trying until it is).
            if setup.machine != .none || simulate, await instance?.owner() == Instance.Owner.none {
                try? await instance?.execute(.connect(port: nil), by: setup.name)
            }
        } catch {
            launchError = error.localizedDescription
        }
    }

    /// Switch between the simulator and the machine the setup names, by restarting the instance
    /// (never while a job runs here).
    public func useSimulator(_ on: Bool) {
        guard let setup, !jobRunningHere else { return }
        Task { await launch(setup, simulate: on) }
    }

    /// Run an instance (tests pass their own).
    public func attach(_ instance: Instance) async throws {
        self.instance = instance
        await instance.setUpdater { [weak self] in
            guard let self else { return }
            try await self.beginUpdate()
        }
        let events = await instance.events()
        eventTask = Task { [weak self] in
            for await e in events { self?.handle(e) }
        }
        try await instance.start()
        await refresh()
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        checkTask?.cancel()
        checkTask = nil
        keepAwake.set(false)
        keepAwake.setScreen(false)
        if let instance {
            await instance.stop()
            await instance.library.close()
        }
        instance = nil
        state = nil
    }

    // MARK: Events

    private func handle(_ e: InstanceEvent) {
        switch e {
        case .changed:
            guard !refreshPending else { return }
            refreshPending = true
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                refreshPending = false
                await refresh()
            }
        case .toast(let t):
            toast(t.level, t.text)
        }
    }

    public func refresh() async {
        guard let instance else { return }
        let s = await instance.state()
        if state == nil || jogFeedXY == 0 {
            jogFeedXY = s.config.jogFeedXY
            jogFeedZ = s.config.jogFeedZ
            if !s.config.jogSteps.contains(jogStep) { jogStep = s.config.jogSteps.dropFirst().first ?? 1 }
        }
        noticeChanges(s)
        applyKeepAwake(s)
        let first = state == nil
        state = s
        if first { devOpen(s) }
        let c = await instance.library.conflicts()
        // New conflicts (on reconnect): ask straight away.
        if c.contains(where: { n in !conflicts.contains { $0.id == n.id } }) { conflictsOpen = true }
        conflicts = c
        if conflicts.isEmpty { conflictsOpen = false }
        if managerOpen { await refreshTrash() }
    }

    /// Dev runs only (SG_HOME set), for smoke screenshots: SG_SELECT=<file name> selects a file,
    /// SG_OPEN=probe|resume|surfacing|settings|start opens a dialog.
    private func devOpen(_ s: AppState) {
        guard AppSetup.devHome != nil else { return }
        let env = ProcessInfo.processInfo.environment
        if let name = env["SG_SELECT"] { previewId = s.library.first { $0.name == name }?.id }
        if let d = env["SG_OPEN"] {
            if d == "start", let id = previewId { confirmStart = StartRequest(fileId: id, next: false) } else { dialog = Dialog(rawValue: d) }
        }
    }

    /// Probe Z: its own dialog, or above the start or surfacing dialog when one is open.
    public func openProbe() {
        if confirmStart != nil || dialog == .surfacing { probeOver = true } else { dialog = .probe }
    }

    public func refreshTrash() async {
        trash = await instance?.library.trash() ?? []
    }

    /// macOS notifications when a job finishes or the machine alarms.
    private func noticeChanges(_ s: AppState) {
        defer {
            lastJob = s.job.status
            lastAlarm = s.machine.alarm?.code
        }
        guard state != nil else { return }
        if s.job.status != lastJob {
            switch s.job.status {
            case .done: notify("Job finished", "\(s.job.fileName ?? "The job") is done.")
            case .toolchange: notify("Bit change", "\(s.job.fileName ?? "A file") is done. Fit the next bit and re-probe Z.")
            case .error: notify("Job stopped", s.job.error ?? "The job stopped with an error.")
            default: break
            }
        }
        if let a = s.machine.alarm, a.code != lastAlarm { notify("Alarm \(a.code)", a.message) }
    }

    private func notify(_ title: String, _ body: String) {
        guard notifications else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Commands

    /// Send a command; a refusal shows as a toast. Returns whether it worked.
    @discardableResult
    public func run(_ cmd: Command) async -> Bool {
        guard let instance else { return false }
        do {
            try await instance.execute(cmd, by: name)
            await refresh()
            return true
        } catch {
            toast(.error, error.localizedDescription)
            return false
        }
    }

    public func send(_ cmd: Command) { Task { await run(cmd) } }

    public func jog(_ x: Double, _ y: Double, _ z: Double) {
        guard state?.canJog == true else { return }
        let s = jogStep
        send(.jog(x: x == 0 ? nil : x * s, y: y == 0 ? nil : y * s, z: z == 0 ? nil : z * s, feed: z != 0 ? jogFeedZ : jogFeedXY))
    }

    /// Add files to the library (into `folder`, "" for the top level).
    public func upload(_ urls: [URL], folder: String = "") async {
        guard let instance else { return }
        for url in urls {
            do {
                guard isGcodeName(url.lastPathComponent) else { throw LibraryError("Not a G-code file") }
                let data = try Data(contentsOf: url)
                _ = try await instance.upload(data, AddOptions(name: url.lastPathComponent, source: "Upload", folder: folder))
            } catch {
                toast(.error, "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        await refresh()
    }

    /// A library action that isn't a Command (Trash, history, conflicts): the local library, which syncs.
    public func library(_ action: @Sendable (Library) async throws -> Void) async {
        guard let library = instance?.library else { return }
        do {
            try await action(library)
        } catch {
            toast(.error, error.localizedDescription)
        }
        await refresh()
        await refreshTrash()
    }

    public func revealLibrary() {
        guard let root = instance?.library.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: Toasts

    public func toast(_ level: Toast.Level, _ text: String) {
        let t = ToastItem(level: level, text: text)
        toasts = Array(toasts.suffix(4)) + [t]
        Task {
            try? await Task.sleep(for: .seconds(level == .error ? 9 : 4.5))
            dismiss(t.id)
        }
    }

    public func dismiss(_ id: UUID) { toasts.removeAll { $0.id == id } }

    // MARK: Questions

    public var selected: LibraryItem? { state?.library.first { $0.id == previewId } }

    public func conflict(for fileId: String) -> LibraryConflict? { conflicts.first { $0.entryId == fileId } }

    // MARK: Updates

    /// How the other Mac's code compares with this one's (.ahead: it's behind).
    public var peerCode: CodeComparison { compareCode(build.code, state?.link.peerCode) }

    /// The other Mac's role, while linked.
    public var peerRole: UpdateTarget? {
        guard let s = state, s.link.peerCode != nil || (s.link.hubConnected && s.link.agentConnected) else { return nil }
        return s.link.via == .hub ? .agent : .hub
    }

    private func updater() -> Updater? {
        guard !build.isRelease, let repo = build.repo, let app = build.bundle else { return nil }
        return Updater(repo: repo, built: build.code.commit, installDir: app.deletingLastPathComponent())
    }

    /// Check soon after launch, then every few hours (a release build: Sparkle's own schedule).
    private func startUpdateChecks() {
        if build.isRelease {
            startReleaseUpdater()
            return
        }
        guard checkTask == nil, build.canUpdate else { return }
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.checkForUpdates(manual: false)
                try? await Task.sleep(for: .seconds(4 * 3600))
            }
        }
    }

    private func startReleaseUpdater() {
        guard release == nil else { return }
        let r = ReleaseUpdater()
        r.onStatus = { [weak self] in self?.update = $0 }
        r.onStep = { [weak self] step in
            guard let self else { return }
            Task { await self.instance?.announce(.info, "\(self.name): \(step)…") }
        }
        r.onToast = { [weak self] in self?.toast($0, $1) }
        r.jobRunning = { [weak self] in self?.jobRunningHere ?? false }
        do {
            try r.start()
            release = r
        } catch {
            toast(.warn, "Updates are off: \(error.localizedDescription)")
        }
    }

    public func checkForUpdates(manual: Bool) async {
        if build.isRelease {
            guard let release else {
                if manual { toast(.warn, "Updates are off on this Mac") }
                return
            }
            switch update {
            case .running, .ready: return
            default: release.check(manual: manual)
            }
            return
        }
        guard let u = updater() else {
            if manual { toast(.warn, "This copy can't update itself: it wasn't installed with scripts/build-app.sh") }
            return
        }
        switch update {
        case .running, .ready: return
        default: break
        }
        if manual { update = .checking }
        do {
            let c = try await u.check()
            if let commit = build.code.commit {
                unpublishedCode = await u.isPublished(commit) ? nil : build.code.shortCommit
            }
            update = c.behind > 0 ? .available(c) : .idle
            if manual, c.behind == 0 { toast(.info, "Up to date (\(build.code.shortCommit))") }
        } catch {
            if case .checking = update { update = .idle }
            if manual { toast(.error, "Couldn't check for updates: \(error.localizedDescription)") }
        }
    }

    /// Pull, rebuild and reinstall, then restart (from this Mac's banner, or asked by the other Mac).
    /// Returns once it's under way; throws if it can't start.
    public func beginUpdate() throws {
        if build.isRelease {
            guard let release else { throw UpdateError("Updates are off on \(name)") }
            if case .running = update { throw UpdateError("\(name) is already updating") }
            if jobRunningHere { throw UpdateError("A job is running on \(name). Update it when the job has finished") }
            release.install()
            return
        }
        guard let u = updater() else { throw UpdateError("\(name) can't update itself: it wasn't installed with scripts/build-app.sh") }
        if case .running = update { throw UpdateError("\(name) is already updating") }
        if jobRunningHere { throw UpdateError("A job is running on \(name). Update it when the job has finished") }
        update = .running("Starting")
        Task { await performUpdate(u) }
    }

    private func performUpdate(_ u: Updater) async {
        do {
            let updated = try await u.update { [weak self] step in await self?.updateStep(step) }
            guard updated else {
                update = .idle
                await instance?.announce(.info, "\(name) already has the newest code on GitHub (\(build.code.shortCommit)), so there's nothing to update to. Code that's only committed on the other Mac has to be pushed first")
                return
            }
            update = .ready
            if jobRunningHere {
                await instance?.announce(.info, "\(name) is updated. Restart it when the job has finished")
            } else {
                await instance?.announce(.info, "\(name) is updated. Restarting…")
                restartNow()
            }
        } catch {
            update = .failed(error.localizedDescription)
            await instance?.announce(.error, "\(name) couldn't update: \(error.localizedDescription)")
        }
    }

    private func updateStep(_ step: String) async {
        update = .running(step)
        await instance?.announce(.info, "\(name): \(step)…")
    }

    /// Quit and open the newly built app.
    public func restartNow() {
        guard !jobRunningHere else { return }
        if let release, release.installReady() { return }
        guard let app = build.bundle else { return }
        do { try relaunch(app) } catch { toast(.error, "Couldn't restart: \(error.localizedDescription). Quit and open it again") }
    }

    public func dismissUpdate() {
        release?.dismiss()
        update = .idle
    }

    /// A job is running on this Mac's machine (quitting would stop it).
    public var jobRunningHere: Bool {
        guard let s = state else { return false }
        return s.link.machineOn == name && (s.jobActive || s.job.status == .toolchange)
    }
}
