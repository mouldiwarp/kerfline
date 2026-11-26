// The app: on first launch, the role picker; then the main window, laid out as 1.0 (top bar and
// banners; DRO and jog on the left; job, library and tools on the right; 3D in the centre from
// phase 6), with toasts, the dialogs, the library sheets and the menus.

import AppKit
import SGCore
import SGNet
import SwiftUI

public struct SwarfGRBLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    public init() {
        // Before anything reads the library or settings: carry GCode Controller/KerfLine's across.
        AppSetup.migrateFolders()
        AppSetup.removeOldAppLinks()
        _ = AppSetup.load()
    }

    public var body: some Scene {
        Window("SwarfGRBL", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    DevShow.listen(model)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }

        Settings {
            SetupView(initial: model.setup ?? AppSetup.load() ?? .suggested(), isFirstRun: false)
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a plain process: make it a normal app with a window and a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.jobRunningHere {
            let a = NSAlert()
            a.messageText = "A job is running on this Mac's machine"
            a.informativeText = "Quitting stops the job. Quit anyway?"
            a.alertStyle = .critical
            a.addButton(withTitle: "Keep running")
            a.addButton(withTitle: "Stop and quit")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        // Shut down tidily (close the port, the link and the library), but never let a stuck step
        // stop the app quitting: after a few seconds it quits anyway.
        var replied = false
        let reply = { @MainActor in
            if !replied {
                replied = true
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        Task { @MainActor in
            await model.shutdown()
            reply()
        }
        // Off the main actor, so it fires even if the main actor is stuck; AppKit's wait for the
        // reply runs the run loop in its modal mode, so run it there.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { MainActor.assumeIsolated { reply() } }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var keys = JogKeys()

    var body: some View {
        Group {
            if model.setup == nil, AppSetup.load() == nil {
                SetupView(initial: .suggested(), isFirstRun: true)
            } else if let e = model.launchError {
                LaunchFailed(error: e)
            } else if let s = model.state {
                MainWindow(s: s)
            } else {
                Starting().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.obsidian)
        .task {
            if model.setup == nil, model.instance == nil, let saved = AppSetup.load() { await model.launch(saved) }
        }
        .onAppear { keys.install(model) }
        .onDisappear { keys.remove() }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @AppStorage("swarfgrbl.rightWidth") private var rightWidth = 400.0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar(s: s)
            Banners(s: s)
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        DroPanel(s: s)
                        JogPanel(s: s)
                    }
                }
                .frame(width: 330)
                .frame(maxHeight: .infinity)
                .scrollIndicators(.never)

                VStack(spacing: 12) {
                    Visualizer(s: s).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ProgressPanel(s: s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    JobPanel(s: s)
                    // The library and tools give way when the job panel grows (bit-change steps), so
                    // the column never gets taller than the window and pushes the top bar out of view.
                    LibraryPanel(s: s).frame(minHeight: 110, maxHeight: .infinity).layoutPriority(-1)
                    ToolsPanel(s: s).frame(minHeight: 150, idealHeight: 260, maxHeight: 260).layoutPriority(-1)
                }
                .frame(width: rightWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { ColumnResizer(width: $rightWidth) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Toasts sit below the banners, so they never cover a banner's buttons.
            .overlay(alignment: .topTrailing) { ToastsView().padding(.top, 8).padding(.trailing, 16) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.obsidian)
        .foregroundStyle(Color.offwhite)
        .sheet(isPresented: $model.managerOpen) { LibraryManager(s: s).environment(model) }
        .sheet(isPresented: $model.conflictsOpen) { ConflictsView().environment(model) }
        .sheet(item: $model.confirmStart) { req in StartDialog(req: req).environment(model) }
        .sheet(item: $model.dialog) { d in
            Group {
                switch d {
                case .probe: ProbeDialog()
                case .resume: ResumeDialog()
                case .surfacing: SurfacingDialog()
                case .settings: SettingsView()
                }
            }
            .environment(model)
        }
    }
}

/// Drag the right column's left edge to resize it.
struct ColumnResizer: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 8).offset(x: -10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = width }
                        width = min(640, max(320, (start ?? width) - g.translation.width))
                    }
                    .onEnded { _ in start = nil })
    }
}

struct ToastsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts.reversed()) { t in
                let c: Color = t.level == .error ? .danger : t.level == .warn ? .warn : .info
                HStack(alignment: .top, spacing: 10) {
                    Text(t.text).font(.system(size: 12.5)).foregroundStyle(Color.offwhite).fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.dismiss(t.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.steel)
                }
                .padding(.vertical, 8).padding(.leading, 13).padding(.trailing, 10)
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.slate3))
                .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 3).padding(.vertical, 1) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.lineStrong))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toasts)
    }
}

