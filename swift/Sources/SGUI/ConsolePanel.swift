// The tools panel: the console (what was sent and received, MDI with history) and macros (run, add,
// edit, delete), as 1.0's Console.tsx.

import SGCore
import SGNet
import SwiftUI

struct ToolsPanel: View {
    let s: AppState
    @AppStorage("swarfgrbl.toolsTab") private var tab = 0

    var body: some View {
        Panel("") {
            Picker("", selection: $tab) {
                Text("Console").tag(0)
                Text("Macros").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if tab == 0 { ConsoleView(s: s) } else { MacrosView(s: s) }
        }
    }
}

struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var line = ""
    @State private var history: [String] = []
    @State private var historyIndex = -1
    @State private var showStatus = false

    var body: some View {
        let canSend = s.machineReady && !s.jobActive
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(s.console.enumerated()), id: \.offset) { i, l in
                            Text(prefix(l) + l.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(l))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(6)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
                .onChange(of: s.console.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                .onAppear { proxy.scrollTo(s.console.count - 1, anchor: .bottom) }
            }
            .frame(minHeight: 120)
            HStack(spacing: 6) {
                TextField(canSend ? "G-code or $ command…" : "Unavailable while busy", text: $line)
                    .font(.mono).gccField()
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { step(1) }
                    .onKeyPress(.downArrow) { step(-1) }
                    .disabled(!canSend)
                Button("Send", action: send).gccButton(.normal).disabled(!canSend || line.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func send() {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        history = Array(([l] + history.filter { $0 != l }).prefix(50))
        historyIndex = -1
        line = ""
        model.send(.mdi(line: l))
    }

    private func step(_ d: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        historyIndex = max(-1, min(history.count - 1, historyIndex + d))
        line = historyIndex < 0 ? "" : history[historyIndex]
        return .handled
    }

    private func prefix(_ l: ConsoleLine) -> String {
        let who = l.by.map { "[\($0)] " } ?? ""
        switch l.dir {
        case .out: return "› " + who
        case .in: return "  "
        case .info: return "· "
        case .error: return "! "
        }
    }

    private func color(_ l: ConsoleLine) -> Color {
        switch l.dir {
        case .out: .goldBright
        case .in: .offwhite
        case .info: .steel
        case .error: .danger
        }
    }
}

struct MacrosView: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var editing: Macro?

    var body: some View {
        let canRun = s.machineReady && !s.jobActive && s.machine.status == .idle
        VStack(alignment: .leading, spacing: 6) {
            if s.macros.isEmpty {
                Text("No macros yet.").font(.system(size: 12)).foregroundStyle(Color.steel)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(s.macros) { m in
                        HStack(spacing: 6) {
                            Button(m.name) { model.send(.runMacro(id: m.id)) }.gccButton().wide().disabled(!canRun).help(m.gcode)
                            Button {
                                editing = m
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .gccButton(.ghost, .small).help("Edit")
                        }
                    }
                }
            }
            Button("+ New macro") { editing = Macro(id: randomId(), name: "", gcode: "") }.gccButton(.ghost, .small)
        }
        .sheet(item: $editing) { m in MacroEditor(macro: m, isNew: !s.macros.contains { $0.id == m.id }) }
    }
}

struct MacroEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var macro: Macro
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "NEW MACRO" : "EDIT MACRO").font(.heading).tracking(2).foregroundStyle(Color.offwhite)
            Eyebrow("Name")
            TextField("Name", text: $macro.name).gccField()
            Eyebrow("G-code (one command per line)")
            TextEditor(text: $macro.gcode).font(.mono).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.obsidian))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.lineStrong))
                .frame(minHeight: 140)
            HStack {
                if !isNew {
                    Button("Delete") {
                        model.send(.deleteMacro(id: macro.id))
                        dismiss()
                    }
                    .gccButton(.danger)
                }
                Spacer()
                Button("Cancel") { dismiss() }.gccButton().keyboardShortcut(.cancelAction)
                Button("Save") {
                    let m = macro
                    Task {
                        if await model.run(.saveMacro(macro: m)) { dismiss() }
                    }
                }
                .gccButton(.primary).keyboardShortcut(.defaultAction)
                .disabled(macro.name.trimmingCharacters(in: .whitespaces).isEmpty || macro.gcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18).frame(width: 460).background(Color.slate)
    }
}
