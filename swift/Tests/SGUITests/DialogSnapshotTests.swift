// Renders each dialog offscreen to PNG when SG_SNAPSHOT_DIR is set (for looking at layout
// without a window on screen); otherwise just checks they lay out.

import AppKit
import Foundation
import SGCore
import SGNet
import SwiftUI
import Testing
@testable import SGUI

@MainActor @Suite struct DialogSnapshotTests {
    func model() -> AppModel {
        let m = AppModel()
        var s = AppState(
            link: LinkState(hubConnected: true, agentConnected: true, via: .hub), machine: MachineState(), job: JobState(),
            library: [
                LibraryItem(id: "a", name: "body-pocket.nc", folder: "", source: "Swarf", size: 1000, sha256: "a", addedAt: 0, sourceLines: 400,
                    streamLines: 380, bounds: Bounds(min: Vec3(-20, -10, -6), max: Vec3(120, 80, 5)),
                    cutBounds: Bounds(min: Vec3(-20, -10, -6), max: Vec3(120, 80, 0)), estSeconds: 1260, group: "Body", groupIndex: 0),
                LibraryItem(id: "b", name: "body-profile.nc", folder: "", source: "Swarf", size: 1000, sha256: "b", addedAt: 0, sourceLines: 1,
                    streamLines: 1, bounds: nil, cutBounds: nil, estSeconds: 0, group: "Body", groupIndex: 1),
            ],
            folders: [], libraryRoot: nil, macros: [], config: .defaults, console: [])
        s.link.machineOn = "Garage"
        s.machine.connection = .connected
        s.machine.status = .idle
        s.machine.port = "/dev/cu.usbserial-110"
        s.machine.firmware = "Grbl 1.1h"
        s.machine.homed = true
        s.machine.wco = Vec3(120, 140, -30)
        s.machine.wpos = Vec3(0, 0, 5)
        var st = Dictionary(uniqueKeysWithValues: foxAlien.settings.map { ($0.key, $0.value) })
        st["22"] = "0"
        st["130"] = "400"; st["131"] = "400"; st["132"] = "55"
        s.machine.settings = st
        s.job.status = .stopped
        s.job.fileId = "a"
        s.job.fileName = "body-pocket.nc"
        s.job.resumeLine = 120
        m.state = s
        return m
    }

    func render(_ name: String, _ view: some View, _ m: AppModel) throws {
        let host = NSHostingView(rootView: view.environment(m).environment(\.colorScheme, .dark))
        let size = host.fittingSize
        #expect(size.width > 100 && size.height > 100)
        guard let dir = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"] else { return }
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(filePath: dir).appending(path: "dialog-\(name).png"))
    }

    /// The position panel's rows (Zero, →0, Home) fit the left column with the longest positions.
    @Test func positionPanel() async throws {
        let m = model()
        var s = try #require(m.state)
        s.machine.wpos = Vec3(-800, -800, -120)
        s.machine.mpos = Vec3(-800, -800, -120)
        m.state = s
        let host = NSHostingView(rootView: DroPanel(s: s).fixedSize().environment(m))
        #expect(host.fittingSize.width <= 330, "needs \(host.fittingSize.width) pt")
        try render("position", DroPanel(s: s).frame(width: 330), m)
    }

    @Test func dialogs() async throws {
        let m = model()
        try render("start", StartDialog(req: StartRequest(fileId: "a", next: false)), m)
        try render("probe", ProbeDialog(), m)
        try render("surfacing", SurfacingDialog(), m)
        try render("settings", SettingsView(), m)
        try render("startup", StartupCheck(s: m.state!).frame(width: 900), m)
    }
}