struct LaunchFailed: View {
    @Environment(AppModel.self) private var model
    let error: String

    var body: some View {
        VStack(spacing: 12) {
            Text("SwarfGRBL couldn’t start").font(.system(size: 17, weight: .semibold))
            Text(error).font(.system(size: 13)).foregroundStyle(Color.steel).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                Button("Try again") { if let s = model.setup { Task { await model.launch(s) } } }.gccButton(.primary)
                SettingsLink { Text("Settings…") }.gccButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: First run and Settings: this Mac's role

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var setup: AppSetup
    let isFirstRun: Bool

    init(initial: AppSetup, isFirstRun: Bool) {
        _setup = State(initialValue: initial)
        self.isFirstRun = isFirstRun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isFirstRun {
                Text("SWARFGRBL").font(.custom("Helvetica", size: 15).weight(.bold)).tracking(4).foregroundStyle(Color.gold)
                Text("How does this Mac fit in?").font(.system(size: 20, weight: .semibold))
            } else {
                Text("THIS MAC").font(.heading).tracking(2)
            }
            HStack(spacing: 12) {
                roleCard(.hub, "Hub", "The design Mac. Keeps the library, takes files from SwarfPath, Fretboard and the inbox folder.")
                roleCard(.agent, "Agent", "The machine Mac in the garage. Keeps a copy of the library and works on its own if the hub is off.")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(Color.steel)
                    TextField("Name", text: $setup.name).gccField().frame(width: 280)
                }
                GridRow {
                    Text("Machine").foregroundStyle(Color.steel)
                    Picker("", selection: $setup.machine) {
                        ForEach(MachineKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 300)
                }
                if setup.role == .agent {
                    GridRow {
                        Text("Hub").foregroundStyle(Color.steel)
                        TextField("Found automatically (or host:port)", text: $setup.hubAddress).gccField().frame(width: 280)
                    }
                }
                GridRow {
                    Text("Trial").foregroundStyle(Color.steel)
                    Toggle("Run alongside 1.0 (own port, folder and data; 1.0 is left alone)", isOn: $setup.trial)
                }
            }
            .font(.system(size: 13))
            Text(where_).font(.system(size: 11.5)).foregroundStyle(Color.steel).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if !isFirstRun { Button("Cancel") { dismiss() }.gccButton() }
                Button(isFirstRun ? "Start" : "Apply and restart") {
                    let s = setup
                    Task { await model.launch(s) }
                    if !isFirstRun { dismiss() }
                }
                .gccButton(.primary).keyboardShortcut(.defaultAction)
                .disabled(setup.name.trimmingCharacters(in: .whitespaces).isEmpty || (!isFirstRun && model.jobRunningHere))
            }
        }
        .padding(28)
        .frame(width: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isFirstRun ? Color.obsidian : Color.slate)
        .foregroundStyle(Color.offwhite)
    }

    private var where_: String {
        "Library folder: \(setup.libraryRoot.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
            + (setup.role == .hub ? " · SwarfPath/Fretboard port \(setup.port)" : "")
            + (setup.role == .hub && setup.trial && setup.v1 != nil ? " · 1.0's library is copied in on first start (1.0 isn't changed)" : "")
    }

