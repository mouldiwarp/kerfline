// Manage the library: folders (new, rename, delete), a file's name, folder and earlier versions,
// and the Trash (restore, delete for good, empty). Changes sync to the other Mac.

import SGCore
import SGLibrary
import SGNet
import SwiftUI

struct LibraryManager: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let s: AppState
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MANAGE LIBRARY").font(.heading).tracking(2).foregroundStyle(Color.offwhite)
                Spacer()
                Picker("", selection: $tab) {
                    Text("Folders & files").tag(0)
                    Text("Trash (\(model.trash.count))").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 260)
            }
            if tab == 0 { FilesTab(s: s) } else { TrashTab() }
            HStack {
                Text("Changes sync to the other Mac. Deleted files stay in the Trash for 30 days.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.steel)
                Spacer()
                Button("Done") { dismiss() }.gccButton(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 780, height: 560)
        .background(Color.slate)
    }
}

private struct FilesTab: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var folder = ""
    @State private var newFolder = ""
    @State private var renameFolderTo = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Folders
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("Folders")
                List(selection: Binding(get: { folder }, set: { folder = $0 ?? "" })) {
                    Text("Library (top level)").tag("")
                    ForEach(s.folders.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { f in
                        HStack {
                            Text(String(repeating: "   ", count: f.split(separator: "/").count - 1) + baseName(f))
                            Spacer()
                            Text("\(countIn(s.library, f))").foregroundStyle(Color.steel)
                        }
                        .tag(f)
                    }
                }
                .scrollContentBackground(.hidden).background(Color.obsidian).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    TextField(folder.isEmpty ? "New folder" : "New folder in \(baseName(folder))", text: $newFolder).gccField()
                    Button("Add") {
                        let path = folder.isEmpty ? newFolder : "\(folder)/\(newFolder)"
                        model.send(.createFolder(path: path))
                        newFolder = ""
                    }
                    .gccButton(.normal, .small).disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !folder.isEmpty {
                    HStack(spacing: 6) {
                        TextField("Rename \(baseName(folder))", text: $renameFolderTo).gccField()
                        Button("Rename") {
                            let to = parentOf(folder).isEmpty ? renameFolderTo : "\(parentOf(folder))/\(renameFolderTo)"
                            model.send(.renameFolder(path: folder, to: to))
                            folder = to
                            renameFolderTo = ""
                        }
                        .gccButton(.normal, .small).disabled(renameFolderTo.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Delete folder (files go to the Trash)") {
                        model.send(.deleteFolder(path: folder))
                        folder = parentOf(folder)
                    }
                    .gccButton(.danger, .small)
                }
            }
            .frame(width: 280)

            // Files in the folder, and the selected file
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(folder.isEmpty ? "Files at the top level" : "Files in \(folder)")
                let files = filesIn(s.library, folder)
                List(selection: Binding(get: { model.previewId }, set: { model.previewId = $0 })) {
                    ForEach(files) { f in
                        HStack {
                            Text(f.name)
                            if model.conflict(for: f.id) != nil { Badge(text: "CONFLICT", color: .warn) }
                            Spacer()
                            Text(bytes(f.size)).foregroundStyle(Color.steel)
                        }
                        .tag(Optional(f.id))
                    }
                }
                .scrollContentBackground(.hidden).background(Color.obsidian).clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: 170)
                if let f = model.selected {
                    FileDetail(s: s, f: f).id(f.id)
                } else {
                    Text("Select a file to rename it, move it or restore an earlier version.")
                        .font(.system(size: 12)).foregroundStyle(Color.steel)
                }
                Spacer()
            }
        }
        .onAppear { if let f = model.selected { folder = f.folder } }
    }
}

private struct FileDetail: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    let f: LibraryItem
    @State private var name = ""
    @State private var moveTo = ""
    @State private var versions: [FileVersion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Name", text: $name).gccField()
                Button("Rename") { model.send(.renameFile(fileId: f.id, name: name)) }
                    .gccButton(.normal, .small).disabled(name.isEmpty || name == f.name)
            }
            HStack(spacing: 6) {
                Picker("Folder", selection: $moveTo) {
                    Text("Library (top level)").tag("")
                    ForEach(s.folders.filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Button("Move") { model.send(.moveFile(fileId: f.id, folder: moveTo)) }
                    .gccButton(.normal, .small).disabled(moveTo == f.folder)
            }
            Eyebrow("Earlier versions").padding(.top, 4)
            if versions.isEmpty {
                Text("None yet. When the file's content is replaced, the earlier one is kept here (the last 5, for 30 days).")
                    .font(.system(size: 12)).foregroundStyle(Color.steel)
            }
            ForEach(versions, id: \.sha256) { v in
                HStack {
                    Text("Replaced \(ago(v.replacedAt))")
                    Badge(text: v.source)
                    Text(bytes(v.size)).foregroundStyle(Color.steel)
                    Spacer()
                    Button("Restore") {
                        let id = f.id
                        let sha = v.sha256
                        Task {
                            await model.library { try await $0.restoreVersion(id, sha: sha) }
                            await load()
                        }
                    }
                    .gccButton(.outlineGold, .small)
                    .disabled(s.job.fileId == f.id && s.job.status.isActive)
                    .help("Make this the current content (the current one is kept as a version)")
                }
                .font(.system(size: 12))
            }
        }
        .task {
            name = f.name
            moveTo = f.folder
            await load()
        }
    }

    private func load() async {
        versions = await model.instance?.library.versions(f.id) ?? []
    }
}

private struct TrashTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.trash.isEmpty {
                Text("The Trash is empty.").font(.system(size: 12.5)).foregroundStyle(Color.steel).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.trash, id: \.item.id) { t in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.item.name)
                                Text("\(t.item.folder.isEmpty ? "Top level" : t.item.folder) · deleted \(ago(t.deletedAt))")
                                    .font(.system(size: 11)).foregroundStyle(Color.steel)
                            }
                            Spacer()
                            Button("Restore") {
                                let id = t.item.id
                                Task { await model.library { try await $0.restore(id) } }
                            }
                            .gccButton(.outlineGold, .small)
                            Button("Delete") {
                                let id = t.item.id
                                Task { await model.library { try await $0.purge(id) } }
                            }
                            .gccButton(.danger, .small).help("Delete for good, on both Macs")
                        }
                    }
                }
                .scrollContentBackground(.hidden).background(Color.obsidian).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    if confirmEmpty {
                        Text("Delete \(model.trash.count) files for good, on both Macs?").font(.system(size: 12))
                        Button("Empty Trash") {
                            confirmEmpty = false
                            Task { await model.library { try await $0.emptyTrash() } }
                        }
                        .gccButton(.danger, .small)
                        Button("Cancel") { confirmEmpty = false }.gccButton(.normal, .small)
                    } else {
                        Button("Empty Trash…") { confirmEmpty = true }.gccButton(.danger, .small)
                    }
                }
            }
        }
    }
}
