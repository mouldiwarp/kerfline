// An orbit camera for the toolpath view, Z up, as 1.0's three.js OrbitControls: drag to rotate,
// scroll or pinch to zoom, right-drag (or ⌥-drag) to pan. Views fit the program's bounds.

import SGCore
import simd

public enum ViewName: String, CaseIterable, Sendable {
    case iso, top, front, right

    var direction: SIMD3<Float> {
        switch self {
        case .iso: simd_normalize(SIMD3(0.75, -1.15, 1.0))
        case .top: SIMD3(0, 0, 1)
        case .front: SIMD3(0, -1, 0)
        case .right: SIMD3(1, 0, 0)
        }
    }
}

struct OrbitCamera {
    var target = SIMD3<Float>(50, 50, 0)
    /// Angle around Z, from +X, radians.
    var azimuth: Float = 0
    /// Angle above the XY plane, radians (±89°).
    var elevation: Float = 0.6
    var distance: Float = 300
    var fovY: Float = 40 * .pi / 180
    var aspect: Float = 1

    static let maxElevation: Float = 89.9 * .pi / 180

    var eye: SIMD3<Float> {
        let c = cos(elevation)
        return target + distance * SIMD3(c * cos(azimuth), c * sin(azimuth), sin(elevation))
    }

    var forward: SIMD3<Float> { simd_normalize(target - eye) }
    var right: SIMD3<Float> {
        // Straight down (top view) keeps +X to the right and +Y up the screen.
        let r = simd_cross(forward, SIMD3(0, 0, 1))
        return simd_length(r) < 1e-4 ? SIMD3(-sin(azimuth), cos(azimuth), 0) : simd_normalize(r)
    }
    var up: SIMD3<Float> { simd_cross(right, forward) }

    var view: simd_float4x4 { lookAt(eye: eye, target: target, up: up) }

    var projection: simd_float4x4 {
        perspective(fovY: fovY, aspect: aspect, near: max(distance / 100, 0.05), far: distance * 20)
    }

    /// Fit `b` (or a 100×100×10 box) into view from `view`'s direction.
    mutating func fit(_ b: Bounds?, _ view: ViewName) {
        let b = b ?? Bounds(min: .zero, max: Vec3(100, 100, 10))
        let lo = SIMD3<Float>(b.min), hi = SIMD3<Float>(b.max)
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 10)
        let hFov = 2 * atan(tan(fovY / 2) * aspect)
        distance = radius / sin(min(fovY, hFov) / 2) * 1.02
        let d = view.direction
        elevation = asin(max(-1, min(1, d.z)))
        elevation = min(Self.maxElevation, max(-Self.maxElevation, elevation))
        // Top view looks down with +Y up the screen: azimuth -90° (camera "south" of the target).
        azimuth = view == .top ? -.pi / 2 : atan2(d.y, d.x)
    }

    mutating func orbit(dx: Float, dy: Float) {
        azimuth -= dx * 0.008
        elevation = min(Self.maxElevation, max(-Self.maxElevation, elevation - dy * 0.008))
    }

    /// Pan by a drag of (dx, dy) points in a view `height` points tall.
    mutating func pan(dx: Float, dy: Float, height: Float) {
        let worldPerPoint = 2 * distance * tan(fovY / 2) / max(height, 1)
        target += (-dx * right + dy * up) * worldPerPoint
    }

    mutating func zoom(_ factor: Float) {
        distance = min(1_000_000, max(1, distance * factor))
    }
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

/// Right-handed perspective, Metal clip space (z from 0 to 1).
func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)
    ))
}
