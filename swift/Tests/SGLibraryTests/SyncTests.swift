// Library sync between two Macs, wired together in memory (every message goes through JSON, as on
// the wire). "A" is the design Mac, "B" the garage MacBook. The matrix: a fresh Mac pulling
// everything, live changes, offline edits on both sides, same file, same new path, edit vs
// delete, rename vs move, Finder changes, a large library, reconnecting after a restart, a job
// running during sync, and newest-wins macros and config.

import Foundation
import SGCore
import Testing
@testable import SGLibrary

private final class Ref: @unchecked Sendable {
    var sync: LibrarySync?
}

private func wire(_ m: SyncMessage) -> SyncMessage {
    try! JSONDecoder().decode(SyncMessage.self, from: JSONEncoder().encode(m))
}

/// Two Macs' libraries and the link between them.
private final class Pair {
    let boxA = Sandbox(), boxB = Sandbox()
    var a: Library!
    var b: Library!
    var syncA: LibrarySync?
    var syncB: LibrarySync?
    var batchSize = 500

    func open() async throws {
        a = try await boxA.open()
        b = try await boxB.open()
    }

    func connect() async {
        let toA = Ref(), toB = Ref()
        let sa = LibrarySync(library: a, peerName: "Garage", batchSize: batchSize) { m in toB.sync?.receive(wire(m)) }
        let sb = LibrarySync(library: b, peerName: "Design", batchSize: batchSize) { m in toA.sync?.receive(wire(m)) }
        toA.sync = sa
        toB.sync = sb
        (syncA, syncB) = (sa, sb)
        await sa.start()
        await sb.start()
    }

    func disconnect() async {
        await syncA?.stop()
        await syncB?.stop()
        (syncA, syncB) = (nil, nil)
    }

    /// Both have every change and all the content.
    func settled() async -> Bool {
        await until(10000) {
            let (va, vb) = (await a.versionVector(), await b.versionVector())
            let missing = await a.missingBlobs().count + b.missingBlobs().count
            return va == vb && missing == 0
        }
    }

    func names(_ lib: Library) async -> [String] { await lib.items().map { joinPath($0.folder, $0.name) }.sorted() }
}

private func text(_ s: String) -> Data { Data("G21 G90\n\(s)\nM30".utf8) }

@Suite struct SyncTests {
    @Test func aNewMacPullsTheWholeLibrary() async throws {
        let p = Pair()
        try await p.open()
        let one = try await p.a.add(gcode(), AddOptions(name: "one.nc", source: "Swarf", group: "Body", groupIndex: 0))
        try await p.a.add(gcode(4), AddOptions(name: "two.nc", folder: "Necks/Tele"))
        try await p.a.createFolder("Empty")
        try await p.a.saveMacro(Macro(id: "zero", name: "Zero all", gcode: "G10 L20 P1 X0 Y0 Z0"))
        try await p.a.saveConfig(MachineConfigPatch(safeZ: 7))
        let gone = try await p.a.add(gcode(5), AddOptions(name: "old.nc"))
        try await p.a.delete(gone.id)

        await p.connect()
        #expect(await p.settled())
        #expect(await p.names(p.b) == ["Body/one.nc", "Necks/Tele/two.nc"])
        #expect(await p.b.item(one.id)?.group == "Body") // same ids on both Macs
        #expect(p.boxB.read("Body/one.nc") == gcode())
        #expect(p.boxB.read("Necks/Tele/two.nc") == gcode(4))
        #expect(await p.b.folders() == ["Body", "Empty", "Necks", "Necks/Tele"])
        #expect(await p.b.trash().map(\.item.name) == ["old.nc"])
        #expect(await p.b.macros().contains { $0.id == "zero" && $0.gcode.hasPrefix("G10") })
        #expect(await p.b.config().safeZ == 7)
        #expect(await p.b.conflicts().isEmpty)
    }

