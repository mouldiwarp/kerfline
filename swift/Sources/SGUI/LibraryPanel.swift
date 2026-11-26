// The library: folders (with counts), groups in run order, file rows (source, ~time, size, age, ▶,
// Trash), conflict badges and drag-and-drop upload, as 1.0's Library.tsx.

import SGCore
import SGLibrary
import SGNet
import SwiftUI
import UniformTypeIdentifiers


let gcodeTypes: [UTType] = ["nc", "gcode", "ngc", "tap", "cnc", "gc"].compactMap { UTType(filenameExtension: $0) } + [.plainText]

struct LibraryPanel: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    @State private var dropTarget: String?

    var body: some View {
        @Bindable var model = model
        Panel("Library") {
            HStack(spacing: 4) {
                Button("Add…") { model.uploadOpen = true }.gccButton(.ghost, .small).help("Add G-code files to the library")
                Button("Manage") { model.managerOpen = true }.gccButton(.ghost, .small).help("Folders, Trash and version history")
                Button("Surfacing…") { model.dialog = .surfacing }.gccButton(.ghost, .small).help("Make a program to flatten the stock")
                Button {
                    model.revealLibrary()
                } label: {
                    Image(systemName: "folder")
                }
                .gccButton(.ghost, .small).help("Show the library folder in Finder")
            }
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if s.library.isEmpty, s.folders.allSatisfy(\.isEmpty) {
                        Text("No files yet. Drop G-code here, send it from SwarfPath, or put it in the library folder.")
                            .font(.system(size: 12)).foregroundStyle(Color.steel).padding(8)
                    }
                    FolderContents(s: s, folder: "", depth: 0, dropTarget: $dropTarget)
                }
            }
            .frame(minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(dropTarget == "" ? Color.goldDim : .clear))
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.upload(urls) }
                return true
            } isTargeted: { dropTarget = $0 ? "" : (dropTarget == "" ? nil : dropTarget) }
        }
        .fileImporter(isPresented: $model.uploadOpen, allowedContentTypes: gcodeTypes, allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task {
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                await model.upload(urls)
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

/// One level of the tree: subfolders (collapsible) then files.
struct FolderContents: View {
    let s: AppState
    let folder: String
    let depth: Int
    @Binding var dropTarget: String?

    var body: some View {
        ForEach(childFolders(s.folders, folder), id: \.self) { f in
            FolderRow(s: s, folder: f, depth: depth, dropTarget: $dropTarget)
        }
        let files = filesIn(s.library, folder)
        ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
            if let g = f.group, i == 0 || files[i - 1].group != g {
                Text("GROUP · \(g)").font(.heading).tracking(1.4).foregroundStyle(Color.gold)
                    .padding(.leading, CGFloat(depth) * 14 + 8).padding(.top, 6)
            }
            FileRow(s: s, f: f, depth: depth)
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    let folder: String
    let depth: Int
    @Binding var dropTarget: String?
    @AppStorage private var open: Bool

    init(s: AppState, folder: String, depth: Int, dropTarget: Binding<String?>) {
        self.s = s
        self.folder = folder
        self.depth = depth
        _dropTarget = dropTarget
        _open = AppStorage(wrappedValue: depth == 0, "swarfgrbl.folderOpen.\(folder)")
    }

    var body: some View {
        let n = countIn(s.library, folder)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
                    Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(Color.gold)
                    Text(baseName(folder)).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.offwhite)
                    Text("\(n)").font(.system(size: 11)).foregroundStyle(Color.steel)
                    Spacer()
                }
                .padding(.vertical, 4).padding(.leading, CGFloat(depth) * 14 + 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 5).fill(dropTarget == folder ? Color.goldDim : .clear))
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.upload(urls, folder: folder) }
                return true
            } isTargeted: { dropTarget = $0 ? folder : (dropTarget == folder ? nil : dropTarget) }
            .help(dropTarget == folder ? "Upload into \(folder)" : folder)
            if open {
                FolderContents(s: s, folder: folder, depth: depth + 1, dropTarget: $dropTarget)
                if n == 0 {
                    Text("Empty").font(.system(size: 11)).foregroundStyle(Color.steel).padding(.leading, CGFloat(depth + 1) * 14 + 8)
                }
            }
        }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let s: AppState
    let f: LibraryItem
    let depth: Int
    @State private var confirmTrash = false
    @State private var hover = false

    var body: some View {
        let selected = model.previewId == f.id
        let running = s.job.fileId == f.id && s.jobActive
        let waitingForBit = s.job.status == .toolchange
        let conflict = model.conflict(for: f.id)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(f.name).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.goldBright : .offwhite).lineLimit(1).truncationMode(.middle)
                        .help(f.name)
                    if conflict != nil {
                        Button {
                            model.conflictsOpen = true
                        } label: {
                            Badge(text: "CONFLICT", color: .warn)
                        }
                        .buttonStyle(.plain).help(conflict!.kind.summary)
                    }
                    if running { Badge(text: "RUNNING", color: .gold) }
                }
                HStack(spacing: 6) {
                    if !f.source.isEmpty { Badge(text: f.source) }
                    if f.estSeconds > 0 { Text("~\(formatDuration(f.estSeconds))") }
                    Text(dims(f))
                    Text(ago(f.addedAt))
                }
                .font(.system(size: 11)).foregroundStyle(Color.steel)
            }
            Spacer(minLength: 4)
            if confirmTrash {
                Button("Trash") {
                    confirmTrash = false
                    if model.previewId == f.id { model.previewId = nil }
                    model.send(.deleteFile(fileId: f.id))
                }
                .gccButton(.danger, .small).help("Move this file to the Trash")
                Button("Keep") { confirmTrash = false }.gccButton(.normal, .small)
            } else {
                Button("▶") {
                    model.previewId = f.id
                    model.confirmStart = StartRequest(fileId: f.id, next: false)
                }
                .gccButton(.outlineGold, .small)
                .disabled(s.startHint(selected: f) != nil || waitingForBit)
                .help(waitingForBit ? "A group is waiting for a bit change: use Start next or End group" : s.startHint(selected: f) ?? "Start this file")
                Button("✕") { confirmTrash = true }.gccButton(.ghost, .small).disabled(running).help("Delete")
                    .opacity(hover || selected ? 1 : 0.4)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8).padding(.leading, CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.goldDim : hover ? Color.slate2 : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.previewId = selected ? nil : f.id }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Start…") { model.confirmStart = StartRequest(fileId: f.id, next: false) }.disabled(s.startHint(selected: f) != nil)
            Button("Rename / Move…") {
                model.previewId = f.id
                model.managerOpen = true
            }
            Button("History…") {
                model.previewId = f.id
                model.managerOpen = true
            }
            Divider()
            Button("Move to Trash") { model.send(.deleteFile(fileId: f.id)) }.disabled(running)
        }
    }
}
