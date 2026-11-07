//
//  HideScene.swift
//  The result of scanning (or of the built-in demo room): the extracted, colored
//  environment around the hiding spot, expressed in hide-anchor space.
//

import Foundation
import simd

struct HideScene: Sendable {
    let environment: EnvironmentGeometry
    /// Hide-anchor space -> ARKit world space.
    let anchorToWorld: simd_float4x4
    let surface: SurfaceKind
    /// Anchor-space positions a seeker is likely to look from. For a real scan these
    /// are the keyframe camera positions; auto-camouflage optimizes for them.
    let viewpoints: [Vec3]
    let isDemo: Bool
}

enum SceneExtraction {
    /// Radius of the room chunk kept around the hiding spot.
    static let cropRadius: Float = 1.25
    /// Caps memory and bake time on very detailed scans.
    static let maxTriangles = 150_000

    /// Moves world-space triangles into anchor space, keeping those near the spot.
    static func crop(v0: [Vec3], v1: [Vec3], v2: [Vec3], anchorToWorld: simd_float4x4,
                     radius: Float = cropRadius) -> (v0: [Vec3], v1: [Vec3], v2: [Vec3]) {
        let worldToAnchor = anchorToWorld.inverse
        var candidates: [(distance: Float, a: Vec3, b: Vec3, c: Vec3)] = []
        candidates.reserveCapacity(v0.count / 4)
        for i in 0..<v0.count {
            let a = worldToAnchor.transformPoint(v0[i])
            let b = worldToAnchor.transformPoint(v1[i])
            let c = worldToAnchor.transformPoint(v2[i])
            let distance = simd_length((a + b + c) / 3)
            if distance <= radius { candidates.append((distance, a, b, c)) }
        }
        if candidates.count > maxTriangles {
            candidates.sort { $0.distance < $1.distance }
            candidates.removeLast(candidates.count - maxTriangles)
        }
        return (candidates.map(\.a), candidates.map(\.b), candidates.map(\.c))
    }
}

// MARK: - Demo room

/// A procedurally painted corner of a room — wood floor, striped wallpaper, a red
/// cabinet and a checkered crate — so the paint studio can be tried without
/// scanning, and so it runs in the Simulator.
enum DemoEnvironment {

    static func makeScene(surface: SurfaceKind) -> HideScene {
        let (v0, v1, v2) = worldTriangles()
        let spot: Vec3 = surface == .floor ? [-0.08, 0, -0.12] : [-0.15, 0.62, -0.35]
        let normal: Vec3 = surface == .floor ? [0, 1, 0] : [0, 0, 1]
        let anchorToWorld = SurfaceFrame.anchorTransform(position: spot, normal: normal,
                                                         kind: surface, viewerPosition: [0, 1.3, 1.4])
        let worldToAnchor = anchorToWorld.inverse

        let local = SceneExtraction.crop(v0: v0, v1: v1, v2: v2, anchorToWorld: anchorToWorld, radius: 3)
        var environment = EnvironmentGeometry(v0: local.v0, v1: local.v1, v2: local.v2,
                                              texelsPerMeter: 300, maxDimension: 2048)
        environment.paint { point, normal in
            worldColor(anchorToWorld.transformPoint(point), anchorToWorld.transformDirection(normal))
        }

        var viewpoints: [Vec3] = []
        let base = Vec3(spot.x, 0, spot.z)
        for degrees in stride(from: -60, through: 60, by: 30) {
            let a = Float(degrees) * .pi / 180
            for height in [Float(0.75), 1.35] {
                let world = base + Vec3(sin(a) * 1.4, height, 0.25 + cos(a) * 1.4)
                viewpoints.append(worldToAnchor.transformPoint(world))
            }
        }

        return HideScene(environment: environment, anchorToWorld: anchorToWorld,
                         surface: surface, viewpoints: viewpoints, isDemo: true)
    }

