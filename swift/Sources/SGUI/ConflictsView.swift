// Conflicts between the Macs, asked about when they reconnect: both sides side by side, and Keep this
// Mac's / Keep the other Mac's / Keep both. The losing side goes into the file's history.

import SGCore
import SGLibrary
import SwiftUI

struct ConflictsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LIBRARY CONFLICTS").font(.heading).tracking(2).foregroundStyle(Color.offwhite)
            Text("These files were changed on both Macs while they were apart. Choose which to keep; the other goes into the file's history, so nothing is lost.")
                .font(.system(size: 12.5)).foregroundStyle(Color.steel).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.conflicts) { c in ConflictCard(c: c) }
                }
            }
            HStack {
                Spacer()
                Button(model.conflicts.isEmpty ? "Done" : "Decide later") { dismiss() }.gccButton()
            }
        }
        .padding(18)
        .frame(width: 720, height: 520)
        .background(Color.slate)
    }
}

private struct ConflictCard: View {
    @Environment(AppModel.self) private var model
    let c: LibraryConflict
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(c.mine.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.offwhite)
                Badge(text: c.kind.summary.uppercased(), color: .warn)
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                side(model.name + " (this Mac)", c.mine)
                side(c.peer, c.theirs)
            }
            HStack(spacing: 8) {
                Button("Keep this Mac's") { resolve(.keepMine) }.gccButton(.normal)
                Button("Keep \(c.peer)'s") { resolve(.keepTheirs) }.gccButton(.normal)
                    .disabled(!c.theirs.deleted && c.theirs.size == nil)
                    .help(!c.theirs.deleted && c.theirs.size == nil ? "Still fetching it from \(c.peer)" : "")
                Button("Keep both") { resolve(.keepBoth) }.gccButton(.primary)
                    .disabled(c.mine.deleted || c.theirs.deleted || c.theirs.size == nil)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.slate2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
    }

    private func side(_ who: String, _ x: ConflictSide) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(who)
            if x.deleted {
                Text("Deleted").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.danger)
            } else {
                Text((x.folder.isEmpty ? "" : x.folder + "/") + x.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.offwhite)
                HStack(spacing: 6) {
                    Badge(text: x.source)
                    if let n = x.size { Text(bytes(n)) } else { Text("fetching…") }
                    if let e = x.estSeconds { Text("~\(formatDuration(e))") }
                }
                .font(.system(size: 11.5)).foregroundStyle(Color.steel)
            }
            Text("changed \(ago(x.changedAt))").font(.system(size: 11.5)).foregroundStyle(Color.steel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.obsidian))
    }

    private func resolve(_ choice: ConflictChoice) {
        busy = true
        let id = c.id
        Task {
            await model.library { try await $0.resolve(id, choice) }
            busy = false
        }
    }
}