    private func roleCard(_ role: Role, _ title: String, _ text: String) -> some View {
        let on = setup.role == role
        return Button {
            setup.role = role
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.heading).tracking(2).foregroundStyle(on ? Color.goldBright : .offwhite)
                Text(text).font(.system(size: 12)).foregroundStyle(Color.steel).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.goldDim : Color.slate))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.gold : Color.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Menus

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await model.checkForUpdates(manual: true) } }
                .disabled({ if case .running = model.update { true } else { false } }())
        }
        CommandGroup(replacing: .newItem) {
            Button("Add to Library…") { model.uploadOpen = true }.keyboardShortcut("o")
                .disabled(model.state == nil)
            Button("Manage Library…") { model.managerOpen = true }.keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.state == nil)
            Button("Show Library in Finder") { model.revealLibrary() }.disabled(model.state == nil)
            Button("Resolve Conflicts…") { model.conflictsOpen = true }.disabled(model.conflicts.isEmpty)
        }
        CommandMenu("Machine") {
            let s = model.state
            let ready = s?.machineReady == true
            Button("Connect") { model.send(.connect(port: nil)) }.disabled(s?.machine.connection != .disconnected)
            Button("Disconnect") { model.send(.disconnect) }.disabled(!ready || s?.jobActive == true)
            Divider()
            Button("Home") { model.send(.home) }.keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(!ready || s?.jobActive == true)
            Button("Unlock") { model.send(.unlock) }.disabled(!ready || s?.machine.status != .alarm)
            Button("Probe Z…") { model.openProbe() }.keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!ready || s?.jobActive == true)
            Button("Surfacing…") { model.dialog = .surfacing }.disabled(s == nil)
            Divider()
            Button("Machine Settings…") { model.dialog = .settings }.keyboardShortcut(",", modifiers: [.command, .shift]).disabled(s == nil)
            Divider()
            Button(s?.machine.status == .hold ? "Resume" : "Feed Hold") { model.send(s?.machine.status == .hold ? .resume : .hold) }
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!ready)
            Button("Stop") { model.send(.stop) }.keyboardShortcut(".", modifiers: .command).disabled(!ready)
            Button("Soft Reset") { model.send(.reset) }.disabled(!ready)
        }
    }
}

/// Shown while the library opens. A newly built copy of the app may have to be allowed into the
/// Documents folder again, and macOS's question can be hidden behind other windows.
struct Starting: View {
    @State private var slow = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView("Starting…")
            if slow {
                Text("Waiting for the library folder in Documents. If macOS asks whether SwarfGRBL can access files in your Documents folder, click Allow (the question may be behind this window).")
                    .font(.system(size: 13)).foregroundStyle(Color.steel)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            slow = true
        }
    }
}

/// Development only (SG_HOME set): open a dialog or sheet from a script, for screenshots:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("swarfgrbl.dev.show"), object: "probe")'
/// Objects: start:<file name>, select:<file name>, probe, resume, surfacing, settings, manager, conflicts, add, none,
/// and check-updates / update (Check for Updates…, Update now).
@MainActor
enum DevShow {
    private static var observer: NSObjectProtocol?

    static func listen(_ model: AppModel) {
        guard AppSetup.devHome != nil, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("swarfgrbl.dev.show"), object: nil, queue: .main) { n in
            let what = n.object as? String ?? ""
            MainActor.assumeIsolated { show(what, model) }
        }
    }

    private static func show(_ what: String, _ model: AppModel) {
        model.dialog = nil
        model.confirmStart = nil
        model.managerOpen = false
        model.conflictsOpen = false
        model.uploadOpen = false
        switch what {
        case "probe": model.dialog = .probe
        case "resume": model.dialog = .resume
        case "surfacing": model.dialog = .surfacing
        case "settings": model.dialog = .settings
        case "manager": model.managerOpen = true
        case "conflicts": model.conflictsOpen = true
        case "add": model.uploadOpen = true
        case "check-updates": Task { await model.checkForUpdates(manual: true) }
        case "simulator": model.useSimulator(true)
        case "machine": model.useSimulator(false)
        case "update":
            do { try model.beginUpdate() } catch { model.toast(.error, error.localizedDescription) }
        default:
            if what.hasPrefix("start:"), let f = model.state?.library.first(where: { $0.name == what.dropFirst(6) }) {
                model.previewId = f.id
                model.confirmStart = StartRequest(fileId: f.id, next: false)
            } else if what.hasPrefix("select:"), let f = model.state?.library.first(where: { $0.name == what.dropFirst(7) }) {
                model.previewId = f.id
            }
        }
    }
}
