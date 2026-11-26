// The library on disk, in temporary folders. Ported from packages/hub/test/library.test.ts, plus
// history, Trash, persistence, the change log and the 1.0 import.

import Foundation
import SGCore
import Testing
@testable import SGLibrary

func gcode(_ n: Int = 3) -> Data {
    Data((["G21 G90", "G0 Z5"] + (0..<n).map { "G1 X\($0) Y\($0) F1000" } + ["M30"]).joined(separator: "\n").utf8)
}

final class Sandbox {
    let dir: URL
    var data: URL { dir.appending(path: "data") }
    var root: URL { dir.appending(path: "SwarfGRBL") }

    /// One folder per test run; the previous run's is removed. (Not removed on deinit: Swift may
    /// release a sandbox while its library is still using the folder.)
    static let base: URL = {
        let base = FileManager.default.temporaryDirectory.appending(path: "sg-lib-tests")
        try? FileManager.default.removeItem(at: base)
        return base.appending(path: UUID().uuidString)
    }()

    init() {
        dir = Sandbox.base.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func open(importV1: V1Paths? = nil) async throws -> Library {
        try await Library.open(LibraryOptions(dataDir: data, root: root, settleMs: 0, importV1: importV1))
    }

    func path(_ rel: String) -> URL { root.appending(path: rel) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel).path) }
    func read(_ rel: String) -> Data? { try? Data(contentsOf: path(rel)) }

    /// Write a file as Finder would.
    func finderWrite(_ rel: String, _ content: Data) {
        try! FileManager.default.createDirectory(at: path(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: path(rel))
    }

    func mkdir(_ rel: String) { try! FileManager.default.createDirectory(at: path(rel), withIntermediateDirectories: true) }
    func move(_ a: String, _ b: String) { try! FileManager.default.moveItem(at: path(a), to: path(b)) }
    func remove(_ rel: String) { try! FileManager.default.removeItem(at: path(rel)) }
}

// Generous: it returns as soon as the condition holds, and a busy CI runner can take seconds to deliver FSEvents.
func until(_ ms: Int = 20000, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await cond()
}