    @Test func liveChangesFlowBothWays() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(gcode(), AddOptions(name: "part.nc", source: "Swarf"))
        #expect(await until { p.boxB.read("part.nc") == gcode() })
        try await p.b.createFolder("Done")
        try await p.b.moveFile(part.id, to: "Done")
        #expect(await until { p.boxA.exists("Done/part.nc") && !p.boxA.exists("part.nc") })
        try await p.b.renameFile(part.id, "body.nc")
        #expect(await until { await p.a.item(part.id)?.name == "body.nc" })
        try await p.a.add(gcode(7), AddOptions(name: "body.nc", source: "Swarf", folder: "Done")) // a re-export
        #expect(await until { p.boxB.read("Done/body.nc") == gcode(7) })
        #expect(await p.b.versions(part.id).map(\.sha256) == [sha256Hex(gcode())]) // history on the other Mac too
        try await p.a.delete(part.id)
        #expect(await until { await p.b.trash().count == 1 && !p.boxB.exists("Done/body.nc") })
        try await p.b.restore(part.id)
        #expect(await until { p.boxA.read("Done/body.nc") == gcode(7) })
        try await p.a.delete(part.id)
        try await p.a.purge(part.id)
        #expect(await until { let t = await p.b.trash(); let i = await p.b.items(); return t.isEmpty && i.isEmpty })
        #expect(await p.settled())
        #expect(await p.a.conflicts().isEmpty)
        #expect(await p.b.conflicts().isEmpty)
    }

    @Test func offlineEditsToDifferentFieldsBothApply() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(gcode(), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        await p.disconnect()

        try await p.a.renameFile(part.id, "renamed.nc") // the design Mac renames it
        p.boxB.finderWrite("part.nc", gcode(9)) // the garage edits it in Finder
        _ = await p.b.rescan() // (the folder watcher may get there first)
        let other = try await p.b.add(gcode(2), AddOptions(name: "garage-only.nc"))
        let mine = try await p.a.add(gcode(3), AddOptions(name: "design-only.nc"))

        await p.connect()
        #expect(await p.settled())
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await p.names(lib) == ["design-only.nc", "garage-only.nc", "renamed.nc"])
            #expect(box.read("renamed.nc") == gcode(9))
            #expect(await lib.item(other.id) != nil)
            #expect(await lib.item(mine.id) != nil)
            #expect(await lib.conflicts().isEmpty)
        }
    }

    @Test func theSameFileEditedOnBothMacs() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc", source: "Swarf"))
        #expect(await p.settled())
        await p.disconnect()

        try await p.a.add(text("G1 X2"), AddOptions(name: "part.nc", source: "Swarf")) // re-exported here
        try await Task.sleep(for: .milliseconds(5))
        p.boxB.finderWrite("part.nc", text("G1 X333")) // edited in the garage
        _ = await p.b.rescan() // (the folder watcher may get there first)

        await p.connect()
        #expect(await p.settled())
        // Each Mac keeps its own until someone chooses.
        #expect(p.boxA.read("part.nc") == text("G1 X2") && p.boxB.read("part.nc") == text("G1 X333"))
        let ca = try #require(await p.a.conflicts().first)
        #expect(ca.kind == .content && ca.entryId == part.id && ca.peer == "Garage")
        #expect(ca.mine.sha256 == sha256Hex(text("G1 X2")) && ca.theirs.sha256 == sha256Hex(text("G1 X333")))
        #expect(ca.theirs.size == text("G1 X333").count) // the other side's content is here, to preview
        #expect(await p.b.conflicts().first?.kind == .content)

        try await p.a.resolve(ca.id, .keepBoth)
        let day = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"; return f.string(from: Date()) }()
        let copy = "part (Garage, \(day)).nc"
        #expect(await p.settled())
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await lib.conflicts().isEmpty)
            #expect(await p.names(lib) == [copy, "part.nc"])
            #expect(box.read("part.nc") == text("G1 X2"))
            #expect(box.read(copy) == text("G1 X333"))
        }
        // The garage's version, replaced there, is in the file's history too.
        #expect(await p.b.versions(part.id).contains { $0.sha256 == sha256Hex(text("G1 X333")) })
    }

    @Test func keepTheirsFromTheOtherMac() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        await p.disconnect()
        try await p.a.add(text("G1 X2"), AddOptions(name: "part.nc"))
        try await p.b.add(text("G1 X3"), AddOptions(name: "part.nc"))
        await p.connect()
        #expect(await p.settled())
        let cb = try #require(await p.b.conflicts().first)
        try await p.b.resolve(cb.id, .keepTheirs) // the garage takes the design Mac's
        #expect(await p.settled())
        #expect(p.boxA.read("part.nc") == text("G1 X2") && p.boxB.read("part.nc") == text("G1 X2"))
        #expect(await p.a.conflicts().isEmpty)
        #expect(await p.b.conflicts().isEmpty)
        #expect(await p.a.items().count == 1)
        #expect(await p.b.item(part.id)?.sha256 == sha256Hex(text("G1 X2")))
    }

    @Test func aDifferentNewFileAtTheSamePathOnEachMac() async throws {
        let p = Pair()
        try await p.open()
        try await p.a.add(text("G1 X1"), AddOptions(name: "new.nc", source: "Swarf"))
        try await p.b.add(text("G1 X2"), AddOptions(name: "new.nc", source: "Upload"))
        await p.connect()
        #expect(await p.settled())
        #expect(p.boxA.read("new.nc") == text("G1 X1") && p.boxB.read("new.nc") == text("G1 X2"))
        #expect(await p.a.items().count == 1)
        #expect(await p.b.items().count == 1) // the arrival waits
        let cb = try #require(await p.b.conflicts().first)
        #expect(cb.kind == .samePath && cb.theirs.source == "Swarf" && cb.mine.source == "Upload" && cb.peer == "Design")
        #expect(await p.a.conflicts().first?.kind == .samePath)

        try await p.b.resolve(cb.id, .keepBoth)
        #expect(await p.settled())
        let day = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"; return f.string(from: Date()) }()
        let copy = "new (Design, \(day)).nc"
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await lib.conflicts().isEmpty)
            #expect(await p.names(lib) == ["new (Design, \(day)).nc", "new.nc"])
            #expect(box.read("new.nc") == text("G1 X2"))
            #expect(box.read(copy) == text("G1 X1"))
        }
    }

    @Test func samePathKeepMineTrashesTheOther() async throws {
        let p = Pair()
        try await p.open()
        try await p.a.add(text("G1 X1"), AddOptions(name: "new.nc"))
        try await p.b.add(text("G1 X2"), AddOptions(name: "new.nc"))
        await p.connect()
        #expect(await p.settled())
        let ca = try #require(await p.a.conflicts().first)
        try await p.a.resolve(ca.id, .keepMine)
        #expect(await p.settled())
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await lib.conflicts().isEmpty)
            #expect(await p.names(lib) == ["new.nc"])
            #expect(box.read("new.nc") == text("G1 X1"))
            #expect(await lib.trash().count == 1)
        }
    }

    @Test func theSameNewFileOnBothMacsIsNotAConflict() async throws {
        let p = Pair()
        try await p.open()
        try await p.a.add(gcode(), AddOptions(name: "same.nc"))
        p.boxB.finderWrite("same.nc", gcode())
        _ = await p.b.rescan() // (the folder watcher may get there first)
        await p.connect()
        #expect(await p.settled())
        #expect(await p.a.conflicts().isEmpty)
        #expect(await p.b.conflicts().isEmpty)
        let (ia, ib) = (await p.a.items(), await p.b.items())
        #expect(ia.count == 1 && ib.count == 1 && ia[0].id == ib[0].id)
        #expect(p.boxA.read("same.nc") == gcode() && p.boxB.read("same.nc") == gcode())
    }

    /// The reconnect race behind an intermittent failure: the delete reaches the editing Mac first,
    /// which acknowledges it before sending its edit. The edit is still older than the delete.
    @Test func anEditThatArrivesAfterTheAckOfADeleteStillConflicts() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        await p.disconnect()
        p.boxA.finderWrite("part.nc", text("G1 X22"))
        _ = await p.a.rescan()
        try await Task.sleep(for: .milliseconds(5)) // the delete is stamped after the edit
        try await p.b.delete(part.id)

        let edit = await p.a.syncChanges(after: await p.b.versionVector())
        let delete = await p.b.syncChanges(after: await p.a.versionVector())
        #expect(edit.map(\.field) == ["content"] && delete.map(\.field) == ["deleted"])
        try await p.a.applySync(delete, peer: SyncPeer(name: "Garage", seenMine: nil))
        // A has now acknowledged the delete, and only then does its edit reach B.
        try await p.b.applySync(edit, peer: SyncPeer(name: "Design", seenMine: delete[0].stamp))
        #expect(await p.a.conflicts().map(\.kind) == [.editDelete])
        #expect(await p.b.conflicts().map(\.kind) == [.deleteEdit])
    }

    @Test func editedHereDeletedThere() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        await p.disconnect()
        p.boxA.finderWrite("part.nc", text("G1 X22")) // edited on the design Mac
        _ = await p.a.rescan() // (the folder watcher may get there first)
        try await p.b.delete(part.id) // deleted in the garage

        await p.connect()
        #expect(await p.settled())
        #expect(p.boxA.read("part.nc") == text("G1 X22")) // nothing is lost while it's open
        #expect(await p.b.item(part.id) == nil)
        let ca = try #require(await p.a.conflicts().first)
        #expect(ca.kind == .editDelete && !ca.mine.deleted && ca.theirs.deleted)
        let cb = try #require(await p.b.conflicts().first)
        #expect(cb.kind == .deleteEdit && cb.mine.deleted && !cb.theirs.deleted)

        try await p.a.resolve(ca.id, .keepMine) // keep the edit
        #expect(await p.settled())
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await lib.conflicts().isEmpty)
            #expect(box.read("part.nc") == text("G1 X22"))
            #expect(await lib.trash().isEmpty)
        }
    }

    @Test func deletedHereEditedThereKeepTheirsRestores() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        await p.disconnect()
        try await p.a.delete(part.id)
        try await p.b.add(text("G1 X5"), AddOptions(name: "part.nc"))
        await p.connect()
        #expect(await p.settled())
        let ca = try #require(await p.a.conflicts().first)
        #expect(ca.kind == .deleteEdit)
        try await p.a.resolve(ca.id, .keepTheirs)
        #expect(await p.settled())
        for box in [p.boxA, p.boxB] { #expect(box.read("part.nc") == text("G1 X5")) }
        #expect(await p.a.conflicts().isEmpty)
        #expect(await p.b.conflicts().isEmpty)
    }

    @Test func renamedHereMovedThere() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(gcode(), AddOptions(name: "part.nc"))
        try await p.a.createFolder("Done")
        #expect(await p.settled())
        await p.disconnect()
        try await p.a.renameFile(part.id, "body.nc")
        try await p.b.moveFile(part.id, to: "Done")

        await p.connect()
        #expect(await p.settled())
        #expect(p.boxA.exists("body.nc") && p.boxB.exists("Done/part.nc"))
        let ca = try #require(await p.a.conflicts().first)
        #expect(ca.kind == .path && ca.mine.name == "body.nc" && ca.theirs.folder == "Done" && ca.theirs.name == "part.nc")
        try await p.a.resolve(ca.id, .keepTheirs)
        #expect(await p.settled())
        for (lib, box) in [(p.a!, p.boxA), (p.b!, p.boxB)] {
            #expect(await p.names(lib) == ["Done/part.nc"])
            #expect(box.exists("Done/part.nc") && !box.exists("body.nc"))
            #expect(await lib.conflicts().isEmpty)
        }
    }

    @Test func finderChangesOnEitherMacSync() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        p.boxA.mkdir("Jigs")
        p.boxA.finderWrite("Jigs/drill.nc", gcode(4))
        _ = await p.a.rescan() // (the folder watcher may get there first)
        #expect(await until { p.boxB.read("Jigs/drill.nc") == gcode(4) })
        p.boxB.move("Jigs/drill.nc", "drill.nc")
        _ = await p.b.rescan() // (the folder watcher may get there first)
        #expect(await until { p.boxA.exists("drill.nc") && !p.boxA.exists("Jigs/drill.nc") })
        p.boxB.remove("drill.nc")
        _ = await p.b.rescan() // (the folder watcher may get there first)
        #expect(await until { await p.a.trash().count == 1 && !p.boxA.exists("drill.nc") })
        #expect(await p.settled())
    }

    @Test func aLargeLibrary() async throws {
        let p = Pair()
        p.batchSize = 64
        try await p.open()
        for i in 0..<300 {
            try await p.a.add(text("G1 X\(i)"), AddOptions(name: "f\(i).nc", folder: "Batch \(i % 7)"))
        }
        let start = Date()
        await p.connect()
        #expect(await p.settled())
        #expect(await p.b.items().count == 300)
        #expect(p.boxB.read("Batch 3/f10.nc") == text("G1 X10"))
        #expect(Date().timeIntervalSince(start) < 20)
    }

    @Test func reconnectingAfterARestart() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        try await p.a.add(gcode(), AddOptions(name: "one.nc"))
        #expect(await p.settled())
        await p.disconnect()
        let before = await p.b.versionVector()
        await p.a.close()
        await p.b.close()
        try await p.open() // both apps restarted
        #expect(await p.b.versionVector() == before)
        try await p.a.add(gcode(2), AddOptions(name: "two.nc"))
        try await p.b.add(gcode(3), AddOptions(name: "three.nc"))
        await p.connect()
        #expect(await p.settled())
        #expect(await p.names(p.a) == ["one.nc", "three.nc", "two.nc"])
        #expect(await p.names(p.b) == ["one.nc", "three.nc", "two.nc"])
        // Only what was missing went across: one.nc's create isn't in either log twice.
        #expect(await p.a.changes().filter { $0.field == "create" }.count == 3)
    }

    @Test func aRunningJobKeepsItsContentWhileSyncChangesTheFile() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        let part = try await p.a.add(text("G1 X1"), AddOptions(name: "part.nc"))
        #expect(await p.settled())
        let running = sha256Hex(text("G1 X1"))
        await p.b.pin(running) // the garage runs it
        try await p.a.add(text("G1 X2"), AddOptions(name: "part.nc")) // re-exported meanwhile
        try await p.a.delete(part.id)
        try await p.a.purge(part.id)
        #expect(await p.settled())
        try await p.b.maintenance()
        #expect(await p.b.content(sha: running) == text("G1 X1"))
        await p.b.unpin(running)
        try await p.b.maintenance()
        #expect(await p.b.content(sha: running) == nil)
    }

    @Test func macrosAndConfigNewestWins() async throws {
        let p = Pair()
        try await p.open()
        await p.connect()
        #expect(await p.settled())
        await p.disconnect()
        try await p.a.saveMacro(Macro(id: "lift-z", name: "Lift", gcode: "G91 G0 Z5\nG90"))
        try await p.a.saveConfig(MachineConfigPatch(safeZ: 4))
        try await Task.sleep(for: .milliseconds(5))
        try await p.b.saveMacro(Macro(id: "lift-z", name: "Lift more", gcode: "G91 G0 Z20\nG90"))
        try await p.b.deleteMacro("modal")
        try await p.b.saveConfig(MachineConfigPatch(safeZ: 9))
        await p.connect()
        #expect(await p.settled())
        for lib in [p.a!, p.b!] {
            #expect(await lib.macros().first { $0.id == "lift-z" }?.name == "Lift more")
            #expect(await !lib.macros().contains { $0.id == "modal" })
            #expect(await lib.config().safeZ == 9)
        }
    }
}
