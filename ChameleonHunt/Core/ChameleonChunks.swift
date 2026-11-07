//
//  ChameleonChunks.swift
//  Hiding just the part of a chameleon that's behind something, without the glitch.
//
//  There have been two answers to "something real is in front of part of it", and both
//  were wrong in testing:
//
//   - v1: cut it per pixel against the depth map. Right in principle, but a boundary
//     drawn from a measurement good to a few centimetres crawls and flickers as the iPad
//     moves, and a flickering edge is exactly what gives a hiding place away.
//   - v4.0: never cut; fade the whole chameleon out once about a fifth of it is covered.
//     Steady, but crude: a chair leg across its middle made the whole thing vanish.
//
//  This is the middle road. The chameleon is split into chunks a few centimetres
//  across. Each chunk decides for itself, on sustained evidence, whether it's behind
//  something, and fades rather than switches. The decision is deliberately generous —
//  a chunk goes if even a quarter of it is covered, and so does its neighbour if that
//  one is mostly covered — so the cut sits a little outside the real edge, where the
//  depth noise can't reach it. And, crucially, the state lives on the chameleon, not
//  on the screen: a chunk is the same bit of chameleon whichever way the iPad moves,
//  so nothing slides or crawls. (Keeping memory per screen cell while the camera moves
//  is what broke v1.6; see the README.)
//
//  The whole-chameleon fade still sits on top (VisibilityPolicy): mostly covered, it
//  all goes, rather than leaving a sliver.
//

import Foundation
import simd

struct ChameleonChunks: Sendable {

    struct Chunk: Sendable {
        /// This chunk's quads, ready to become a mesh (same atlas as the whole chameleon).
        var buffers = RenderBuffers()
        /// Points on its surface and their normals, for testing what's in front of it.
        var samples: [Vec3] = []
        var sampleNormals: [Vec3] = []
        var centre = Vec3.zero
        /// Chunks touching this one.
        var neighbours: [Int] = []
    }

    let chunks: [Chunk]
    let cellSize: Float

    var count: Int { chunks.count }

    /// Splits the chameleon's render mesh into chunks on a grid of `cellSize` metres
    /// (character space). Every quad lands in exactly one chunk.
    static func build(_ geometry: CharacterGeometry, cellSize: Float = 0.045,
                      maximumSamples: Int = 48) -> ChameleonChunks {
        let render = geometry.render
        let quadCount = render.indices.count / 6
        var slots: [SIMD3<Int32>: Int] = [:]
        var chunks: [Chunk] = []
        var keys: [SIMD3<Int32>] = []
        var quadCentres: [[Vec3]] = []
        var quadNormals: [[Vec3]] = []

        for q in 0..<quadCount {
            let base = Int(render.indices[q * 6])
            let corners = (0..<4).map { render.positions[base + $0] }
            let centre = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
            let key = SIMD3<Int32>(Int32((centre.x / cellSize).rounded(.down)),
                                   Int32((centre.y / cellSize).rounded(.down)),
                                   Int32((centre.z / cellSize).rounded(.down)))
            let slot: Int
            if let existing = slots[key] {
                slot = existing
            } else {
                slot = chunks.count
                slots[key] = slot
                chunks.append(Chunk())
                keys.append(key)
                quadCentres.append([])
                quadNormals.append([])
            }
            let first = UInt32(chunks[slot].buffers.positions.count)
            for c in 0..<4 {
                chunks[slot].buffers.positions.append(render.positions[base + c])
                chunks[slot].buffers.normals.append(render.normals[base + c])
                chunks[slot].buffers.uvs.append(render.uvs[base + c])
            }
            chunks[slot].buffers.indices += [first, first + 1, first + 2, first, first + 2, first + 3]
            let n = render.normals[base] + render.normals[base + 1] + render.normals[base + 2] + render.normals[base + 3]
            quadCentres[slot].append(centre)
            quadNormals[slot].append(simd_length(n) > 1e-6 ? simd_normalize(n) : Vec3(0, 1, 0))
        }

        for slot in chunks.indices {
            let centres = quadCentres[slot]
            chunks[slot].centre = centres.reduce(Vec3.zero, +) / Float(max(centres.count, 1))
            let stride = max(1, centres.count / maximumSamples)
            for i in Swift.stride(from: 0, to: centres.count, by: stride) {
                chunks[slot].samples.append(centres[i])
                chunks[slot].sampleNormals.append(quadNormals[slot][i])
            }
            // Face neighbours only: diagonal ones spread the margin further than it needs to go.
            let key = keys[slot]
            let steps: [SIMD3<Int32>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
            for step in steps {
                if let other = slots[key &+ step] { chunks[slot].neighbours.append(other) }
            }
        }
        return ChameleonChunks(chunks: chunks, cellSize: cellSize)
    }

    /// For each chunk, the share of its camera-facing surface with something real at
    /// least `clearance` nearer the camera; nil when none of it faces the camera or it's
    /// off screen (nothing to say, so the chunk keeps its current state).
    /// - Parameters:
    ///   - intrinsics: fx, fy, cx, cy in depth-map pixels.
    func coverage(characterToCamera: simd_float4x4, eyeInCharacter eye: Vec3, intrinsics k: SIMD4<Float>,
                  cells: OcclusionCoverage.Cells, clearance: Float = 0.06) -> [Float?] {
        let grid = cells.grid
        return chunks.map { chunk in
            var seen = 0, covered = 0
            for (p, n) in zip(chunk.samples, chunk.sampleNormals) {
                let toEye = eye - p
                let distance = simd_length(toEye)
                guard distance > 1e-4, simd_dot(n, toEye / distance) > 0.1 else { continue }
                let c = characterToCamera.transformPoint(p)
                let z = -c.z
                guard z > 0.05 else { continue }
                let pixelX = c.x / z * k.x + k.z
                let pixelY = k.w - c.y / z * k.y
                let cell = grid.cell(atPixelX: pixelX, pixelY: pixelY)
                let column = Int(cell.x.rounded()), row = Int(cell.y.rounded())
                guard column >= 0, row >= 0, column < grid.columns, row < grid.rows else { continue }
                seen += 1
                let real = cells.nearest[row * grid.columns + column]
                if real > 0, real <= z - clearance { covered += 1 }
            }
            return seen > 0 ? Float(covered) / Float(seen) : nil
        }
    }
}

/// Which chunks of one chameleon are showing, and how much.
struct ChunkVisibility: Sendable {

