// Port of packages/shared/test/travel.test.ts, machineCheck.test.ts and the protocol parts of
// code.test.ts, plus JSON compatibility with 1.0's saved data.

import Foundation
import Testing
@testable import SGCore

@Suite struct TravelTests {
    let abs = DistanceModes(absolute: true, inches: false)
    let mpos = Vec3(100, 200, -50)
    let wco = Vec3(10, 20, -80)
    let env = Bounds(min: Vec3(0, 0, -100), max: Vec3(800, 800, 0))

    func target(_ line: String) -> [Double?]? { lineTarget(line, modes: abs, mpos: mpos, wco: wco).target }

    @Test func followsAbsoluteRelativeInchesAndMachineCoordinates() {
        #expect(target("G0 Z10") == [nil, nil, -70])
        #expect(lineTarget("G91 G0 Z60", modes: abs, mpos: mpos, wco: wco) == LineTarget(target: [nil, nil, 10], modes: .init(absolute: false, inches: false)))
        #expect(target("G20 G0 X1")?[0].map { close($0, 35.4, 9) } == true)
        #expect(target("G53 G0 Z-1") == [nil, nil, -1])
        #expect(target("G1 X5 Y5 F100 (comment Z99)") == [15, 25, nil])
        #expect(target("g1 x5 ; Z99") == [15, nil, nil])
    }

    @Test func treatsJogsAsOneOffsThatDontChangeTheModes() {
        #expect(lineTarget("$J=G91G21Z60F1000", modes: abs, mpos: mpos, wco: wco) == LineTarget(target: [nil, nil, 10], modes: abs))
    }

    @Test func ignoresLinesThatSetOffsetsOrGoToStoredPositions() {
        #expect(target("G10 L20 P0 Z0") == nil)
        #expect(target("G28 Z0") == nil)
        #expect(target("$H") == nil)
        #expect(target("M3 S1000") == nil)
    }

    @Test func readsTheModesFromDollarGAndDescribesHowFarPastTheTravelATargetGoes() {
        #expect(modesFromModal("[GC:G0 G54 G17 G20 G91 G94 M5 M9 T0 F0 S0]") == DistanceModes(absolute: false, inches: true))
        #expect(modesFromModal(nil) == DistanceModes(absolute: true, inches: false))
        #expect(travelProblem([nil, nil, 10], env) == "10.0 mm past the top of Z")
        #expect(travelProblem([-5, 900, nil], env) == "5.0 mm past the start of X and 100.0 mm past the end of Y")
        #expect(travelProblem([400, 400, -50], env) == nil)
    }
}

@Suite struct MachineCheckTests {
    // The FoxAlien's settings as read on 2026-11-18 (before soft limits were turned on).
    let now = ["20": "0", "21": "1", "22": "1", "23": "3", "27": "3.000", "30": "24000.000", "32": "0", "130": "800.000", "131": "800.000", "132": "100.000"]

    func with(_ changes: [String: String]) -> [String: String] { now.merging(changes) { $1 } }

    @Test func comparesNumbersAsNumbersAndReportsOnlyWhatDiffers() {
        let problems = checkSettings(now, foxAlien)
        #expect(problems.count == 1)
        #expect(problems[0].key == "20" && problems[0].expected == "1" && problems[0].actual == "0" && problems[0].why.contains("Soft limits"))
        #expect(checkSettings(with(["20": "1"]), foxAlien).isEmpty)
    }

    @Test func catchesAControllerThatHasLostItsSettings() {
        let defaults = with(["20": "0", "23": "0", "30": "1000", "130": "200", "131": "200", "132": "200"])
        #expect(checkSettings(defaults, foxAlien).map(\.key) == ["20", "23", "30", "130", "131", "132"])
        let missing = checkSettings([:], foxAlien)
        #expect(missing.count == foxAlien.settings.count)
        #expect(missing[0].actual == nil)
    }

    @Test func worksOutTheTravelFromTheSettingsAndTheHomingCorner() throws {
        let env = try #require(envelopeFromSettings(now))
        #expect(env == Bounds(min: Vec3(0, 0, -100), max: Vec3(800, 800, 0)))
        #expect(sameEnvelope(env, Bounds(min: Vec3(0, 0, -100), max: Vec3(800, 800, 0))))
        #expect(envelopeFromSettings(with(["23": "0"])) == Bounds(min: Vec3(-800, -800, -100), max: Vec3(0, 0, 0)))
        #expect(envelopeFromSettings(with(["23": "1"])) == nil)
    }

    @Test func remindsAboutTheLaserSpindleSwitch() {
        #expect(foxAlien.hardware.joined(separator: " ").contains("Laser/Spindle switch is set to LASER"))
        #expect(foxAlien.spindleReminder?.contains("LASER") == true)
    }
}

@Suite struct ProtocolTests {
    func at(_ commit: String, _ time: Double? = nil) -> CodeVersion {
        CodeVersion(version: "0.1.0", commit: commit.padding(toLength: 40, withPad: "0", startingAt: 0), time: time)
    }

    @Test func ordersCommitsByTime() {
        #expect(compareCode(at("a", 1), at("a", 1)) == .same)
        #expect(compareCode(at("a", 1), at("b", 2)) == .behind)
        #expect(compareCode(at("b", 2), at("a", 1)) == .ahead)
        #expect(compareCode(at("a", 1), at("b", 1)) == .different)
        #expect(compareCode(at("a"), at("b", 1)) == .different)
        #expect(compareCode(CodeVersion(version: "0.1.0"), at("b", 1)) == .unknown)
        #expect(at("abcdef123").shortCommit == "abcdef1")
    }