    static func worldTriangles() -> ([Vec3], [Vec3], [Vec3]) {
        var a = [Vec3](), b = [Vec3](), c = [Vec3]()

        func quad(_ origin: Vec3, _ u: Vec3, _ v: Vec3, cell: Float = 0.06) {
            let nu = max(1, Int(ceil(simd_length(u) / cell)))
            let nv = max(1, Int(ceil(simd_length(v) / cell)))
            for j in 0..<nv {
                for i in 0..<nu {
                    let p00 = origin + u * (Float(i) / Float(nu)) + v * (Float(j) / Float(nv))
                    let p10 = origin + u * (Float(i + 1) / Float(nu)) + v * (Float(j) / Float(nv))
                    let p11 = origin + u * (Float(i + 1) / Float(nu)) + v * (Float(j + 1) / Float(nv))
                    let p01 = origin + u * (Float(i) / Float(nu)) + v * (Float(j + 1) / Float(nv))
                    a.append(p00); b.append(p10); c.append(p11)
                    a.append(p00); b.append(p11); c.append(p01)
                }
            }
        }

        // Floor and back wall.
        quad([-0.9, 0, 1.0], [1.8, 0, 0], [0, 0, -1.35])
        quad([-0.9, 0, -0.35], [1.8, 0, 0], [0, 1.2, 0])
        // Cabinet against the wall.
        quad([0.35, 0, -0.05], [0.4, 0, 0], [0, 0.5, 0])
        quad([0.35, 0.5, -0.05], [0.4, 0, 0], [0, 0, -0.3])
        quad([0.35, 0, -0.35], [0, 0, 0.3], [0, 0.5, 0])
        quad([0.75, 0, -0.05], [0, 0, -0.3], [0, 0.5, 0])
        // Crate.
        quad([-0.75, 0, 0.15], [0.3, 0, 0], [0, 0.22, 0], cell: 0.05)
        quad([-0.75, 0.22, 0.15], [0.3, 0, 0], [0, 0, -0.3], cell: 0.05)
        quad([-0.75, 0, -0.15], [0, 0, 0.3], [0, 0.22, 0], cell: 0.05)
        quad([-0.45, 0, 0.15], [0, 0, -0.3], [0, 0.22, 0], cell: 0.05)
        return (a, b, c)
    }

    private static func fract(_ x: Float) -> Float { x - floor(x) }

    static func worldColor(_ p: Vec3, _ n: Vec3) -> Color3 {
        let onCabinet = p.x > 0.349 && p.x < 0.751 && p.y < 0.501 && p.z > -0.351 && p.z < -0.049
        let onCrate = p.x > -0.751 && p.x < -0.449 && p.y < 0.221 && p.z > -0.151 && p.z < 0.151

        if onCrate {
            let checker = (Int(floor(p.x / 0.05)) + Int(floor(p.y / 0.05)) + Int(floor(p.z / 0.05))) & 1 == 0
            return checker ? [0.93, 0.76, 0.22] : [0.16, 0.52, 0.55]
        }
        if onCabinet {
            if n.y > 0.5 { return [0.86, 0.83, 0.76] }
            if p.y > 0.24 && p.y < 0.27 { return [0.90, 0.87, 0.80] }
            let handle = abs(p.x - 0.55) < 0.05 && abs(p.y - 0.36) < 0.012
            return handle ? [0.25, 0.22, 0.2] : [0.70, 0.22, 0.17]
        }
        if n.y > 0.5 {
            // Wooden planks running along x.
            let plankCoordinate = (p.z + 10) / 0.11
            let plank = Int(floor(plankCoordinate))
            let tones: [Color3] = [[0.55, 0.38, 0.24], [0.61, 0.43, 0.28], [0.50, 0.34, 0.21], [0.58, 0.40, 0.25]]
            var color = tones[((plank % 4) + 4) % 4]
            let grain = sin(p.x * 55 + Float(plank) * 13.7) * 0.025 + sin(p.x * 9 + Float(plank) * 3.1) * 0.02
            color += Color3(repeating: grain)
            let joint = fract((p.x + 10 + Float(plank) * 0.37) / 0.9) < 0.006
            if fract(plankCoordinate) < 0.05 || joint { color *= 0.72 }
            return color
        }
        // Wallpaper with a skirting board.
        if p.y < 0.08 { return [0.93, 0.93, 0.91] }
        if p.y < 0.09 { return [0.72, 0.72, 0.70] }
        var color: Color3 = fract((p.x + 10) / 0.12) < 0.35 ? [0.52, 0.60, 0.50] : [0.63, 0.71, 0.61]
        let cellU = fract((p.x + 10) / 0.06) - 0.5
        let cellV = fract(p.y / 0.06) - 0.5
        if (cellU * cellU + cellV * cellV).squareRoot() * 0.06 < 0.008 { color = [0.91, 0.89, 0.79] }
        return color
    }
}