@Suite struct LibraryTests {
    @Test func filesGroupsInFoldersAndSingleFilesAtTheTop() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        let a = try await lib.add(gcode(), AddOptions(name: "body_1_rough.nc", source: "Swarf", group: "Strat body", groupIndex: 0))
        let b = try await lib.add(gcode(4), AddOptions(name: "body_2_finish.nc", source: "Swarf", group: "Strat body", groupIndex: 1))
        let c = try await lib.add(gcode(5), AddOptions(name: "dots", source: "Fretboard"))
        #expect(a.folder == "Strat body" && b.folder == "Strat body")
        #expect(box.read("Strat body/body_1_rough.nc") == gcode())
        #expect(c.folder == "" && c.name == "dots.nc") // an extension is added
        #expect(a.streamLines == 6 && a.size == gcode().count && a.group == "Strat body" && a.groupIndex == 0)
        #expect(await lib.folders() == ["Strat body"])
        let d = try await lib.add(gcode(6), AddOptions(name: "neck.nc", folder: "Guitars/Tele"))
        #expect(d.folder == "Guitars/Tele")
        #expect(await lib.folders() == ["Guitars", "Guitars/Tele", "Strat body"])
        #expect(await lib.items().map(\.name) == ["dots.nc", "neck.nc", "body_2_finish.nc", "body_1_rough.nc"])
    }

    @Test func refusesWhatIsNotGcode() async throws {
        let lib = try await Sandbox().open()
        await #expect(throws: LibraryError("The file is empty")) { try await lib.add(Data(), AddOptions(name: "a.nc")) }
        await #expect(throws: LibraryError("The file has no G-code in it")) {
            try await lib.add(Data("(just a comment)\n; and a note\n%".utf8), AddOptions(name: "a.nc"))
        }
        await #expect(throws: LibraryError("That doesn't look like a G-code text file")) {
            try await lib.add(Data([0x47, 0, 1]), AddOptions(name: "a.nc"))
        }
    }

    @Test func reExportReplacesInPlaceAndKeepsHistory() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        let first = try await lib.add(gcode(3), AddOptions(name: "part.nc", folder: "Jobs"))
        let same = try await lib.add(gcode(3), AddOptions(name: "part.nc", folder: "Jobs"))
        #expect(same.id == first.id)
        #expect(await lib.versions(first.id).isEmpty) // same content: no new version
        let newer = try await lib.add(gcode(8), AddOptions(name: "part.nc", source: "Swarf", folder: "Jobs"))
        #expect(newer.id == first.id && newer.source == "Swarf")
        #expect(await lib.items().count == 1)
        #expect(await lib.content(first.id) == gcode(8))
        #expect(box.read("Jobs/part.nc") == gcode(8))
        let history = await lib.versions(first.id)
        #expect(history.map(\.sha256) == [first.sha256] && history[0].source == "Upload")

        try await lib.restoreVersion(first.id, sha: first.sha256)
        #expect(box.read("Jobs/part.nc") == gcode(3))
        #expect(await lib.versions(first.id).map(\.sha256) == [newer.sha256]) // the newer one is history now
    }

    @Test func createsRenamesMovesAndDeletesFolders() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        let f = try await lib.add(gcode(), AddOptions(name: "pocket.nc"))
        try await lib.createFolder("Guitars")
        try await lib.createFolder("Guitars/Strat")
        await #expect(throws: LibraryError("Guitars already exists")) { try await lib.createFolder("Guitars") }
        try await lib.moveFile(f.id, to: "Guitars/Strat")
        #expect(await lib.item(f.id)?.folder == "Guitars/Strat")
        #expect(box.exists("Guitars/Strat/pocket.nc") && !box.exists("pocket.nc"))

        try await lib.renameFile(f.id, "Body pocket")
        #expect(await lib.item(f.id)?.name == "Body pocket.nc") // keeps the extension
        box.finderWrite("Guitars/notes.md", Data("not G-code".utf8)) // goes along with its folder
        try await lib.renameFolder("Guitars", to: "Instruments")
        #expect(await lib.item(f.id)?.folder == "Instruments/Strat")
        #expect(await lib.folders() == ["Instruments", "Instruments/Strat"])
        #expect(box.read("Instruments/Strat/Body pocket.nc") == gcode())
        #expect(box.exists("Instruments/notes.md") && !box.exists("Guitars"))
        #expect(await lib.rescan() == false) // the library's own moves aren't changes
        await #expect(throws: LibraryError("A folder can't be moved inside itself")) {
            try await lib.renameFolder("Instruments", to: "Instruments/Strat/inner")
        }

        try await lib.deleteFolder("Instruments")
        #expect(await lib.items().isEmpty)
        #expect(await lib.folders().isEmpty)
        #expect(!box.exists("Instruments"))
        #expect(box.exists(".Deleted/Instruments/notes.md")) // what wasn't the library's is set aside
        let trash = await lib.trash()
        #expect(trash.map(\.item.id) == [f.id])

        try await lib.restore(f.id) // brings its folder back
        #expect(await lib.folders() == ["Instruments", "Instruments/Strat"])
        #expect(box.read("Instruments/Strat/Body pocket.nc") == gcode())
    }

    @Test func refusesUnsafeFolderNames() async throws {
        let lib = try await Sandbox().open()
        for bad in ["..", "a/../b", ".hidden", "", "x:y"] {
            await #expect(throws: LibraryError.self) { try await lib.createFolder(bad) }
        }
        let f = try await lib.add(gcode(), AddOptions(name: "a.nc"))
        await #expect(throws: LibraryError.self) { try await lib.moveFile(f.id, to: "../outside") }
        await #expect(throws: LibraryError("The folder Missing doesn't exist")) { try await lib.moveFile(f.id, to: "Missing") }
    }

    @Test func renamesWithoutClobbering() async throws {
        let lib = try await Sandbox().open()
        let a = try await lib.add(gcode(1), AddOptions(name: "a.nc"))
        _ = try await lib.add(gcode(2), AddOptions(name: "b.nc"))
        await #expect(throws: LibraryError("There is already a file called b.nc in this folder")) { try await lib.renameFile(a.id, "b.nc") }
        try await lib.createFolder("X")
        let x = try await lib.add(gcode(3), AddOptions(name: "a.nc", folder: "X"))
        try await lib.moveFile(x.id, to: "")
        #expect(await lib.item(x.id)?.name == "a (2).nc")
    }

    @Test func deleteGoesToTheTrashAndRestoreBringsItBack() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        let f = try await lib.add(gcode(), AddOptions(name: "part.nc"))
        try await lib.delete(f.id)
        #expect(await lib.items().isEmpty && !box.exists("part.nc"))
        #expect(await lib.trash().first?.item.name == "part.nc")
        // Its name was reused meanwhile: it comes back beside it.
        _ = try await lib.add(gcode(9), AddOptions(name: "part.nc"))
        try await lib.restore(f.id)
        #expect(await lib.item(f.id)?.name == "part (2).nc")
        #expect(box.read("part (2).nc") == gcode())
        #expect(await lib.trash().isEmpty)
    }

    @Test func followsFilesAddedMovedEditedAndRemovedInFinder() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        box.finderWrite("From Finder/drilled.gcode", gcode(7))
        box.finderWrite("notes.md", Data("just some notes".utf8))
        #expect(await lib.rescan())
        let item = try #require(await lib.items().first { $0.name == "drilled.gcode" })
        #expect(item.folder == "From Finder" && item.source == "Finder")
        #expect(await !lib.items().contains { $0.name == "notes.md" })
        #expect(await lib.rescan() == false) // nothing changed

        // A move keeps the id (and so its history and source).
        box.mkdir("Archive")
        box.move("From Finder/drilled.gcode", "Archive/drilled v1.gcode")
        #expect(await lib.rescan())
        let moved = await lib.item(item.id)
        #expect(moved?.folder == "Archive" && moved?.name == "drilled v1.gcode")

        // An edit in place is a new version.
        box.finderWrite("Archive/drilled v1.gcode", gcode(2))
        #expect(await lib.rescan())
        #expect(await lib.item(item.id)?.streamLines == 5)
        #expect(await lib.versions(item.id).map(\.sha256) == [item.sha256])

        // Deleting in Finder sends it to the library's Trash, content kept.
        box.remove("Archive/drilled v1.gcode")
        await lib.rescan()
        #expect(await lib.item(item.id) == nil)
        #expect(await lib.trash().map(\.item.id) == [item.id])
        #expect(await lib.folders() == ["Archive", "From Finder"])

        box.remove("From Finder")
        await lib.rescan()
        #expect(await lib.folders() == ["Archive"])
    }

    @Test func ownWritesAreNotChanges() async throws {
        let lib = try await Sandbox().open()
        let before = await lib.changes().count
        try await lib.add(gcode(), AddOptions(name: "a.nc", folder: "F"))
        let after = await lib.changes().count
        #expect(await lib.rescan() == false)
        #expect(await lib.changes().count == after && after > before)
    }

    @Test func noticesFinderChangesOnItsOwnWhileWatching() async throws {
        let box = Sandbox()
        let lib = try await box.open()
        let events = await lib.events()
        await lib.watch()
        let got = Task { for await _ in events { return true }; return false }
        box.finderWrite("dropped.nc", gcode())
        #expect(await until { await lib.items().contains { $0.name == "dropped.nc" } })
        #expect(await got.value)
        await lib.close()
    }

    @Test func remembersEverythingAndCatchesUpWithFinderAfterARestart() async throws {
        let box = Sandbox()
        var lib = try await box.open()
        let a = try await lib.add(gcode(), AddOptions(name: "a.nc", source: "Swarf", group: "G", groupIndex: 2))
        try await lib.saveMacro(Macro(id: "", name: " Probe corner ", gcode: "G38.2 Z-10 F50"))
        try await lib.saveConfig(MachineConfigPatch(safeZ: 12))
        await lib.close()

        box.finderWrite("while closed.nc", gcode(4))
        box.move("G/a.nc", "G/renamed.nc")
        lib = try await box.open()
        let again = try #require(await lib.item(a.id))
        #expect(again.name == "renamed.nc" && again.source == "Swarf" && again.group == "G" && again.groupIndex == 2)
        #expect(await lib.items().contains { $0.name == "while closed.nc" && $0.source == "Finder" })
        #expect(await lib.macros().last?.name == "Probe corner")
        #expect(await lib.config().safeZ == 12)
    }

    @Test func macrosAndConfigStartFromTheDefaults() async throws {
        let lib = try await Sandbox().open()
        #expect(await lib.macros() == defaultMacros)
        #expect(await lib.config() == .defaults)
        try await lib.saveMacro(Macro(id: "park", name: "Park", gcode: "G53 G0 Z-1"))
        try await lib.deleteMacro("modal")
        #expect(await lib.macros().map(\.name) == ["Lift Z 10 mm", "Park", "Spindle off"])
        await #expect(throws: LibraryError("The macro needs a name")) { try await lib.saveMacro(Macro(id: "", name: " ", gcode: "")) }
    }

    @Test func historyKeepsFiveVersionsForThirtyDays() async throws {
        let lib = try await Sandbox().open()
        let f = try await lib.add(gcode(1), AddOptions(name: "p.nc"))
        for n in 2...8 { try await lib.add(gcode(n), AddOptions(name: "p.nc")) }
        let kept = await lib.versions(f.id)
        #expect(kept.count == 5)
        #expect(await lib.content(sha: f.sha256) != nil) // still on disk until maintenance
        try await lib.maintenance()
        #expect(await lib.content(sha: f.sha256) == nil) // dropped from history, so its content goes

        try await lib.maintenance(now: nowMs() + 31 * 86_400_000)
        #expect(await lib.versions(f.id).isEmpty)
        #expect(await lib.item(f.id)?.streamLines == 11) // the current one stays, of course
    }

    @Test func trashEmptiesAfterThirtyDaysButPinnedContentStays() async throws {
        let lib = try await Sandbox().open()
        let a = try await lib.add(gcode(1), AddOptions(name: "a.nc"))
        let b = try await lib.add(gcode(2), AddOptions(name: "b.nc"))
        try await lib.delete(a.id)
        try await lib.delete(b.id)
        await lib.pin(a.sha256) // a job is running it
        try await lib.maintenance(now: nowMs() + 29 * 86_400_000)
        #expect(await lib.trash().count == 2)
        try await lib.maintenance(now: nowMs() + 31 * 86_400_000)
        #expect(await lib.trash().isEmpty)
        #expect(await lib.content(sha: a.sha256) == gcode(1))
        #expect(await lib.content(sha: b.sha256) == nil)
        await lib.unpin(a.sha256)
        try await lib.maintenance()
        #expect(await lib.content(sha: a.sha256) == nil)
    }

    @Test func logsEachFieldChangeWithItsBase() async throws {
        let lib = try await Sandbox().open()
        let start = await lib.changes().last?.seq ?? 0
        let f = try await lib.add(gcode(), AddOptions(name: "a.nc"))
        try await lib.renameFile(f.id, "b")
        try await lib.renameFile(f.id, "c")
        let log = await lib.changes(after: start).filter { $0.entity == "entry" }
        #expect(log.map(\.field) == ["create", "path", "path"])
        #expect(log[1].base == log[0].stamp && log[2].base == log[1].stamp)
        #expect(log[0].stamp < log[1].stamp && log[1].stamp < log[2].stamp)
        #expect(log[2].value == #"{"folder":"","name":"c.nc"}"#)
        #expect(log.allSatisfy { $0.stamp.replica == lib.replica })
    }

    @Test func importsTheV1LibraryOnceKeepingIds() async throws {
        let box = Sandbox()
        let v1Data = box.dir.appending(path: "hub")
        try FileManager.default.createDirectory(at: v1Data, withIntermediateDirectories: true)
        // 1.0 and 2.0 share the Finder folder.
        box.finderWrite("Body/side A.nc", gcode(3))
        box.finderWrite("dots.nc", gcode(4))
        box.finderWrite("untracked.nc", gcode(5))
        box.mkdir("Empty")
        let index = """
            {"version":1,"items":[
             {"id":"aaa","name":"side A.nc","folder":"Body","source":"Swarf","group":"Body","groupIndex":0,"addedAt":1000},
             {"id":"bbb","name":"dots.nc","folder":"","source":"Fretboard","addedAt":2000},
             {"id":"gone","name":"missing.nc","folder":"","source":"Upload","addedAt":3000}]}
            """
        try Data(index.utf8).write(to: box.path(".gcode-controller.json"))
        try Data(#"[{"id":"m1","name":"Mine","gcode":"G0 X0"}]"#.utf8).write(to: v1Data.appending(path: "macros.json"))
        try Data(#"{"safeZ":7,"probe":{"plateThickness":19.6}}"#.utf8).write(to: v1Data.appending(path: "config.json"))

        let v1 = V1Paths(dataDir: v1Data, libraryDir: box.root)
        var lib = try await box.open(importV1: v1)
        let a = try #require(await lib.item("aaa"))
        #expect(a.folder == "Body" && a.source == "Swarf" && a.group == "Body" && a.groupIndex == 0 && a.addedAt == 1000)
        #expect(await lib.item("bbb")?.source == "Fretboard")
        #expect(await lib.items().count == 3) // plus the untracked file, as a Finder file
        #expect(await lib.items().first { $0.name == "untracked.nc" }?.source == "Finder")
        #expect(await lib.folders() == ["Body", "Empty"])
        #expect(await lib.macros() == [Macro(id: "m1", name: "Mine", gcode: "G0 X0")])
        let config = await lib.config()
        #expect(config.safeZ == 7 && config.probe.plateThickness == 19.6 && config.probe.seekFeed == 150)
        #expect(box.read("Body/side A.nc") == gcode(3)) // 1.0's files are left as they were
        await lib.close()

        // A second start doesn't import again.
        try await lib.saveMacro(Macro(id: "m2", name: "Two", gcode: "G0 Y0"))
        lib = try await box.open(importV1: v1)
        #expect(await lib.items().count == 3)
        #expect(await lib.macros().count == 2)
    }

    @Test func importsFromASeparateV1FolderByCopying() async throws {
        let box = Sandbox()
        let old = box.dir.appending(path: "old library")
        try FileManager.default.createDirectory(at: old.appending(path: "Jobs"), withIntermediateDirectories: true)
        try gcode(3).write(to: old.appending(path: "Jobs/p.nc"))
        try Data(#"{"items":[{"id":"p1","name":"p.nc","folder":"Jobs","source":"Swarf","addedAt":5}]}"#.utf8)
            .write(to: old.appending(path: ".gcode-controller.json"))
        let lib = try await box.open(importV1: V1Paths(dataDir: box.dir.appending(path: "none"), libraryDir: old))
        #expect(await lib.item("p1")?.folder == "Jobs")
        #expect(box.read("Jobs/p.nc") == gcode(3))
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "Jobs/p.nc").path))
    }
}

