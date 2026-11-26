import SGCore
import SGNet
import Testing
import simd
import Metal
import Foundation
import CoreGraphics
import ImageIO

@testable import SGUI

@Suite struct CameraTests {
    func project(_ c: OrbitCamera, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = c.projection * c.view * SIMD4(p, 1)
        return SIMD3(v.x / v.w, v.y / v.w, v.z / v.w)
    }

    @Test func isoFitPutsBoundsOnScreen() {
        var c = OrbitCamera()
        c.aspect = 1
        let b = Bounds(min: Vec3(-40, -30, -3), max: Vec3(0, 0, 0))
        c.fit(b, .iso)
        for p in [SIMD3<Float>(0, 0, 0), SIMD3(-40, -30, -3), SIMD3(-40, 0, 0), SIMD3(0, -30, -3)] {
            let s = project(c, p)
            print(p, s)
            #expect(abs(s.x) < 1 && abs(s.y) < 1 && s.z > 0 && s.z < 1)
        }
    }

    @Test func topViewHasXRightYUp() {
        var c = OrbitCamera()
        c.aspect = 1.5
        c.fit(Bounds(min: Vec3(0, 0, 0), max: Vec3(100, 50, 5)), .top)
        let o = project(c, SIMD3(0, 0, 0)), x = project(c, SIMD3(100, 0, 0)), y = project(c, SIMD3(0, 50, 0))
        #expect(x.x > o.x + 0.1 && abs(x.y - o.y) < 0.01)
        #expect(y.y > o.y + 0.1 && abs(y.x - o.x) < 0.01)
    }

    @Test func frontViewHasZUp() {
        var c = OrbitCamera()
        c.fit(Bounds(min: Vec3(0, 0, -10), max: Vec3(100, 50, 0)), .front)
        let o = project(c, SIMD3(0, 0, -10)), x = project(c, SIMD3(100, 0, -10)), z = project(c, SIMD3(0, 0, 0))
        #expect(x.x > o.x + 0.1)
        #expect(z.y > o.y + 0.01)
    }
}

@MainActor @Suite struct RendererTests {
    /// Pixels within a few levels of `rgb` (BGRA bytes).
    func count(_ px: [UInt8], _ rgb: (Int, Int, Int)) -> Int {
        stride(from: 0, to: px.count, by: 4).count { i in
            abs(Int(px[i + 2]) - rgb.0) < 6 && abs(Int(px[i + 1]) - rgb.1) < 6 && abs(Int(px[i]) - rgb.2) < 6
        }
    }

    @Test func drawsPathAxesAndProgress() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let r = try #require(ToolpathRenderer(device: device, sampleCount: 1))
        let p = LoadedProgram(sha: "x", text: "G21 G90\nG0 Z-1\nG1 X-20 Y-10 F2000\nG1 X-40 Y-30\nG1 Z-3\nM30\n", rapidRate: 5000)
        r.setProgram(p.analysis.segments, bounds: p.analysis.bounds)
        var px = try #require(r.snapshot(width: 400, height: 300, sampleCount: 1))
        if let dir = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"] { writePNG(px, 400, 300, "\(dir)/viz-test.png") }
        #expect(count(px, (0x9a, 0x9a, 0x9a)) > 50)  // the path, to cut
        #expect(count(px, (0xd9, 0x6b, 0x6b)) > 20)  // X axis
        #expect(count(px, (0x6a, 0x9f, 0xd9)) > 20)  // Z axis
        #expect(count(px, (0xc5, 0xa0, 0x59)) == 0)
        r.setProgress(3)
        px = try #require(r.snapshot(width: 400, height: 300, sampleCount: 1))
        #expect(count(px, (0xc5, 0xa0, 0x59)) > 50)  // cut, in gold
        r.setTool(Vec3(-20, -10, 0))
        px = try #require(r.snapshot(width: 400, height: 300, sampleCount: 1))
        #expect(count(px, (0xd8, 0xb6, 0x72)) > 20)  // the tool
    }

    func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, _ path: String) {
        var rgba = px
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(filePath: path) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}


@Suite struct VizLogicTests {
    let program = LoadedProgram(sha: "x", text: "G21 G90\nG0 Z-1\n\nG1 X-20 Y-10 F2000\nG1 X-40 Y-30\nG1 Z-3\nM30\n", rapidRate: 5000)

    @Test func doneLineFollowsCuttingThenPlanner() {
        var j = JobState()
        j.status = .running
        #expect(doneSourceLine(j, program, plannerFree: nil, plannerSize: 15) == -1)
        j.ackedLines = 4
        // Streamed lines 1…4 are source lines 0, 1, 3, 4 (the blank line isn't sent).
        #expect(doneSourceLine(j, program, plannerFree: nil, plannerSize: 15) == 4)
        #expect(doneSourceLine(j, program, plannerFree: 13, plannerSize: 15) == 1)
        j.cuttingLine = 3
        #expect(doneSourceLine(j, program, plannerFree: 13, plannerSize: 15) == 3)
        j.status = .stopped
        j.resumeLine = 2
        #expect(doneSourceLine(j, program, plannerFree: nil, plannerSize: 15) == 1)
        j.status = .done
        #expect(doneSourceLine(j, program, plannerFree: nil, plannerSize: 15) == Int.max)
    }

    @Test func overrunsNameTheAxisAndSide() {
        let env = Bounds(min: Vec3(0, 0, -100), max: Vec3(400, 400, 0))
        let b = Bounds(min: Vec3(-40, -30, -3), max: Vec3(0, 0, 0))
        #expect(travelOverruns(b, envelope: env, wco: Vec3(100, 100, -10)).isEmpty)
        let r = travelOverruns(b, envelope: env, wco: Vec3(20, 100, 2))
        #expect(r == ["X goes 20.0 mm left of the machine's travel", "Z goes 2.0 mm above the machine's travel"])
        #expect(overrunAdvice(envelope: env, wco: .zero).contains("hasn't been set"))
        #expect(overrunAdvice(envelope: env, wco: Vec3(1, 1, 2)).contains("above the top"))
    }

    @Test func remainingBlendsPlanAndPace() {
        var j = JobState()
        #expect(remainingSeconds(j, now: 0) == nil)
        j.status = .running
        j.startedAt = 0
        j.totalSeconds = 1000
        j.doneSeconds = 10
        #expect(remainingSeconds(j, now: 10_000) == 990)  // too early to judge the pace
        j.doneSeconds = 500
        // Twice as slow as planned, past 20%: the pace alone.
        #expect(remainingSeconds(j, now: 1_000_000) == 1000)
    }

    @Test func dims() {
        #expect(boundsDims(Bounds(min: Vec3(-40, -30, -3), max: .zero)) == "40.0 × 30.0 × 3.0 mm")
        #expect(boundsDims(nil) == "")
    }
}
