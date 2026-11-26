import Foundation
import SGCore
import SGNet
import Testing
@testable import SGUI

@Suite struct DialogLogicTests {
    func state(_ edit: (inout AppState) -> Void = { _ in }) -> AppState {
        var s = AppState(
            link: LinkState(hubConnected: true, agentConnected: false, via: .hub), machine: MachineState(), job: JobState(), library: [],
            folders: [], libraryRoot: nil, macros: [], config: .defaults, console: [])
        s.machine.connection = .connected
        s.machine.status = .idle
        s.config.probe.plateThickness = 12.5
        edit(&s)
        return s
    }

    func item(_ id: String, group: String? = nil, _ i: Int? = nil) -> LibraryItem {
        LibraryItem(id: id, name: "\(id).nc", folder: "", source: "Upload", size: 1, sha256: id, addedAt: 0, sourceLines: 1, streamLines: 1,
            bounds: nil, cutBounds: nil, estSeconds: 0, group: group, groupIndex: i)
    }

    @Test func homeCorners() {
        let t = Vec3(400, 400, 55)
        #expect(HomeCorner.frontLeft.envelope(travel: t) == Bounds(min: Vec3(0, 0, -55), max: Vec3(400, 400, 0)))
        #expect(HomeCorner.backRight.envelope(travel: t) == Bounds(min: Vec3(-400, -400, -55), max: .zero))
        #expect(HomeCorner(HomeCorner.frontLeft.envelope(travel: t)) == .frontLeft)
        #expect(HomeCorner(HomeCorner.backRight.envelope(travel: t)) == .backRight)
        #expect(HomeCorner(dirMask: 3) == .frontLeft)
        #expect(HomeCorner(dirMask: 4) == .backRight)
        #expect(HomeCorner(dirMask: 1) == nil)
    }

    @Test func jogSteps() {
        #expect(parseJogSteps("10, 0.1 1,,-2 x 0") == [0.1, 1, 10])
        #expect(parseJogSteps("") == [])
    }

    @Test func probeBlockedReasons() {
        #expect(state().probeBlocked == nil)
        #expect(state { $0.machine.connection = .disconnected }.probeBlocked == "The machine is not connected")
        #expect(state { $0.config.probe.plateThickness = 0 }.probeBlocked?.hasPrefix("Measure the touch plate") == true)
        #expect(state { $0.machine.status = .alarm }.probeBlocked == "Unlock the machine first")
        #expect(state { $0.machine.status = .run }.probeBlocked == "The machine is Run")
        #expect(state { $0.machine.pins = "PZ" }.probeBlocked?.hasPrefix("The probe input is closed") == true)
        #expect(state { $0.job.status = .running }.probeBlocked == "A job is running")
    }

    @Test func notIdleReasons() {
        #expect(state().notIdleReason == nil)
        #expect(state { $0.machine.status = .alarm }.notIdleReason == "Home or unlock the machine first")
        #expect(state { $0.job.status = .paused }.notIdleReason == "A job is running")
    }

    @Test func groupFollowingIsInRunOrder() {
        let s = state {
            $0.library = [item("c", group: "g", 2), item("a", group: "g", 0), item("x"), item("b", group: "g", 1)]
        }
        #expect(s.groupFollowing(item("a", group: "g", 0)).map(\.id) == ["b", "c"])
        #expect(s.groupFollowing(item("c", group: "g", 2)).isEmpty)
        #expect(s.groupFollowing(item("x")).isEmpty)
    }

    @Test func settingChecksSkipTheSimulator() {
        let wrong = Dictionary(uniqueKeysWithValues: foxAlien.settings.map { ($0.key, "999") })
        #expect(!state { $0.machine.settings = wrong }.settingProblems.isEmpty)
        #expect(state { $0.machine.settings = wrong; $0.machine.simulated = true }.settingProblems.isEmpty)
        let right = Dictionary(uniqueKeysWithValues: foxAlien.settings.map { ($0.key, $0.value) })
        #expect(state { $0.machine.settings = right }.settingProblems.isEmpty)
    }

    @Test func axesOutsideTravel() {
        let env = Bounds(min: Vec3(0, 0, -55), max: Vec3(400, 400, 0))
        let b = Bounds(min: Vec3(-5, 0, -3), max: Vec3(100, 100, 5))
        #expect(axesOutside(b, envelope: env, wco: Vec3(10, 10, -20)) == [])
        #expect(axesOutside(b, envelope: env, wco: Vec3(0, 10, -20)) == ["X"])
        #expect(axesOutside(b, envelope: env, wco: Vec3(10, 350, -2)) == ["Y", "Z"])
    }

    @Test func surfacingParamsPersist() throws {
        let d = try #require(UserDefaults(suiteName: "swarfgrbl.test.\(UUID())"))
        #expect(SurfacingStore.load(d) == .defaults)
        var p = SurfacingParams.defaults
        p.lengthX = 123
        p.widthY = 45
        SurfacingStore.save(p, d)
        #expect(SurfacingStore.load(d) == p)
    }

    @Test func shortNumbers() {
        #expect(short(3) == "3")
        #expect(short(0.5) == "0.5")
        #expect(short(-12.25) == "-12.25")
    }
}
