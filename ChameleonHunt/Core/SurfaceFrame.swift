//
//  SurfaceFrame.swift
//  Decides whether a LiDAR hit is a floor or a wall, and builds the "hide anchor"
//  coordinate frame the character, the scan crop and the paint all live in.
//

import simd

enum SurfaceKind: String, Sendable {
    case floor
    case wall

    var displayName: String { self == .floor ? "Floor" : "Wall" }
    var systemImage: String { self == .floor ? "square.bottomthird.inset.filled" : "square.leadingthird.inset.filled" }
}

enum SurfaceFrame {

    /// Classifies a surface normal. Returns nil for ceilings and steep slopes,
    /// where none of the poses would look right.
    static func classify(normal: Vec3) -> SurfaceKind? {
        if normal.y > 0.8 { return .floor }
        if abs(normal.y) < 0.3 { return .wall }
        return nil
    }

    /// Hide-anchor frame: origin on the surface, +Y along the surface normal.
    ///  - Floor: +Z points toward the viewer, so a standing figure faces the hider.
    ///  - Wall:  +Z points up the wall, so a clinging figure's head is up.
    static func anchorTransform(position: Vec3, normal rawNormal: Vec3,
                                kind: SurfaceKind, viewerPosition: Vec3) -> simd_float4x4 {
        let y = simd_normalize(rawNormal)
        var z: Vec3
        switch kind {
        case .floor:
            let toViewer = viewerPosition - position
            z = toViewer - y * simd_dot(toViewer, y)
        case .wall:
            let up: Vec3 = [0, 1, 0]
            z = up - y * simd_dot(up, y)
        }
        z = simd_length(z) > 1e-4 ? simd_normalize(z) : anyPerpendicular(to: y)
        let x = simd_normalize(simd_cross(y, z))
        z = simd_cross(x, y)
        return simd_float4x4(xAxis: x, yAxis: y, zAxis: z, origin: position)
    }

    /// Rotation about the surface normal, for turning the character on the spot.
    static func yaw(_ radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: [0, 1, 0]))
    }

    /// How far the character floats off the scanned surface. LiDAR meshes are
    /// noisy by a centimeter or so; this keeps the surface from poking through.
    static let surfaceOffset: Float = 0.006
}