@Suite struct NameTests {
    @Test func sanitizesNames() throws {
        #expect(sanitizeName("../../etc/pass:wd") == "passwd")
        #expect(sanitizeName("..hidden.nc") == "hidden.nc")
        #expect(sanitizeName("").hasPrefix("upload-"))
        #expect(folderName("Body / back: v2") == "Body - back- v2")
        #expect(try checkFolder(" /Guitars/ Strat / ") == "Guitars/Strat")
        #expect(uniqueName("part.NC") { $0 == "part.NC" || $0 == "part (2).NC" } == "part (3).NC")
    }

    @Test func stampsOrderAndRoundTrip() {
        var clock = HybridClock(replica: "abc", last: nil)
        let a = clock.tick(wall: 1000), b = clock.tick(wall: 1000), c = clock.tick(wall: 900)
        #expect(a < b && b < c && c.ms == 1000 && c.counter == 2)
        #expect(Stamp(c.description) == c)
        #expect(a.description < b.description)
        clock.observe(Stamp(ms: 5000, counter: 3, replica: "xyz"))
        #expect(clock.tick(wall: 1000) == Stamp(ms: 5000, counter: 4, replica: "abc"))
    }
}

extension Library {
    /// Puts back an analysis row as a build from before the spindle check wrote it.
    func writeOldAnalysis(_ sha: String) throws {
        let json = #"{"size":10,"sourceLines":3,"streamLines":3,"estSeconds":1}"#
        _ = try db.run("INSERT OR REPLACE INTO analysis(sha, json) VALUES(?, ?)", [sha, json])
    }
}

@Suite struct AnalysisCacheTests {
    /// Files analysed by an older build are worked out again, so they get the spindle check too.
    @Test func olderAnalysesAreRedone() async throws {
        let sb = Sandbox()
        let lib = try await sb.open()
        let item = try await lib.add(gcode(), AddOptions(name: "a.nc"))
        #expect(item.spindleOffCut == 2)
        try await lib.writeOldAnalysis(item.sha256)
        let again = try #require(await lib.item(item.id))
        #expect(again.spindleOffCut == 2)
        #expect(again.streamLines == item.streamLines)
    }

    /// The Z-zero reference reaches library items, including ones analysed before it was read.
    @Test func zZeroReachesItems() async throws {
        let sb = Sandbox()
        let lib = try await sb.open()
        let item = try await lib.add(Data("; Z0 = SPOILBOARD surface (bottom of the stock)\nG21\nM3 S10000\nG1 X1 F500\n".utf8), AddOptions(name: "z.nc"))
        #expect(item.zZero == .spoilboard)
        try await lib.writeOldAnalysis(item.sha256)
        #expect(try #require(await lib.item(item.id)).zZero == .spoilboard)
    }
}