    @Test func ordersReleasesByVersionFirst() {
        func v(_ version: String, _ commit: String? = nil, _ time: Double? = nil) -> CodeVersion {
            CodeVersion(version: version, commit: commit, time: time)
        }
        // A newer release is ahead even if its commit is older (a fix released from a branch).
        #expect(compareCode(v("2.1", "b", 1), v("2.2", "a", 2)) == .behind)
        #expect(compareCode(v("2.10", "b", 9), v("2.9", "a", 1)) == .ahead)
        #expect(compareCode(v("2.1", "b", 2), v("2.1.1", "a", 1)) == .behind)
        // Equal versions ("2.1" is "2.1.0"): a build from git after the tag is ahead of the release.
        #expect(compareCode(v("v2.1", "a", 1), v("2.1.0", "b", 2)) == .behind)
        #expect(compareCode(v("2.1", "a", 1), v("2.1", "a", 1)) == .same)
        // Releases without commits still compare.
        #expect(compareCode(v("2.1"), v("2.2")) == .behind)
        #expect(compareCode(v("2.1"), v("2.1")) == .unknown)
        // Not a version number: commits decide.
        #expect(compareCode(v("dev", "a", 1), v("2.2", "b", 2)) == .behind)
    }

    @Test func commandsEncodeAs1_0Json() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(Command.jog(x: 1, y: nil, z: nil, feed: 3000)), as: UTF8.self)
        #expect(json == #"{"feed":3000,"type":"jog","x":1}"#)
        let all: [Command] = [
            .connect(port: "/dev/cu.usbserial-110"), .connect(port: nil), .home, .stop, .zero(axes: [.X, .Z]),
            .start(fileId: "abc", group: true, fromLine: 120), .start(fileId: "abc", group: nil, fromLine: nil, spindleOff: true), .override(kind: .feed, action: .plus10), .mdi(line: "G0 X0"),
            .renameFolder(path: "a", to: "b"), .saveMacro(macro: Macro(id: "m", name: "Park", gcode: "G53 G0 Z-1")),
            .saveConfig(config: MachineConfigPatch(safeZ: 10)), .update(target: .agent),
        ]
        for c in all {
            #expect(try JSONDecoder().decode(Command.self, from: enc.encode(c)) == c)
        }
        let fromWeb = #"{"type":"goToZero","axes":["X","Y"]}"#
        #expect(try JSONDecoder().decode(Command.self, from: Data(fromWeb.utf8)) == .goToZero(axes: [.X, .Y]))
        #expect(Command.home.movesMachine && !Command.stop.movesMachine)
        #expect(Command.deleteFile(fileId: "x").isLibraryCommand && !Command.hold.isLibraryCommand)
    }

    @Test func decodes1_0SavedData() throws {
        // A library.json entry and config.json as 1.0 writes them.
        let item = #"""
        {"id":"k3j2h","name":"part.nc","folder":"Guitars/Tele","source":"swarf","size":1234,"sha256":"ab12","addedAt":1763400000000,
         "sourceLines":40,"streamLines":38,"bounds":{"min":[0,0,-3],"max":[100,50,5]},"cutBounds":null,"estSeconds":61.5,"group":"Body","groupIndex":1}
        """#
        let li = try JSONDecoder().decode(LibraryItem.self, from: Data(item.utf8))
        #expect(li.folder == "Guitars/Tele" && li.bounds?.max == Vec3(100, 50, 5) && li.cutBounds == nil && li.groupIndex == 1)

        let config = #"""
        {"envelope":{"min":[0,0,-100],"max":[800,800,0]},"safeZ":5,"jogSteps":[0.1,1,10,50],"jogFeedXY":3000,"jogFeedZ":1000,
         "rapidRate":5000,"probe":{"plateThickness":19.6,"maxTravel":25,"seekFeed":150,"latchFeed":25,"retract":5}}
        """#
        var c = try JSONDecoder().decode(MachineConfig.self, from: Data(config.utf8))
        #expect(c.probe.plateThickness == 19.6 && c.envelope.max == Vec3(800, 800, 0))
        c.apply(MachineConfigPatch(safeZ: 8))
        #expect(c.safeZ == 8 && c.jogFeedXY == 3000)
    }

    @Test func jobProgressAndTiming() {
        var job = JobState()
        #expect(job.percent == 0 && job.elapsedSeconds() == 0)
        job.totalLines = 100
        job.ackedLines = 50
        #expect(job.percent == 50)
        job.totalSeconds = 200
        job.doneSeconds = 20
        #expect(job.percent == 10)
        job.status = .toolchange
        #expect(job.percent == 100 && job.status.isActive)
        job.startedAt = 1000
        job.pausedMs = 2000
        #expect(job.elapsedSeconds(now: 11000) == 8)
        job.pausedAt = 9000
        #expect(job.elapsedSeconds(now: 11000) == 6)
    }

    @Test func formatsNumbersLike1_0() {
        #expect(gnum(10.5) == "10.5" && gnum(100) == "100" && gnum(-0.0001) == "0" && gnum(3.14159) == "3.142")
        #expect(jsNumber(6) == "6" && jsNumber(1.5) == "1.5" && jsNumber(0.1) == "0.1")
        #expect(formatDuration(65) == "01:05" && formatDuration(3725) == "1:02:05" && formatDuration(-1) == "--:--")
        #expect(randomId().count == 10)
    }
}