    struct Settings: Sendable {
        /// A chunk goes once this much of it is covered…
        var hideAbove: Float = 0.25
        /// …or when a neighbour is this covered (cutting a little more than needed).
        var neighbourAbove: Float = 0.6
        /// …and comes back only once clearly out.
        var showBelow: Float = 0.08
        var dwellToShow: TimeInterval = 0.35
        /// Camera speed above which a chunk won't come back (see VisibilityPolicy).
        var freezeAboveMotion: Float = 0.9
        /// Quick out, gentle in.
        var fadeOutTime: Float = 0.06
        var fadeInTime: Float = 0.25
        /// A soft edge: chunks touching a hidden one fade part-way, and the ring beyond
        /// them a little, so the cut blends out instead of stepping chunk by chunk.
        var featherNear: Float = 0.45
        var featherFar: Float = 0.8
    }

    private(set) var hidden: [Bool]
    private(set) var opacity: [Float]
    /// Where each chunk's opacity is heading: 0 hidden, the feather values next to hidden
    /// chunks, 1 otherwise.
    private(set) var target: [Float]
    private var pendingSince: [TimeInterval?]
    private var lastTimestamp: TimeInterval = 0
    private let settings: Settings

    init(count: Int, settings: Settings = Settings()) {
        hidden = [Bool](repeating: false, count: count)
        opacity = [Float](repeating: 1, count: count)
        target = [Float](repeating: 1, count: count)
        pendingSince = [TimeInterval?](repeating: nil, count: count)
        self.settings = settings
    }

    var hiddenCount: Int { hidden.filter { $0 }.count }

    mutating func reset() {
        for i in hidden.indices { hidden[i] = false; opacity[i] = 1; target[i] = 1; pendingSince[i] = nil }
        lastTimestamp = 0
    }

    /// Advances the fades; call every frame. Returns the per-chunk opacities.
    @discardableResult
    mutating func advance(to timestamp: TimeInterval) -> [Float] {
        let elapsed = lastTimestamp > 0 ? Float(min(max(timestamp - lastTimestamp, 0), 0.5)) : 0
        lastTimestamp = timestamp
        guard elapsed > 0 else { return opacity }
        let stepIn = elapsed / max(settings.fadeInTime, 0.001)
        let stepOut = elapsed / max(settings.fadeOutTime, 0.001)
        for i in opacity.indices {
            let goal = target[i]
            opacity[i] = opacity[i] < goal ? min(goal, opacity[i] + stepIn) : max(goal, opacity[i] - stepOut)
        }
        return opacity
    }

    /// Feeds in a fresh coverage reading for every chunk. Chunks hide the moment they're
    /// covered, fast motion or not; they only come back once the iPad has settled and
    /// they've been clearly out for a moment (see VisibilityPolicy for why).
    mutating func update(coverage: [Float?], neighbours: [[Int]], motion: Float, timestamp: TimeInterval) {
        guard coverage.count == hidden.count else { return }
        let moving = motion > settings.freezeAboveMotion
        for i in hidden.indices {
            let own = coverage[i]
            let neighbourMax = neighbours[i].compactMap { coverage[$0] }.max() ?? 0
            let wanted: Bool
            if hidden[i] {
                // Stay hidden until both it and its neighbours are clearly out.
                if let own {
                    wanted = own > settings.showBelow || neighbourMax >= settings.neighbourAbove
                } else {
                    wanted = neighbourMax >= settings.neighbourAbove
                }
            } else {
                wanted = (own ?? 0) > settings.hideAbove || neighbourMax >= settings.neighbourAbove
            }
            if wanted == hidden[i] {
                pendingSince[i] = nil
            } else if wanted {
                hidden[i] = true
                pendingSince[i] = nil
            } else if moving {
                pendingSince[i] = nil
            } else if let since = pendingSince[i] {
                if timestamp - since >= settings.dwellToShow {
                    hidden[i] = false
                    pendingSince[i] = nil
                }
            } else {
                pendingSince[i] = timestamp
            }
        }
        feather(neighbours: neighbours)
    }

    /// Sets each chunk's target from how many steps it is from a hidden one.
    private mutating func feather(neighbours: [[Int]]) {
        var steps = [Int](repeating: Int.max, count: hidden.count)
        var ring: [Int] = []
        for i in hidden.indices where hidden[i] { steps[i] = 0; ring.append(i) }
        for distance in 1...2 {
            var next: [Int] = []
            for i in ring {
                for j in neighbours[i] where steps[j] == Int.max {
                    steps[j] = distance
                    next.append(j)
                }
            }
            ring = next
        }
        for i in target.indices {
            switch steps[i] {
            case 0: target[i] = 0
            case 1: target[i] = settings.featherNear
            case 2: target[i] = settings.featherFar
            default: target[i] = 1
            }
        }
    }
}
