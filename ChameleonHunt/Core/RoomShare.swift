//
//  RoomShare.swift
//  A LiDAR device's map of the room, packed small enough to send to the phones that
//  don't have LiDAR.
//
//  In a squad where only some devices have LiDAR, one of them (SquadRules.roomSupport)
//  maps the room and shares it. The others use the map for two things they can't do by
//  themselves: hiding a chameleon on any surface — not just the flat ones ARKit finds —
//  and having furniture hide chameleons from them. The map is a triangle soup around a
//  shared ARAnchor, so each device can put it in its own coordinates.
//
//  Packed as millimetres in 16 bits (±32 m, far more than a room) and compressed; a
//  room's worth is a few hundred kilobytes.
//

import Foundation
import simd

struct RoomMesh: Sendable {
    /// The shared ARAnchor the triangles are relative to.
    var anchor: UUID
    var v0: [Vec3]
    var v1: [Vec3]
    var v2: [Vec3]

    var triangleCount: Int { v0.count }
}

enum RoomShare {

    /// Enough for a well-mapped living room; the nearest ones are kept when there are more.
    static let maximumTriangles = 60_000
    private static let magic: UInt32 = 0x524F_4F4D // "ROOM"

    /// Packs triangles already in the anchor's coordinates. Keeps the ones nearest the
    /// anchor if there are too many.
    static func encode(_ mesh: RoomMesh) -> Data? {
        var order = Array(0..<mesh.triangleCount)
        if order.count > maximumTriangles {
            let distance = { (i: Int) in simd_length_squared((mesh.v0[i] + mesh.v1[i] + mesh.v2[i]) / 3) }
            order.sort { distance($0) < distance($1) }
            order = Array(order.prefix(maximumTriangles))
        }
        var raw = Data()
        raw.reserveCapacity(24 + order.count * 18)
        append(magic, to: &raw)
        withUnsafeBytes(of: mesh.anchor.uuid) { raw.append(contentsOf: $0) }
        append(UInt32(order.count), to: &raw)
        for i in order {
            for p in [mesh.v0[i], mesh.v1[i], mesh.v2[i]] {
                for c in 0..<3 {
                    let millimetres = Int16(clamping: Int((p[c] * 1000).rounded()))
                    append(millimetres, to: &raw)
                }
            }
        }
        return try? (raw as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) -> RoomMesh? {
        guard let raw = try? (data as NSData).decompressed(using: .lzfse) as Data, raw.count >= 24 else { return nil }
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
            let value = raw.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }
        guard read(UInt32.self) == magic else { return nil }
        let uuidBytes = raw.subdata(in: offset..<offset + 16)
        offset += 16
        let anchor = uuidBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        guard let count = read(UInt32.self), Int(count) <= maximumTriangles,
              raw.count >= offset + Int(count) * 18 else { return nil }
        var mesh = RoomMesh(anchor: anchor, v0: [], v1: [], v2: [])
        mesh.v0.reserveCapacity(Int(count)); mesh.v1.reserveCapacity(Int(count)); mesh.v2.reserveCapacity(Int(count))
        func point() -> Vec3 {
            Vec3(Float(read(Int16.self) ?? 0), Float(read(Int16.self) ?? 0), Float(read(Int16.self) ?? 0)) / 1000
        }
        for _ in 0..<Int(count) {
            mesh.v0.append(point()); mesh.v1.append(point()); mesh.v2.append(point())
        }
        return mesh
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

extension ChameleonChunks {
    /// Coverage per chunk from a shared room map instead of this device's own depth
    /// sensor: a sample counts as covered when the map has something between it and the
    /// eye (more than `clearance` in front of it). Up to `samplesPerChunk` samples each,
    /// to keep the ray count down.
    ///
    /// The surface it's standing on never counts. Without LiDAR the floor or table under a
    /// chameleon is a flat surface ARKit estimated, often a centimetre or two off the
    /// height it was placed at; seen from low down, a table "above" its feet used to cover
    /// most of it — and "mostly covered" hides all of it. In testing, one hidden on a phone
    /// without LiDAR vanished for everyone, its hider included. So hits on a thin band
    /// around its base, near it, are stepped past.
    func coverage(characterToWorld: simd_float4x4, eye: Vec3, room: TriangleBVH,
                  clearance: Float = 0.06, samplesPerChunk: Int = 4) -> [Float?] {
        let worldToCharacter = characterToWorld.inverse
        let eyeInCharacter = worldToCharacter.transformPoint(eye)
        let support = supportRegion(characterToWorld: characterToWorld)
        return chunks.map { chunk in
            var seen = 0, covered = 0
            let step = max(1, chunk.samples.count / samplesPerChunk)
            for k in stride(from: 0, to: chunk.samples.count, by: step) {
                let p = chunk.samples[k]
                let toEye = eyeInCharacter - p
                guard simd_length(toEye) > 1e-4, simd_dot(chunk.sampleNormals[k], simd_normalize(toEye)) > 0.1 else { continue }
                let world = characterToWorld.transformPoint(p)
                let ray = world - eye
                let distance = simd_length(ray)
                guard distance > clearance + 0.05 else { continue }
                seen += 1
                let direction = ray / distance
                var tMin: Float = 0.05
                // At most a couple of support hits to step past (floor, then a rug on it).
                for _ in 0..<3 {
                    guard let hit = room.intersect(origin: eye, direction: direction, tMin: tMin, tMax: distance - clearance) else { break }
                    if support.contains(worldToCharacter.transformPoint(eye + direction * hit.t)) {
                        tMin = hit.t + 0.002
                        continue
                    }
                    covered += 1
                    break
                }
            }
            return seen > 0 ? Float(covered) / Float(seen) : nil
        }
    }

    /// The patch of surface a chameleon stands on, in its own coordinates: a thin band
    /// (5 cm either side, in real size) around its lowest point, reaching a little past
    /// its footprint.
    struct SupportRegion: Sendable {
        var base: Float
        var band: Float
        var centre: SIMD2<Float>
        var reach: Float

        func contains(_ p: Vec3) -> Bool {
            let d = SIMD2<Float>(p.x, p.z) - centre
            return abs(p.y - base) < band && simd_length_squared(d) < reach * reach
        }
    }

    func supportRegion(characterToWorld: simd_float4x4) -> SupportRegion {
        var lowest = Float.greatestFiniteMagnitude
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for chunk in chunks {
            for p in chunk.samples {
                lowest = min(lowest, p.y)
                lo = simd_min(lo, SIMD2(p.x, p.z))
                hi = simd_max(hi, SIMD2(p.x, p.z))
            }
        }
        // World metres per unit of the chameleon's own coordinates.
        let scale = max(simd_length(SIMD3<Float>(characterToWorld.columns.0.x, characterToWorld.columns.0.y,
                                                  characterToWorld.columns.0.z)), 1e-4)
        let centre = (lo + hi) / 2
        return SupportRegion(base: lowest, band: 0.05 / scale, centre: centre,
                             reach: simd_length(hi - lo) / 2 * 1.6 + 0.05 / scale)
    }
}
