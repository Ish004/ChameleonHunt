//
//  coretest/main.swift
//  The guardrails for everything in Core/ that can be checked without an iPad.
//
//  Lives in the repo rather than a scratch folder because it has been lost once already,
//  and because each of these tests is a bug that actually happened: the occluder eating
//  the character, the visibility policy strobing and blinking, the spot search refusing to find a
//  spot from a new angle. Run with Tools/build.sh, then Tools/build/coretest.
//

import Foundation
import simd

final class Failures: @unchecked Sendable { var count = 0 }
let failures = Failures()

func check(_ condition: Bool, _ message: String) {
    if condition { print("  ✅ \(message)") } else { failures.count += 1; print("  ❌ FAIL: \(message)") }
}

func section(_ title: String) { print("\n== \(title) ==") }

// MARK: - The chameleon

section("The chameleon's shapes")
do {
    for pose in CharacterPose.allCases {
        let shape = CharacterShape.build(pose)
        let mesh = shape.mesh
        let lo = mesh.positions.reduce(Vec3(repeating: .greatestFiniteMagnitude), simd_min)
        let hi = mesh.positions.reduce(Vec3(repeating: -.greatestFiniteMagnitude), simd_max)
        let size = hi - lo
        print(String(format: "  %@: %d quads, %.0f x %.0f x %.0f cm",
                     pose.rawValue, mesh.quads.count, size.x * 100, size.y * 100, size.z * 100))

        check(mesh.quads.count > 800, "\(pose.rawValue): polygonizes into a real surface")
        check(lo.y > -0.002 && lo.y < 0.01, "\(pose.rawValue): sits on the surface it's placed on")
        // A chameleon is longer than it is wide, and narrow across the body. This is
        // what stops it drifting back towards the barrel-shaped mammal it started as.
        check(size.z > size.x, "\(pose.rawValue): longer nose-to-tail than it is wide")
        check(size.x < 0.30, "\(pose.rawValue): stays narrow across the body")

        // The mesh has to be a closed surface, or the paint atlas has holes in it and
        // the occlusion stand-in leaks. Checking |distance| at each vertex would be the
        // obvious alternative and it's the wrong test: the parts are squashed per axis,
        // so the field is scaled differently in different directions and isn't a
        // Euclidean distance — only its zero set is exact. Watertightness is structural,
        // and it is what the rest of the pipeline actually depends on.
        var edges: [Int64: Int] = [:]
        for quad in mesh.quads {
            for e in 0..<4 {
                let a = Int64(quad[e]), b = Int64(quad[(e + 1) % 4])
                edges[min(a, b) << 32 | max(a, b), default: 0] += 1
            }
        }
        // Surface nets leaves a handful of non-manifold edges where a feature is
        // hairline-thin — the crest fin is about four millimetres thick against a five
        // millimetre grid. A few out of ten thousand is the known cost of that and
        // harms nothing downstream; hundreds would mean the shape had broken.
        let open = edges.values.filter { $0 != 2 }.count
        let share = Double(open) / Double(max(edges.count, 1))
        check(share < 0.002, "\(pose.rawValue): effectively closed (\(open) odd edges of \(edges.count))")
    }

    // The poses have to look different from each other, or the pose picker is a lie.
    let standing = CharacterShape.build(.standing).mesh
    let curled = CharacterShape.build(.curled).mesh
    func height(_ mesh: QuadMesh) -> Float {
        mesh.positions.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.y) }
    }
    check(height(standing) > height(curled) * 1.35, "perched stands well clear of curled up")
}

section("Turning it on the spot")
do {
    for (name, normal) in [("floor", Vec3(0, 1, 0)), ("wall", simd_normalize(Vec3(0.2, 0.05, 1)))] {
        let kind: SurfaceKind = name == "floor" ? .floor : .wall
        let position = Vec3(0.3, 0.9, -1.2)
        let base = SurfaceFrame.anchorTransform(position: position, normal: normal, kind: kind,
                                                viewerPosition: [0, 1.4, 0])
        for degrees in [Float(35), -110, 179] {
            let turned = base * SurfaceFrame.yaw(degrees * .pi / 180)
            let moved = simd_distance(turned.translation, position)
            let drift = acos(min(1, abs(simd_dot(simd_normalize(turned.yAxis), simd_normalize(base.yAxis))))) * 180 / .pi
            let swept = acos(min(1, max(-1, simd_dot(simd_normalize(turned.zAxis), simd_normalize(base.zAxis))))) * 180 / .pi
            check(moved < 1e-5 && drift < 0.05 && abs(swept - abs(degrees)) < 0.5,
                  "\(name): \(Int(degrees))° spins about the surface normal")
        }
    }
}

section("The chameleon as a picture")
do {
    for pose in CharacterPose.allCases {
        let image = MascotRenderer.render(pose, view: .hero, size: 240)
        let w = image.width, h = image.height
        var covered = 0, edge = 0, pupil = 0, sclera = 0, green = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
                let a = Int(image.pixels[i + 3])
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1) && a > 0 { edge += 1 }
                guard a > 250 else { continue }
                covered += 1
                if r < 45 && g < 45 && b < 45 { pupil += 1 }
                if r > 225 && g > 225 && b > 215 { sclera += 1 }
                if g > r + 30 && g > b + 30 { green += 1 }
            }
        }
        let share = Float(covered) / Float(w * h)
        check(share > 0.12 && share < 0.7, "\(pose.rawValue): fills the frame sensibly (\(Int(share * 100))%)")
        check(edge == 0, "\(pose.rawValue): nothing clipped at the edges")
        check(green > covered / 2, "\(pose.rawValue): it's green")
        check(pupil > 20 && sclera > 20, "\(pose.rawValue): you can see its eyes")
    }
}

// MARK: - Occlusion

section("Hidden or shown")
do {
    var rng = SystemRandomNumberGenerator()
    func run(_ coverage: [Float], motion: [Float]? = nil)
        -> (states: [VisibilityPolicy.State], opacity: [Float], changes: Int) {
        var policy = VisibilityPolicy()
        var states: [VisibilityPolicy.State] = [], opacity: [Float] = []
        var changes = 0
        for (i, value) in coverage.enumerated() {
            opacity.append(policy.update(coverage: value, motion: motion?[i] ?? 0, timestamp: Double(i + 1) / 30))
            if let last = states.last, last != policy.state { changes += 1 }
            states.append(policy.state)
        }
        return (states, opacity, changes)
    }

    var nibbling = [Float]()
    for i in 0..<90 { nibbling.append(i % 17 == 0 ? 0.34 : Float.random(in: 0...0.05, using: &rng)) }
    let nibble = run(nibbling)
    check(nibble.opacity.allSatisfy { $0 == 1 }, "noise at the silhouette never touches it")

    var walkPast = [Float]()
    for i in 0..<60 { walkPast.append(Float(i) / 59) }
    for i in 0..<60 { walkPast.append(1 - Float(i) / 59) }
    let clearAt = walkPast.count
    walkPast.append(contentsOf: [Float](repeating: 0, count: 45))
    let walk = run(walkPast)
    check(walk.states.contains(.hidden), "someone walking in front of it hides it")
    check(walk.states.last == .shown, "and it comes back once they've moved on")
    let backAt = walk.states[clearAt...].firstIndex(of: .shown).map { $0 - clearAt } ?? 999
    check(backAt <= 30, "within a second (\(String(format: "%.2f", Double(backAt) / 30)) s)")
    check(walk.changes == 2, "one fade out, one fade in (\(walk.changes) changes)")
    let steps = zip(walk.opacity, walk.opacity.dropFirst()).map { $1 - $0 }
    check(steps.filter { $0 > 0 }.allSatisfy { $0 <= 0.13 }, "it fades back in gently, never pops in")
    let hideAt = walk.states.firstIndex(of: .hidden) ?? 0
    let goneAt = walk.opacity[hideAt...].firstIndex(where: { $0 == 0 }).map { $0 - hideAt } ?? 999
    check(goneAt <= 3, "and goes almost at once — gone within \(goneAt) frames of being covered")

    // A quick sweep past something: covered for a fifth of a second mid-swing.
    var sweep = [Float](repeating: 0, count: 90), sweepMotion = [Float](repeating: 0.1, count: 90)
    for i in 30..<36 { sweep[i] = 0.95 }
    for i in 26..<40 { sweepMotion[i] = 1.8 }
    let swept = run(sweep, motion: sweepMotion)
    let sweptHidden = swept.states.firstIndex(of: .hidden).map { $0 - 30 } ?? 999
    check(sweptHidden <= 1, "a quick sweep behind something hides it at once, mid-swing (\(sweptHidden) frames)")

    // What used to happen in testing: a burst of bad depth while the iPad swings round.
    var swing = [Float](repeating: 0, count: 120), motion = [Float](repeating: 0.1, count: 120)
    for i in 30..<48 { swing[i] = Float.random(in: 0.2...1, using: &rng); motion[i] = 1.6 }
    let swung = run(swing, motion: motion)
    check(swung.changes <= 2, "bad depth during a swing hides it at most once — no flicker (\(swung.changes) changes)")
    check(swung.states.last == .shown, "and it's back once the iPad settles")

    var tableEdge = [Float]()
    for i in 0..<150 { tableEdge.append(i < 20 ? 0 : 0.3 + Float.random(in: -0.04...0.04, using: &rng)) }
    check(run(tableEdge).states.last == .shown, "a third behind something leaves the rest showing (its chunks fade instead)")
    var mostly = [Float]()
    for i in 0..<150 { mostly.append(i < 20 ? 0 : 0.75 + Float.random(in: -0.04...0.04, using: &rng)) }
    check(run(mostly).states.last == .hidden, "mostly behind something, all of it goes rather than a sliver")

    var onTheEdge = [Float]()
    for _ in 0..<150 { onTheEdge.append(0.5 + Float.random(in: -0.07...0.07, using: &rng)) }
    check(run(onTheEdge).changes <= 1, "sitting on a threshold doesn't strobe")
}

section("How much of it is behind something")
do {
    let W = 256, H = 192
    let k = SIMD4<Float>(210, 210, 128, 96)
    var rng = SystemRandomNumberGenerator()

    func room(withTable: Bool) -> TriangleBVH {
        var v0: [Vec3] = [], v1: [Vec3] = [], v2: [Vec3] = []
        func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) { v0 += [a, a]; v1 += [b, c]; v2 += [c, d] }
        quad([-4, 0, 2], [4, 0, 2], [4, 0, -5], [-4, 0, -5])                                    // floor
        if withTable {
            quad([-1.2, 0.73, -0.2], [1.2, 0.73, -0.2], [1.2, 0.73, -1.8], [-1.2, 0.73, -1.8]) // table top
        }
        quad([-2.5, 0, -2.2], [2.5, 0, -2.2], [2.5, 2.2, -2.2], [-2.5, 2.2, -2.2])              // far wall
        return TriangleBVH(v0: v0, v1: v1, v2: v2)
    }

    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing))
    let characterToWorld = simd_float4x4(translation: [0, 0, -1.0])

    func coverage(in scene: TriangleBVH, frames: Int) -> [Float] {
        var result: [Float] = []
        for frame in 0..<frames {
            let eye = Vec3(0.05 * sin(Float(frame) * 0.2), 1.45, 0.25 + 0.01 * Float(frame))
            let forward = simd_normalize(Vec3(0, 0.15, -1.0) - eye)
            let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
            let cam = simd_float4x4(xAxis: right, yAxis: simd_cross(right, forward), zAxis: -forward, origin: eye)
            let worldToCam = cam.inverse
            var depth = [Float32](repeating: 0, count: W * H)
            for v in 0..<H {
                for u in 0..<W {
                    let dir = simd_normalize(cam.transformDirection(
                        Vec3((Float(u) + 0.5 - k.z) / k.x, -(Float(v) + 0.5 - k.w) / k.y, -1)))
                    guard let hit = scene.intersect(origin: eye, direction: dir) else { continue }
                    depth[v * W + u] = -worldToCam.transformPoint(eye + dir * hit.t).z
                        + Float.random(in: -0.015...0.015, using: &rng)
                }
            }
            let cells = depth.withUnsafeBufferPointer {
                OcclusionCoverage.sample(depth: $0, width: W, height: H, stride: W)
            }
            let mask = CharacterMask.build(mesh: geometry.mask, characterToCamera: worldToCam * characterToWorld,
                                           intrinsics: k, grid: cells.grid)
            result.append(OcclusionCoverage.coverage(of: mask, in: cells))
        }
        return result
    }

    let under = coverage(in: room(withTable: true), frames: 12)
    print(String(format: "  under a table, looking down: %.2f covered", under.last!))
    check(under.allSatisfy { $0 > 0.9 }, "a table top over it reads as fully covered, every frame")

    let open = coverage(in: room(withTable: false), frames: 12)
    print(String(format: "  on the open floor: %.2f covered at most", open.max()!))
    check(open.allSatisfy { $0 < 0.05 }, "the floor it stands on never counts as covering it")

    var policy = VisibilityPolicy()
    var hiddenAt: Double = 99
    for (i, value) in (under + under + under).enumerated() {
        policy.update(coverage: value, timestamp: Double(i + 1) / 30)
        if policy.state == .hidden { hiddenAt = Double(i + 1) / 30; break }
    }
    check(hiddenAt <= 0.4, "under the table it's gone within a moment (\(String(format: "%.2f", hiddenAt)) s)")
}

section("Hiding just the covered part")
do {
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let chunks = ChameleonChunks.build(geometry)
    let quadCount = geometry.render.indices.count / 6
    let chunkQuads = chunks.chunks.reduce(0) { $0 + $1.buffers.indices.count / 6 }
    print("  \(chunks.count) chunks")
    check(chunkQuads == quadCount, "every bit of the chameleon is in exactly one chunk")
    check(chunks.count >= 12 && chunks.count <= 120, "chunks a few centimetres across (\(chunks.count))")
    check(chunks.chunks.allSatisfy { !$0.neighbours.isEmpty }, "every chunk knows its neighbours")

    // A camera looking at it side-on from 1 m, and a wall of depth that covers the left
    // half of the picture 40 cm in front of it: the left chunks go, the right ones stay.
    let W = 256, H = 192
    let k = SIMD4<Float>(210, 210, 128, 96)
    let characterToWorld = simd_float4x4(translation: [0, 0, -1.0])
    let eye = Vec3(0, 0.1, 0)
    let forward = simd_normalize(Vec3(0, 0.08, -1) - eye)
    let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
    let cam = simd_float4x4(xAxis: right, yAxis: simd_cross(right, forward), zAxis: -forward, origin: eye)
    var depth = [Float32](repeating: 3, count: W * H)
    for v in 0..<H { for u in 0..<(W / 2) { depth[v * W + u] = 0.6 } }
    let cells = depth.withUnsafeBufferPointer { OcclusionCoverage.sample(depth: $0, width: W, height: H, stride: W) }
    let characterToCamera = cam.inverse * characterToWorld
    let eyeInCharacter = characterToWorld.inverse.transformPoint(eye)
    let coverage = chunks.coverage(characterToCamera: characterToCamera, eyeInCharacter: eyeInCharacter,
                                   intrinsics: k, cells: cells)
    var visibility = ChunkVisibility(count: chunks.count)
    for frame in 0..<20 {
        let t = Double(frame + 1) / 30
        visibility.update(coverage: coverage, neighbours: chunks.chunks.map(\.neighbours), motion: 0, timestamp: t)
        visibility.advance(to: t)
    }
    var leftHidden = 0, leftSeen = 0, rightHidden = 0, rightSeen = 0
    for (i, chunk) in chunks.chunks.enumerated() where coverage[i] != nil {
        let x = characterToCamera.transformPoint(chunk.centre).x
        if x < -0.03 { leftSeen += 1; if visibility.hidden[i] { leftHidden += 1 } }
        if x > 0.03 { rightSeen += 1; if visibility.hidden[i] { rightHidden += 1 } }
    }
    print("  left half: \(leftHidden) of \(leftSeen) chunks faded · right half: \(rightHidden) of \(rightSeen)")
    check(leftSeen > 0 && leftHidden == leftSeen, "everything behind the wall fades out")
    check(rightSeen > 0 && rightHidden * 3 <= rightSeen, "the part in the open mostly stays")
    check(zip(visibility.opacity, visibility.target).allSatisfy { $0 == $1 }, "after a moment every chunk has settled")
    let neighbours = chunks.chunks.map(\.neighbours)
    let softEdge = visibility.opacity.indices.filter { visibility.opacity[$0] > 0 && visibility.opacity[$0] < 1 }
    check(!softEdge.isEmpty && softEdge.allSatisfy { i in
        neighbours[i].contains { visibility.hidden[$0] } || neighbours[i].contains { j in neighbours[j].contains { visibility.hidden[$0] } }
    }, "the only part-faded chunks are the soft edge right next to the cut (\(softEdge.count))")
    let nearEdge = visibility.opacity.indices.filter { i in !visibility.hidden[i] && neighbours[i].contains { visibility.hidden[$0] } }
    check(nearEdge.allSatisfy { visibility.opacity[$0] < visibility.opacity.indices.filter { j in
        !visibility.hidden[j] && !neighbours[j].contains { visibility.hidden[$0] } }.map { visibility.opacity[$0] }.max() ?? 1 },
          "the edge fades out gradually: next to the cut is fainter than further away")
    var quick = ChunkVisibility(count: chunks.count)
    quick.update(coverage: coverage, neighbours: neighbours, motion: 0, timestamp: 1.0 / 30)
    quick.advance(to: 1.0 / 30); quick.advance(to: 2.0 / 30); quick.advance(to: 3.0 / 30)
    check(quick.opacity.indices.filter { quick.hidden[$0] }.allSatisfy { quick.opacity[$0] == 0 },
          "the covered part is still gone within a couple of frames")

    var swinging = ChunkVisibility(count: chunks.count)
    swinging.update(coverage: coverage, neighbours: chunks.chunks.map(\.neighbours), motion: 1.8, timestamp: 1.0 / 30)
    check(swinging.hiddenCount >= leftHidden, "mid-swing, the covered chunks go on the very first reading")
    let clear = [Float?](repeating: 0, count: chunks.count)
    for frame in 1..<30 {
        swinging.update(coverage: clear, neighbours: chunks.chunks.map(\.neighbours), motion: 1.8,
                        timestamp: Double(frame + 1) / 30)
    }
    check(swinging.hiddenCount >= leftHidden, "and none come back while it's still swinging")
    for frame in 30..<60 {
        swinging.update(coverage: clear, neighbours: chunks.chunks.map(\.neighbours), motion: 0.1,
                        timestamp: Double(frame + 1) / 30)
    }
    check(swinging.hiddenCount == 0, "they come back once it settles and the way is clear")
}

// MARK: - Camouflage

section("Living camouflage")
do {
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let white = [UInt8](repeating: 240, count: geometry.atlasWidth * geometry.atlasHeight * 4)
    let skin = LiveSkin(geometry: geometry, base: white)
    let W = 320, H = 240
    var red = [UInt8](repeating: 255, count: W * H * 4)
    for i in stride(from: 0, to: red.count, by: 4) { red[i] = 200; red[i + 1] = 60; red[i + 2] = 50 }
    let eye = Vec3(0, 0.25, 0.45)
    let forward = simd_normalize(Vec3(0, 0.05, 0) - eye)
    let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
    let cam = simd_float4x4(xAxis: right, yAxis: simd_cross(right, forward), zAxis: -forward, origin: eye)
    func frame(depth: Float) -> Keyframe {
        Keyframe(width: W, height: H, rgba: red, intrinsics: [260, 260, 160, 120], cameraToWorld: cam,
                 depthWidth: 64, depthHeight: 48, depth: [Float](repeating: depth, count: 64 * 48))
    }
    var settings = LiveSkin.Settings()
    settings.strength = 1
    // Something right in front of the lens: whatever the camera sees is that, not the room.
    check(skin.update(from: frame(depth: 0.15), characterToWorld: matrix_identity_float4x4, settings: settings) == 0,
          "doesn't take colour from something in front of it")
    var seen = 0
    for _ in 0..<6 { seen = skin.update(from: frame(depth: 3), characterToWorld: matrix_identity_float4x4, settings: settings) }
    check(seen > 1000, "sees plenty of itself from the front (\(seen) texels)")
    var reddish = 0
    for texel in geometry.validTexels {
        let i = Int(texel) * 4
        if skin.composed[i] > 150, skin.composed[i + 1] < 140 { reddish += 1 }
    }
    check(reddish * 10 >= seen * 9, "everything it can see turns the room's colour (\(reddish) of \(seen))")
    check(reddish * 10 <= geometry.validTexels.count * 6, "and the side it can't see keeps its paint")

    // The tell only changes what's drawn: the match underneath is kept, and comes back.
    settings.tell = 0.04
    skin.update(from: frame(depth: 3), characterToWorld: matrix_identity_float4x4, settings: settings)
    let told = skin.composed
    skin.setTell(0)
    let matched = skin.composed
    var darker = 0, counted = 0
    for texel in geometry.validTexels {
        let i = Int(texel) * 4
        counted += 1
        if Int(told[i]) <= Int(matched[i]) - 8 { darker += 1 }
    }
    check(counted > 0 && darker * 10 >= counted * 9, "with a tell, it's drawn a little off the match (\(darker) of \(counted) texels)")
    skin.setTell(0.04)
    let toldAgain = skin.composed
    skin.setTell(0)
    check(toldAgain == told && skin.composed == matched && skin.base == white, "and without it, exactly the match again: the paint is untouched")

    // Catching up: how many updates until what it can see has (nearly) taken on a new view.
    func updatesToCatchUp(_ difficulty: HuntDifficulty) -> Int {
        func turned(_ skin: LiveSkin) -> Int {
            geometry.validTexels.reduce(0) { $0 + (skin.composed[Int($1) * 4 + 1] < 100 ? 1 : 0) }
        }
        var s = LiveSkin.Settings()
        s.strength = 0.9
        s.adaptRate = difficulty.adaptRate
        let settled = LiveSkin(geometry: geometry, base: white)
        for _ in 0..<25 { settled.update(from: frame(depth: 3), characterToWorld: matrix_identity_float4x4, settings: s) }
        let all = turned(settled)
        let fresh = LiveSkin(geometry: geometry, base: white)
        for n in 1...25 {
            fresh.update(from: frame(depth: 3), characterToWorld: matrix_identity_float4x4, settings: s)
            if turned(fresh) * 10 >= all * 9 { return n }
        }
        return 99
    }
    let easySteps = updatesToCatchUp(.easy), hardSteps = updatesToCatchUp(.hard)
    print(String(format: "  updates to take on a new view: Easy %d (%.1f s), Hard %d (%.1f s)",
                 easySteps, Double(easySteps) * HuntDifficulty.easy.refreshInterval,
                 hardSteps, Double(hardSteps) * HuntDifficulty.hard.refreshInterval))
    check(hardSteps < easySteps && hardSteps <= 3, "a Hard chameleon catches up with what's behind it much sooner")
}

section("The chameleon in its own colours")
do {
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let paint = ToyPaint.pixels(for: geometry)
    var green = 0, dark = 0, light = 0
    for texel in geometry.validTexels {
        let i = Int(texel) * 4
        let r = Int(paint[i]), g = Int(paint[i + 1]), b = Int(paint[i + 2])
        if g > r + 25, g > b + 25 { green += 1 }
        if r < 50, g < 50, b < 50 { dark += 1 }
        if r > 200, g > 200, b > 190 { light += 1 }
    }
    let total = geometry.validTexels.count
    check(geometry.eyes.count == 2, "the game's mesh knows where its eyes are")
    check(green > total / 2, "it's green (\(green * 100 / total)%)")
    check(dark > 100 && light > 100, "with eyes you can see (\(dark) pupil, \(light) white texels)")
}

section("Magic camouflage reaches the bottom")
do {
    let scene = DemoEnvironment.makeScene(surface: .floor)
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let offset = Vec3(0, SurfaceFrame.surfaceOffset, 0)
    let scanOnly = scene.viewpoints.map { Camouflage.Viewpoint(eye: $0, weight: 1) }
    let everyone = Camouflage.seekerViewpoints(scanned: scene.viewpoints)
    var lowerSides = 0, bareBefore = 0, bareNow = 0
    for texel in geometry.validTexels {
        let t = Int(texel)
        let position = geometry.texelPositions[t], normal = geometry.texelNormals[t]
        // The lower half of its sides, facing outwards and a bit down.
        guard position.y < 0.035, normal.y < 0.2, simd_length(Vec2(normal.x, normal.z)) > 0.5 else { continue }
        lowerSides += 1
        let before = scanOnly.contains { simd_dot(normal, simd_normalize($0.eye - (position + offset))) > 0.05 }
        if !before { bareBefore += 1 }
        if Camouflage.autoColor(point: position + offset, normal: normal, viewpoints: everyone,
                                environment: scene.environment) == nil { bareNow += 1 }
    }
    print("  \(lowerSides) texels on the lower sides; the scan alone never saw \(bareBefore)")
    check(lowerSides > 500, "there is a lower side to test")
    check(bareNow * 100 <= lowerSides, "every one of them gets painted now (\(bareNow) left bare)")

    // The whole-body pass: bottom edge into the floor, speckle smoothed, edges kept.
    let raw = geometry.validTexels.map { texel -> Color3? in
        let t = Int(texel)
        return Camouflage.autoColor(point: geometry.texelPositions[t] + offset, normal: geometry.texelNormals[t],
                                    viewpoints: everyone, environment: scene.environment)
    }
    let painted = Camouflage.paintAll(geometry: geometry, scale: 1, viewpoints: everyone, environment: scene.environment)
    var bottomBefore: Float = 0, bottomAfter: Float = 0, bottomCount = 0
    for (k, texel) in geometry.validTexels.enumerated() {
        let t = Int(texel)
        let position = geometry.texelPositions[t]
        guard position.y < 0.008, let before = raw[k], let after = painted[t],
              let floor = Camouflage.surfaceColor(beside: position + offset, normal: geometry.texelNormals[t],
                                                  environment: scene.environment) else { continue }
        bottomBefore += simd_distance(before, floor); bottomAfter += simd_distance(after, floor); bottomCount += 1
    }
    print(String(format: "  bottom edge vs the floor beside it: %.3f before, %.3f now", bottomBefore / Float(max(bottomCount, 1)),
                 bottomAfter / Float(max(bottomCount, 1))))
    check(bottomCount > 100 && bottomAfter < bottomBefore * 0.6, "the bottom edge sits into the floor instead of drawing a line")

    // Speckle: how far each texel is from its neighbours, before and after smoothing. A
    // noisy copy of the paint stands in for a noisy scan.
    var rng = SystemRandomNumberGenerator()
    var noisy = [Color3?](repeating: nil, count: geometry.atlasWidth * geometry.atlasHeight)
    for (k, texel) in geometry.validTexels.enumerated() {
        noisy[Int(texel)] = raw[k].map { simd_clamp($0 + Color3(repeating: Float.random(in: -0.08...0.08, using: &rng)), .zero, .one) }
    }
    let smoothed = Camouflage.smooth(noisy, geometry: geometry, radius: 0.004)
    func speckle(_ colours: [Color3?]) -> Float {
        var total: Float = 0, n = 0
        for texel in geometry.validTexels.prefix(4000) {
            let t = Int(texel)
            guard let c = colours[t] else { continue }
            var sum = Color3.zero, m: Float = 0
            geometry.grid.forEachTexel(near: geometry.texelPositions[t], radius: 0.003) { o in
                if o != t, let oc = colours[o] { sum += oc; m += 1 }
            }
            if m > 0 { total += simd_distance(c, sum / m); n += 1 }
        }
        return total / Float(max(n, 1))
    }
    let before = speckle(noisy), after = speckle(smoothed)
    print(String(format: "  speckle %.3f before smoothing, %.3f after", before, after))
    check(after < before * 0.6, "smoothing takes out the speckle of a noisy scan")
    // …but keeps the big picture: the average colour barely moves.
    var shift: Float = 0, shifted = 0
    for texel in geometry.validTexels { let t = Int(texel); if let a = noisy[t], let b = smoothed[t] { shift += simd_distance(a, b); shifted += 1 } }
    check(shift / Float(max(shifted, 1)) < 0.1, "and keeps the colours it had")

    // A hard edge (left half dark, right half light) stays hard.
    var edge = [Color3?](repeating: nil, count: geometry.atlasWidth * geometry.atlasHeight)
    for texel in geometry.validTexels {
        let t = Int(texel)
        edge[t] = geometry.texelPositions[t].x < 0 ? Color3(0.2, 0.2, 0.2) : Color3(0.85, 0.8, 0.7)
    }
    let kept = Camouflage.smooth(edge, geometry: geometry, radius: 0.004)
    var blurred = 0, nearEdge = 0
    for texel in geometry.validTexels {
        let t = Int(texel)
        guard abs(geometry.texelPositions[t].x) < 0.002, let a = edge[t], let b = kept[t] else { continue }
        nearEdge += 1
        if simd_distance(a, b) > 0.15 { blurred += 1 }
    }
    check(nearEdge > 0 && blurred * 10 < nearEdge, "a real edge stays sharp (\(blurred) of \(nearEdge) texels by it blurred)")

    // Painting in patches looks like painting texel by texel, just without the speckle.
    var drift: Float = 0, compared = 0
    for (k, texel) in geometry.validTexels.enumerated() where geometry.texelPositions[Int(texel)].y > 0.03 {
        if let a = raw[k], let b = painted[Int(texel)] { drift += simd_distance(a, b); compared += 1 }
    }
    print(String(format: "  patches vs texel by texel: %.3f apart on average", drift / Float(max(compared, 1))))
    check(drift / Float(max(compared, 1)) < 0.06, "painting in patches gives the same camouflage")

    // …and is quick at any size (a small chameleon used to take seconds).
    let appSize = CharacterGeometry.build(from: CharacterShape.build(.standing))
    for scale: Float in [1, 0.3] {
        let began = Date()
        _ = Camouflage.paintAll(geometry: appSize, scale: scale, viewpoints: everyone, environment: scene.environment)
        let took = Date().timeIntervalSince(began)
        print(String(format: "  magic camouflage at %.0f%% size: %.2f s", scale * 100, took))
        check(took < 0.4, "magic camouflage is quick at \(Int(scale * 100))% size")
    }

    // At the app's real resolution, smoothing mustn't make the button feel slow.
    let full = CharacterGeometry.build(from: CharacterShape.build(.standing))
    let plain = [Color3?](repeating: Color3(0.5, 0.5, 0.5), count: full.atlasWidth * full.atlasHeight)
    let start = Date()
    _ = Camouflage.smooth(plain, geometry: full, radius: 0.004)
    let seconds = Date().timeIntervalSince(start)
    print(String(format: "  smoothing \(full.validTexels.count) texels took %.2f s on this Mac", seconds))
    check(seconds < 2, "smoothing the full-size chameleon is quick")
}

// MARK: - Squad play

section("Placing holds still")
do {
    // A hand-held aim at a table 1 m away: a centimetre of jitter, a few degrees of tilt noise.
    var aim = AimStabilizer()
    var rng = SystemRandomNumberGenerator()
    func noise(_ amount: Float) -> Float { Float.random(in: -amount...amount, using: &rng) }
    let spot = Vec3(0, 0.75, -1)
    var worstMove: Float = 0, worstTilt: Float = 0, worstTurn: Float = 0
    var previous: AimStabilizer.Aim?
    for frame in 0..<180 {
        let t = Double(frame) / 60
        let n = simd_normalize(Vec3(noise(0.07), 1, noise(0.07)))
        let out = aim.update(position: spot + Vec3(noise(0.008), noise(0.003), noise(0.008)), normal: n, kind: .floor,
                             viewer: Vec3(noise(0.03), 1.4, 0), time: t)
        if let previous, frame > 10 {
            worstMove = max(worstMove, simd_distance(out.position, previous.position))
            worstTilt = max(worstTilt, acos(min(1, simd_dot(out.normal, previous.normal))))
            worstTurn = max(worstTurn, acos(min(1, simd_dot(out.facing, previous.facing))))
        }
        previous = out
    }
    print(String(format: "  jittery aim: moves at most %.1f mm, tilts %.2f°, turns %.2f° a frame",
                 worstMove * 1000, worstTilt * 180 / .pi, worstTurn * 180 / .pi))
    check(worstMove < 0.002, "a shaky hand doesn't shake it")
    check(worstTilt < 0.001, "the mesh's bumps don't rock it: it sits level")
    check(worstTurn < 0.001, "and it doesn't swivel")

    // A steady pan across the table: it keeps up.
    var pan = AimStabilizer()
    var lag: Float = 0
    for frame in 0..<60 {
        let target = Vec3(Float(frame) * 0.005, 0.75, -1)
        let out = pan.update(position: target, normal: [0, 1, 0], kind: .floor, viewer: [0, 1.4, 0], time: Double(frame) / 60)
        if frame > 20 { lag = max(lag, simd_distance(out.position, target)) }
    }
    print(String(format: "  panning at 30 cm/s it trails by %.1f cm", lag * 100))
    check(lag < 0.03, "a real move is followed without dragging behind")

    // Aiming at the wall instead: straight there.
    let wall = pan.update(position: [0.3, 1.2, -1.6], normal: [0, 0, 1], kind: .wall, viewer: [0, 1.4, 0], time: 1.1)
    check(simd_distance(wall.position, [0.3, 1.2, -1.6]) < 1e-4 && wall.normal == [0, 0, 1], "a different surface is a jump, not a slide")
}

section("Changing pose keeps the paint")
do {
    let sitting = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let napping = CharacterGeometry.build(from: CharacterShape.build(.curled), cellPixels: 5)
    let sittingField = CharacterSDF.make(.standing), nappingField = CharacterSDF.make(.curled)
    let lift: @Sendable (CharacterGeometry, CharacterSDF) -> Vec3 = { g, f in g.eyes[0].centre - f.eyes[0].centre }
    // Which part a point on the mesh belongs to.
    let part: @Sendable (Vec3, CharacterSDF, Vec3) -> Int = { p, field, l in
        field.parts.indices.min { field.parts[$0].distance(p - l) < field.parts[$1].distance(p - l) }!
    }
    // The head as a player paints it: head, snout, casque and eyes together.
    let head = Set(1...5), tail = Set(14..<30)
    let sittingLift = lift(sitting, sittingField)
    let red = Color3(0.9, 0.1, 0.1), blue = Color3(0.1, 0.2, 0.9)
    let canvas = PaintCanvas(geometry: sitting)
    canvas.applyToAllTexels({ _, position, _ in
        let i = part(position, sittingField, sittingLift)
        return head.contains(i) ? red : (tail.contains(i) ? blue : nil)
    }, progress: { _ in })
    guard let transfer = PoseTransfer(from: sitting, pixels: canvas.pixels, to: napping) else {
        check(false, "the paint can be carried over"); exit(1)
    }
    var headRight = 0, headTotal = 0, tailRight = 0, tailTotal = 0, bodyWhite = 0, bodyTotal = 0
    for texel in napping.validTexels {
        let t = Int(texel)
        let position = napping.texelPositions[t]
        let i = part(position, nappingField, lift(napping, nappingField))
        let c = transfer.colour(at: position, normal: napping.texelNormals[t]) ?? PaintCanvas.baseColor
        if i == 1 { headTotal += 1; if simd_distance(c, red) < 0.25 { headRight += 1 } }
        else if tail.contains(i) { tailTotal += 1; if simd_distance(c, blue) < 0.25 { tailRight += 1 } }
        else if i == 0 { bodyTotal += 1; if simd_distance(c, PaintCanvas.baseColor) < 0.25 { bodyWhite += 1 } }
    }
    let headShare = Float(headRight) / Float(max(headTotal, 1))
    let tailShare = Float(tailRight) / Float(max(tailTotal, 1))
    let bodyShare = Float(bodyWhite) / Float(max(bodyTotal, 1))
    print("  sitting → napping: head \(Int(headShare * 100))% red, tail \(Int(tailShare * 100))% blue, body \(Int(bodyShare * 100))% unpainted")
    check(headShare > 0.8, "the painted head is still painted, on the head")
    check(tailShare > 0.8, "a painted tail stays on the tail, wherever it's curled to")
    check(bodyShare > 0.8, "and the unpainted body stays unpainted")
}

section("Squads with and without LiDAR")
do {
    func state(_ lidar: [Bool]) -> SquadState {
        var s = SquadState()
        for (i, has) in lidar.enumerated() {
            SquadRules.apply(.join(SquadPlayer(id: UUID(), name: "P\(i)", colour: 0, arSession: UUID(), lidar: has)), to: &s)
        }
        return s
    }
    check(SquadRules.roomSupport(state([true, true, true])) == .full, "everyone has LiDAR: the full game")
    let hostScans = state([true, false, false])
    check(SquadRules.roomSupport(hostScans) == .shared(scanner: hostScans.players[0].id), "the host maps the room if it has LiDAR")
    let guestScans = state([false, false, true])
    check(SquadRules.roomSupport(guestScans) == .shared(scanner: guestScans.players[2].id), "otherwise whoever has LiDAR does")
    check(SquadRules.roomSupport(state([false, false])) == .flat, "nobody has LiDAR: the lite game")

    // A room map survives packing, to the millimetre, and packs small.
    var rng = SystemRandomNumberGenerator()
    let anchor = UUID()
    var room = RoomMesh(anchor: anchor, v0: [], v1: [], v2: [])
    for _ in 0..<20_000 {
        let c = Vec3(Float.random(in: -4...4, using: &rng), Float.random(in: 0...2.5, using: &rng), Float.random(in: -4...4, using: &rng))
        room.v0.append(c); room.v1.append(c + [0.03, 0, 0]); room.v2.append(c + [0, 0.03, 0.01])
    }
    let packed = RoomShare.encode(room)
    let unpacked = packed.flatMap(RoomShare.decode)
    let worst = unpacked.map { u in zip(u.v0, room.v0).map { simd_distance($0, $1) }.max() ?? 1 } ?? 1
    print("  20,000 triangles pack to \((packed?.count ?? 0) / 1024) KB; worst error \(String(format: "%.2f", worst * 1000)) mm")
    check(unpacked?.anchor == anchor && unpacked?.triangleCount == 20_000 && worst < 0.001,
          "a room map comes back the same, within a millimetre")
    check((packed?.count ?? .max) < 400_000, "and is small enough to send (\((packed?.count ?? 0) / 1024) KB)")

    // A phone without LiDAR, using the shared map: a wall between it and a chameleon hides it.
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let chunks = ChameleonChunks.build(geometry)
    let characterToWorld = simd_float4x4(translation: [0, 0, -1.0])
    let eye = Vec3(0, 0.1, 0)
    let wall = TriangleBVH(v0: [[-2, -1, -0.5], [-2, -1, -0.5]], v1: [[2, -1, -0.5], [2, 2, -0.5]], v2: [[2, 2, -0.5], [-2, 2, -0.5]])
    let behindWall = chunks.coverage(characterToWorld: characterToWorld, eye: eye, room: wall).compactMap { $0 }
    let open = TriangleBVH(v0: [[-2, -1, -1.5]], v1: [[2, -1, -1.5]], v2: [[0, 2, -1.5]])
    let inTheOpen = chunks.coverage(characterToWorld: characterToWorld, eye: eye, room: open).compactMap { $0 }
    check(!behindWall.isEmpty && behindWall.allSatisfy { $0 > 0.9 }, "with the shared map, a wall in front hides it")
    check(!inTheOpen.isEmpty && inTheOpen.allSatisfy { $0 < 0.05 }, "and a wall behind it doesn't")

    // Its own surface, estimated a little too high (common without LiDAR), seen from low
    // down: that used to cover most of it, and "mostly covered" hides all of it.
    let base = chunks.chunks.flatMap(\.samples).map(\.y).min()! + characterToWorld.columns.3.y
    func plane(_ y: Float, z0: Float, z1: Float) -> ([Vec3], [Vec3], [Vec3]) {
        ([[-3, y, z0], [-3, y, z0]], [[3, y, z0], [3, y, z1]], [[3, y, z1], [-3, y, z1]])
    }
    let table = plane(base + 0.02, z0: 0.5, z1: -2.5)
    let lowEye = Vec3(0, base + 0.22, 0.2)
    let onItsTable = chunks.coverage(characterToWorld: characterToWorld, eye: lowEye,
                                     room: TriangleBVH(v0: table.0, v1: table.1, v2: table.2)).compactMap { $0 }
    let tableShare = onItsTable.reduce(0, +) / Float(max(onItsTable.count, 1))
    print(String(format: "  on a table estimated 2 cm too high, seen from low down: %.0f%% covered", tableShare * 100))
    check(tableShare < 0.15, "the surface it stands on doesn't hide it, even estimated a little off")
    let tableAndWall = TriangleBVH(v0: table.0 + [[-2, -1, -0.5], [-2, -1, -0.5]], v1: table.1 + [[2, -1, -0.5], [2, 2, -0.5]],
                                   v2: table.2 + [[2, 2, -0.5], [-2, 2, -0.5]])
    let behindWallOnTable = chunks.coverage(characterToWorld: characterToWorld, eye: lowEye, room: tableAndWall).compactMap { $0 }
    check(!behindWallOnTable.isEmpty && behindWallOnTable.allSatisfy { $0 > 0.9 }, "…but a wall in front still hides it")
    let raised = plane(base + 0.3, z0: 0.0, z1: -1.6)
    let shelfOver = chunks.coverage(characterToWorld: characterToWorld, eye: Vec3(0, base + 1.2, 0.4),
                                    room: TriangleBVH(v0: raised.0, v1: raised.1, v2: raised.2)).compactMap { $0 }
    check(!shelfOver.isEmpty && shelfOver.reduce(0, +) / Float(shelfOver.count) > 0.8, "…and so does a shelf above it")
}

section("Harder to see from further away")
do {
    let near = DistanceFade.opacity(distance: 0.5), arm = DistanceFade.opacity(distance: 1.0)
    let mid = DistanceFade.opacity(distance: 2.4), far = DistanceFade.opacity(distance: 4), across = DistanceFade.opacity(distance: 9)
    print(String(format: "  small room: %.0f%% at 1 m, %.0f%% at 2.4 m, %.0f%% at 4 m and beyond", arm * 100, mid * 100, far * 100))
    check(near == 1 && arm == 1, "within a metre it's as visible as ever (it was 0.8 m)")
    check(far < 0.25 && far > 0 && across == far, "across the room it's very faint, but never gone")
    var fading = true
    for ease in [Float(0), 0.5, 1] {
        var last: Float = 1.01
        for d in stride(from: Float(0), through: 9, by: 0.1) {
            let o = DistanceFade.opacity(distance: d, roomEase: ease)
            if o > last + 1e-6 { fading = false }
            last = o
        }
    }
    check(fading, "the further away, the fainter — never the other way, in any room")
    let bigAt4 = DistanceFade.opacity(distance: 4, roomEase: 1), bigFar = DistanceFade.opacity(distance: 12, roomEase: 1)
    print(String(format: "  big space: %.0f%% at 4 m, %.0f%% at its faintest", bigAt4 * 100, bigFar * 100))
    check(DistanceFade.opacity(distance: 1.4, roomEase: 1) == 1 && bigAt4 > far + 0.2 && bigFar > far,
          "spread over a big space, they stay clear further off and never get as faint")
}

section("Colours that reach the screen as the camera's")
do {
    // What v7.2 looked like in the playtest screenshots, which the fitted curve is made
    // from: a chameleon over carpet shown at 201 was drawn at about 224.
    let fit = DisplayCurve.fallback
    let drawnThen = fit.shown(198, channel: 1)
    print(String(format: "  stored 198 shows as %.0f (the screenshots: about 224 over a carpet shown at 201)", drawnThen))
    check(abs(drawnThen - 225) < 4, "the fitted curve is what the screenshots showed: stored as sampled, drawn too bright")
    var worst: Float = 0
    for wanted in stride(from: 30, through: 250, by: 5) {
        let stored = fit.stored(UInt8(wanted), channel: 1)
        worst = max(worst, abs(fit.shown(stored, channel: 1) - Float(wanted)))
    }
    print(String(format: "  to show 201 it stores %d; across the range the result is within %.1f of 255 of what's wanted",
                 fit.stored(201, channel: 1), worst))
    check(worst <= 2.5 && fit.stored(201, channel: 1) < 201, "stored darker by the right amount, it shows as the camera's colour")

    // A measurement on a device that isn't quite the fitted curve (and not quite neutral).
    func device(_ stored: Float, _ channel: Int) -> Float { 255 * pow(stored / 255, [0.53, 0.52, 0.5][channel]) }
    let levels = DisplayCurve.patchLevels
    let readings = levels.map { level in SIMD3<Float>(device(Float(level), 0), device(Float(level), 1), device(Float(level), 2)) }
    if let measured = DisplayCurve(levels: levels, shown: readings) {
        var off: Float = 0
        for wanted in stride(from: 60, through: 240, by: 10) {
            for channel in 0..<3 {
                off = max(off, abs(device(Float(measured.stored(UInt8(wanted), channel: channel)), channel) - Float(wanted)))
            }
        }
        print(String(format: "  measured from 8 greys: within %.1f of 255 of what's wanted, in every channel", off))
        check(off <= 4, "a measurement on the device corrects for that device")
        let pixels: [UInt8] = [201, 195, 180, 77]
        let out = measured.apply(pixels)
        check(out[3] == 77 && out[0] < 201 && out[1] < 195, "applied to a texture: colours stored darker, alpha left alone")
        check(DisplayCurve.agreesWithScreenshots(levels: levels, shown: readings), "and it agrees with the screenshots, so it's used")
        // The camera picture shown a touch darker than its pixels say: store darker still.
        let dimFeed = measured.matchingFeed(gain: SIMD3<Float>(repeating: 0.95))
        check(dimFeed.stored(200, channel: 1) < measured.stored(200, channel: 1), "if the camera picture itself is shown darker, that's matched too")
        check(dimFeed.blended(with: dimFeed).stored(200, channel: 1) == dimFeed.stored(200, channel: 1), "and averaging two measurements keeps it")
    } else {
        check(false, "a measurement on the device corrects for that device")
    }

    // Readings that can't be the strip: never used.
    let flat = levels.map { _ in SIMD3<Float>(repeating: 150) }
    let jumbled = [40, 180, 90, 200, 60, 220, 120, 240].map { SIMD3<Float>(repeating: Float($0)) }
    let coloured = levels.map { SIMD3<Float>(Float($0), Float($0) * 0.5, Float($0)) }
    check(DisplayCurve(levels: levels, shown: flat) == nil && DisplayCurve(levels: levels, shown: jumbled) == nil
            && DisplayCurve(levels: levels, shown: coloured) == nil,
          "a reading that isn't a grey ramp (the strip was covered, or missed) is thrown away")
    // A plausible ramp, but as RealityKit's tone mapping would show it: not the screen as played.
    let toneMapped = levels.map { SIMD3<Float>(repeating: Float($0) * 0.82) }
    check(DisplayCurve(levels: levels, shown: toneMapped) != nil
            && !DisplayCurve.agreesWithScreenshots(levels: levels, shown: toneMapped),
          "and one that contradicts the screenshots isn't trusted")
    check(DisplayCurve.identity.apply([10, 128, 250, 255]) == [10, 128, 250, 255], "with nothing to correct, nothing changes")
}

section("Coins and skins")
do {
    // A find: the full amount at the start, half by the end; harder pays more; the hint halves it.
    let hard = CoinRules.findBase(.hard), easy = CoinRules.findBase(.easy)
    let atStart = CoinRules.find(base: hard, elapsed: 0, of: 180, hintOn: false)
    let halfway = CoinRules.find(base: hard, elapsed: 90, of: 180, hintOn: false)
    let atEnd = CoinRules.find(base: hard, elapsed: 180, of: 180, hintOn: false)
    print("  a find on Hard pays \(atStart) at the start, \(halfway) halfway, \(atEnd) at the end; with the hint on, \(CoinRules.find(base: hard, elapsed: 0, of: 180, hintOn: true))")
    check(atStart == hard && atEnd == hard / 2 && halfway < atStart && halfway > atEnd, "the sooner a find, the more it pays, down to half")
    var falling = true, last = Int.max
    for t in stride(from: 0.0, through: 200, by: 5) {
        let coins = CoinRules.find(base: hard, elapsed: t, of: 180, hintOn: false)
        if coins > last { falling = false }
        last = coins
    }
    check(falling && last >= 1, "never more for being slower, and never nothing")
    check(CoinRules.findBase(.medium) > easy && hard > CoinRules.findBase(.medium), "harder levels pay more")
    check(CoinRules.find(base: hard, elapsed: 30, of: 180, hintOn: true) * 2 <= CoinRules.find(base: hard, elapsed: 30, of: 180, hintOn: false) + 1,
          "with the hint on, a find pays half")

    // A squad round's other coins.
    func player(_ name: String) -> SquadPlayer { SquadPlayer(id: UUID(), name: name, colour: 0, arSession: nil) }
    let ana = player("Ana"), ben = player("Ben")
    var round = SquadState()
    round.settings.perPlayer = 4
    for p in [ana, ben] { SquadRules.apply(.join(p), to: &round) }
    SquadRules.apply(.startSync, to: &round)
    for p in [ana, ben] { SquadRules.apply(.synced(p.id), to: &round) }
    SquadRules.apply(.startHiding, to: &round)
    let anas = (0..<4).map { _ in SquadChameleon(id: UUID(), owner: ana.id, pose: "standing", scale: 0.8) }
    let bens = (0..<4).map { _ in SquadChameleon(id: UUID(), owner: ben.id, pose: "standing", scale: 0.8) }
    for c in anas + bens { SquadRules.apply(.placed(c), to: &round) }
    SquadRules.apply(.startHunt, to: &round)
    for c in bens.prefix(3) { SquadRules.apply(.claim(chameleon: c.id, by: ana.id), to: &round) }
    SquadRules.apply(.claim(chameleon: anas[0].id, by: ben.id), to: &round)
    SquadRules.apply(.endRound, to: &round)
    let anaBonus = CoinRules.squadBonus(for: ana.id, in: round), benBonus = CoinRules.squadBonus(for: ben.id, in: round)
    print("  end of round: Ana +\(anaBonus.unfound) for three never found and +\(anaBonus.win) for coming top; Ben +\(benBonus.unfound) and +\(benBonus.win)")
    check(anaBonus.unfound == 3 * CoinRules.unfoundBonus && anaBonus.win == CoinRules.winBonus, "hiding well and coming top both pay")
    check(benBonus.unfound == CoinRules.unfoundBonus && benBonus.win == 0, "second place keeps what theirs earned, without the winner's bonus")

    // Skins: looks only, each with a price worth a few rounds.
    let skins = ChameleonSkin.allCases
    check(ChameleonSkin.classic.price == 0 && skins.filter { $0.price == 0 }.count == 1, "one skin is free: the one everyone starts in")
    check(Set(skins.map(\.title)).count == skins.count && skins.allSatisfy { $0 == .classic || $0.price >= 100 },
          "every other skin has its own name and a price")
    let geometry = CharacterGeometry.build(from: CharacterShape.build(.standing), cellPixels: 5)
    let classic = ToyPaint.pixels(for: geometry), zebra = ToyPaint.pixels(for: geometry, palette: ChameleonSkin.zebra.palette)
    var light = 0, dark = 0
    for texel in geometry.validTexels {
        let i = Int(texel) * 4
        let value = Int(zebra[i]) + Int(zebra[i + 1]) + Int(zebra[i + 2])
        if value > 450 { light += 1 } else if value < 200 { dark += 1 }
    }
    check(zebra != classic && light > geometry.validTexels.count / 6 && dark > geometry.validTexels.count / 12,
          "a patterned skin really is painted in its pattern (zebra: \(light) light texels, \(dark) dark)")
    check(ToyPaint.pixels(for: geometry, palette: ChameleonSkin.classic.palette) == classic, "and Classic is the chameleon as it always was")

    // Hiding with no limit, and the time allowed for placing the rest when there is one.
    var lobby = SquadState()
    SquadRules.apply(.join(ana), to: &lobby)
    var open = lobby.settings
    open.hideSeconds = 0
    check(SquadRules.apply(.settings(open), to: &lobby) && lobby.settings.hideSeconds == 0 && !lobby.settings.hidingIsTimed,
          "the host can set no limit on hiding")
    check(SquadSettings.hideChoices.contains(0) && SquadSettings().hidingIsTimed, "it's one of the choices, and not the default")
    check(SquadSettings().autoPlaceAllowance >= SquadSettings().hiding * 3, "when time runs out there's time to place the rest, a few seconds each")
}

section("Keeping its place in the room")
do {
    // Frames at 60 a second.
    func run(_ guardian: inout TrackingGuard, _ quality: TrackingGuard.Quality, from start: Double, for seconds: Double,
             guarding: Bool) -> (refinds: Int, everHidden: Bool, end: Double) {
        var refinds = 0, everHidden = false
        var t = start
        while t < start + seconds {
            if guardian.update(quality, time: t, guarding: guarding) { refinds += 1 }
            if guardian.hidden { everHidden = true }
            t += 1.0 / 60
        }
        return (refinds, everHidden, t)
    }
    var hiding = TrackingGuard()
    var r = run(&hiding, .good, from: 0, for: 1, guarding: false)
    r = run(&hiding, .shaky, from: r.end, for: 6, guarding: false)
    check(!r.everHidden && r.refinds == 0, "while hiding, 'not enough detail here' (a plain white desk) hides nothing: what's dropped stays in view")

    var hunt = TrackingGuard()
    r = run(&hunt, .good, from: 0, for: 1, guarding: true)
    r = run(&hunt, .shaky, from: r.end, for: 0.5, guarding: true)
    let afterBlip = run(&hunt, .good, from: r.end, for: 1, guarding: true)
    check(!r.everHidden && !afterBlip.everHidden && r.refinds == 0, "a half-second wobble in a hunt hides nothing either")

    r = run(&hunt, .shaky, from: afterBlip.end, for: 1.5, guarding: true)
    check(r.everHidden && r.refinds == 0, "tracking shaky for over a second: the chameleons are hidden")
    r = run(&hunt, .shaky, from: r.end, for: 60, guarding: true)
    check(r.refinds == 1, "put down for a minute: it's told to find its place again, once")
    r = run(&hunt, .blind, from: r.end, for: 8, guarding: true)
    check(hunt.hidden && r.refinds == 0, "while it's finding its place, nothing is shown and it isn't asked again")
    r = run(&hunt, .good, from: r.end, for: 0.2, guarding: true)
    check(hunt.hidden, "found: but not shown until it has held for a moment")
    r = run(&hunt, .good, from: r.end, for: 0.5, guarding: true)
    check(!hunt.hidden, "then they're back")
    r = run(&hunt, .shaky, from: r.end, for: 5, guarding: true)
    check(r.refinds == 1, "and if it's put down again, it finds its place again")

    var starting = TrackingGuard()
    r = run(&starting, .blind, from: 0, for: 1, guarding: false)
    check(starting.hidden, "starting up, nothing is shown")
    r = run(&starting, .shaky, from: r.end, for: 0.1, guarding: false)
    check(!starting.hidden, "but once it's tracking at all, a hider sees what they drop")
}

section("Swarm's difficulty")
do {
    let easy = HuntDifficulty.easy, medium = HuntDifficulty.medium, hard = HuntDifficulty.hard
    check(easy.tapReach == 26 && easy.missPenalty == 0 && easy.secondsPerExtra == 12
            && DistanceFade.range(roomEase: 0, difficulty: easy) == DistanceFade.smallRoom,
          "Easy keeps the forgiving taps, free misses and the distance fade as playtested")
    let levels = [easy, medium, hard]
    var harder = true
    for (a, b) in zip(levels, levels.dropFirst()) {
        if !(b.camouflageBoost > a.camouflageBoost && b.tapReach < a.tapReach && b.missPenalty > a.missPenalty
             && b.secondsPerExtra < a.secondsPerExtra && b.adaptRate > a.adaptRate && b.refreshInterval < a.refreshInterval
             && b.tell.far < a.tell.far && b.tell.close < a.tell.close) { harder = false }
        for d in stride(from: Float(0.5), through: 8, by: 0.5) {
            if DistanceFade.opacity(distance: d, difficulty: b) > DistanceFade.opacity(distance: d, difficulty: a) + 1e-6 { harder = false }
        }
    }
    check(harder, "each level is harder on every count than the one before")
    let phone = ScreenDifficulty.livingStrength(base: 0.75, diagonalInches: 6.3)
    let bigPad = ScreenDifficulty.livingStrength(base: 0.75, diagonalInches: 13)
    print(String(format: "  camouflage on a phone: %.2f / %.2f / %.2f · 13\" iPad: %.2f / %.2f / %.2f",
                 easy.camouflage(base: phone), medium.camouflage(base: phone), hard.camouflage(base: phone),
                 easy.camouflage(base: bigPad), medium.camouflage(base: bigPad), hard.camouflage(base: bigPad)))
    check(hard.camouflage(base: bigPad) <= HuntDifficulty.camouflageCeiling, "never a perfect match: a little of the paint always shows")
    let hardFar = DistanceFade.opacity(distance: 10, difficulty: hard)
    let hardRange = DistanceFade.range(roomEase: 0, difficulty: hard)
    print(String(format: "  Hard: clear within %.1f m, faintest (%.0f%%) from %.1f m", hardRange.clearWithin, hardFar * 100, hardRange.faintBeyond))
    check(hardFar > 0 && DistanceFade.opacity(distance: 0.3, difficulty: hard) == 1, "on Hard it's still never gone, and plain right up close")
    check(Set(levels.map(\.detail)).count == 3 && hard.detail.contains("\(hard.missPenalty) s"), "each says what it means, misses included")

    // The tell: how far off a perfect match it's drawn. Chosen, now that the rendering
    // fault that used to darken every chameleon (by 0.05 to 0.13) is gone.
    for level in levels {
        print(String(format: "  %@: %.1f%% off the match from a step away, %.1f%% right next to it; catches up %.0f%% each %.2f s",
                     level.title, level.tell(distance: 2) * 100, level.tell(distance: 0.2) * 100, level.adaptRate * 100, level.refreshInterval))
    }
    check(levels.allSatisfy { $0.tell(distance: 0.2) > $0.tell(distance: 2) && $0.tell(distance: 0.2) == $0.tell.close
                              && $0.tell(distance: 5) == $0.tell.far },
          "right next to one it's plainer to see, at every level")
    check(hard.tell.far > 0.008 && hard.tell.far < 0.02, "on Hard, from a step away, only very slightly visible: never nothing")
    check(easy.tell.far < 0.05, "on Easy, less off than the old rendering fault was on a carpet")
    let white = LiveSkin.nudged(Color3(0.92, 0.91, 0.88), tell: 0.02), black = LiveSkin.nudged(Color3(0.05, 0.05, 0.06), tell: 0.02)
    check(white.x < 0.92 && abs((0.92 - white.x) - 0.02) < 0.002 && black.x > 0.05,
          "a light surface's chameleon is drawn a touch darker, a dark one's a touch lighter")
    check(LiveSkin.nudged(Color3(0.5, 0.4, 0.3), tell: 0) == Color3(0.5, 0.4, 0.3), "no tell, no change")

    // Squad plays at the same levels: the host's choice travels with the game.
    check(SquadSettings().difficulty == .easy, "a squad starts on Easy, like Swarm")
    var lobby = SquadState()
    SquadRules.apply(.join(SquadPlayer(id: UUID(), name: "Ana", colour: 0, arSession: nil)), to: &lobby)
    var picked = lobby.settings
    picked.difficulty = .hard
    check(SquadRules.apply(.settings(picked), to: &lobby) && lobby.settings.difficulty == .hard, "the host can pick Hard")
    let wire = try! JSONEncoder().encode(SquadMessage.state(lobby))
    if case .state(let arrived) = try! JSONDecoder().decode(SquadMessage.self, from: wire) {
        check(arrived.settings.difficulty == .hard, "and every device gets it")
    } else {
        check(false, "and every device gets it")
    }
    check(easy.summary == "Easy · misses are free" && hard.summary == "Hard · a miss costs 5 s", "the lobby says what the level means")
}

section("A big space is a little easier than a small room")
do {
    let smallRoom: [Vec3] = [Vec3(0, 0, 0), Vec3(2, 0.8, 1), Vec3(-0.5, 1.9, 2.2), Vec3(1, 0.4, -0.6)]
    let house: [Vec3] = [Vec3(0, 0, 0), Vec3(4, 0.8, 1), Vec3(9, 0, 6), Vec3(-2, 1.2, 3)]
    let smallWidth = RoomSpread.width(of: smallRoom), houseWidth = RoomSpread.width(of: house)
    print(String(format: "  a living room: %.1f m across, ease %.2f · a house: %.1f m, ease %.2f",
                 smallWidth, RoomSpread.ease(width: smallWidth), houseWidth, RoomSpread.ease(width: houseWidth)))
    check(RoomSpread.width(of: [Vec3(0, 0, 0), Vec3(0, 2, 0)]) == 0, "height doesn't count: a shelf above a table isn't more room")
    check(RoomSpread.ease(width: smallWidth) == 0, "a living room is played as it was playtested")
    check(RoomSpread.ease(width: houseWidth) == 1, "chameleons spread over a house get the most help")
    check(RoomSpread.ease(width: 0) == 0 && RoomSpread.width(of: [Vec3(1, 1, 1)]) == 0, "one chameleon is a small room")
    let usual = RoomSpread.camouflageScale(distance: 2, roomEase: 0)
    let close = RoomSpread.camouflageScale(distance: 0.3, roomEase: 0)
    let bigFar = RoomSpread.camouflageScale(distance: 3, roomEase: 1)
    let bigClose = RoomSpread.camouflageScale(distance: 0.3, roomEase: 1)
    print(String(format: "  camouflage ×%.2f from a step away, ×%.2f right next to it, ×%.2f across a big space, ×%.2f close in one",
                 usual, close, bigFar, bigClose))
    check(usual == 1, "a small room from a step away: unchanged")
    check(close < 1 && close >= 0.9, "right next to one, a little easier to see")
    check(bigFar < 1 && bigFar >= 0.85 && bigClose >= 0.78, "across a big space a little easier, never a lot")
}

section("Squad rules")
do {
    func player(_ name: String) -> SquadPlayer { SquadPlayer(id: UUID(), name: name, colour: 0, arSession: UUID()) }
    let ana = player("Ana"), ben = player("Ben"), cy = player("Cy")
    var state = SquadState()
    SquadRules.apply(.join(ana), to: &state)
    SquadRules.apply(.join(ben), to: &state)
    SquadRules.apply(.join(cy), to: &state)
    check(state.players.count == 3 && Set(state.players.map(\.colour)).count == 3, "three players, three different colours")
    check(!SquadRules.apply(.join(ben), to: &state), "joining twice changes nothing")

    // Free-for-all.
    check(SquadRules.apply(.startSync, to: &state) && state.phase == .syncing, "the host starts syncing")
    check(!SquadRules.apply(.startHiding, to: &state), "hiding can't start until everyone's AR has met")
    for p in [ana, ben, cy] { SquadRules.apply(.synced(p.id), to: &state) }
    check(SquadRules.apply(.startHiding, to: &state) && state.phase == .hiding, "then it can")
    let limit = state.settings.perPlayer
    var anaChameleons: [UUID] = []
    for _ in 0..<(limit + 1) {
        let c = SquadChameleon(id: UUID(), owner: ana.id, pose: "standing", scale: 0.8)
        if SquadRules.apply(.placed(c), to: &state) { anaChameleons.append(c.id) }
    }
    check(anaChameleons.count == limit, "each player can hide exactly \(limit)")
    let benChameleon = SquadChameleon(id: UUID(), owner: ben.id, pose: "curled", scale: 0.8)
    SquadRules.apply(.placed(benChameleon), to: &state)
    check(SquadRules.apply(.startHunt, to: &state) && state.phase == .hunting, "the hunt starts")
    check(!SquadRules.apply(.claim(chameleon: anaChameleons[0], by: ana.id), to: &state), "you can't find your own")
    check(SquadRules.apply(.claim(chameleon: anaChameleons[0], by: ben.id), to: &state), "someone else can")
    check(!SquadRules.apply(.claim(chameleon: anaChameleons[0], by: cy.id), to: &state), "and only the first claim counts")
    SquadRules.apply(.claim(chameleon: benChameleon.id, by: cy.id), to: &state)
    SquadRules.apply(.endRound, to: &state)
    let scores = SquadRules.scores(state)
    let anaScore = scores.first { $0.player.id == ana.id }!
    check(anaScore.survivors == limit - 1 && anaScore.finds == 0, "unfound chameleons score for whoever hid them")
    check(scores.first!.points >= scores.last!.points, "the leaderboard is in order")

    // Hider vs all: the hider rotates, and only the hider hides.
    state.settings.mode = .hiderVsAll
    SquadRules.apply(.startSync, to: &state)
    let firstHider = state.hider
    for p in state.players { SquadRules.apply(.synced(p.id), to: &state) }
    SquadRules.apply(.startHiding, to: &state)
    check(state.doneHiding.count == 2, "the seekers have nothing to hide")
    let seeker = state.players.first { $0.id != firstHider }!
    check(!SquadRules.apply(.placed(SquadChameleon(id: UUID(), owner: seeker.id, pose: "standing", scale: 1)), to: &state),
          "a seeker can't hide one")
    SquadRules.apply(.placed(SquadChameleon(id: UUID(), owner: firstHider!, pose: "standing", scale: 1)), to: &state)
    SquadRules.apply(.startHunt, to: &state)
    check(!SquadRules.apply(.claim(chameleon: state.chameleons[0].id, by: firstHider!), to: &state), "the hider can't hunt")
    SquadRules.apply(.endRound, to: &state)
    SquadRules.apply(.startSync, to: &state)
    check(state.hider != nil && state.hider != firstHider, "next round, someone else hides")

    // The wire format survives a round trip.
    let data = try! JSONEncoder().encode(SquadMessage.state(state))
    if case .state(let decoded) = try! JSONDecoder().decode(SquadMessage.self, from: data) {
        check(decoded == state, "the game state survives being sent between devices (\(data.count) bytes)")
    } else {
        check(false, "the game state survives being sent between devices")
    }
    SquadRules.apply(.leave(ben.id), to: &state)
    check(!state.players.contains { $0.id == ben.id }, "a player who leaves is gone, with their chameleons")

    // Giving up.
    var hunt = SquadState()
    for p in [ana, ben, cy] { SquadRules.apply(.join(p), to: &hunt) }
    SquadRules.apply(.startSync, to: &hunt)
    for p in [ana, ben, cy] { SquadRules.apply(.synced(p.id), to: &hunt) }
    SquadRules.apply(.startHiding, to: &hunt)
    let cys = SquadChameleon(id: UUID(), owner: cy.id, pose: "standing", scale: 0.8,
                             spot: (0..<16).map { Float($0) })
    SquadRules.apply(.placed(cys), to: &hunt)
    check(!SquadRules.apply(.giveUp(ana.id), to: &hunt), "nobody can give up before the hunt")
    SquadRules.apply(.startHunt, to: &hunt)
    check(SquadRules.apply(.giveUp(ana.id), to: &hunt) && !SquadRules.canSeek(ana.id, in: hunt), "a seeker can give up")
    check(!SquadRules.apply(.claim(chameleon: cys.id, by: ana.id), to: &hunt), "…and then can't find any more")
    check(!SquadRules.everyoneGaveUp(hunt), "the hunt goes on while someone's still looking")
    SquadRules.apply(.giveUp(ben.id), to: &hunt); SquadRules.apply(.giveUp(cy.id), to: &hunt)
    check(SquadRules.everyoneGaveUp(hunt), "once everyone's given up, the hunt can end")
    SquadRules.apply(.endRound, to: &hunt)
    SquadRules.apply(.startSync, to: &hunt)
    check(hunt.gaveUp.isEmpty, "next round, everyone's back in")
    check(hunt.settings.hints, "hints are on unless the host turns them off")
    let sent = try! JSONDecoder().decode(SquadChameleon.self, from: JSONEncoder().encode(cys))
    check(sent.spot == cys.spot, "a chameleon's spot survives being sent")

    // The game from testing: Ana hid four, Ben only managed three before time was up; each
    // found some of the other's. Ben's phone sends each find again until the host has it.
    var tested = SquadState()
    tested.settings.perPlayer = 4
    for p in [ana, ben] { SquadRules.apply(.join(p), to: &tested) }
    SquadRules.apply(.startSync, to: &tested)
    for p in [ana, ben] { SquadRules.apply(.synced(p.id), to: &tested) }
    SquadRules.apply(.startHiding, to: &tested)
    let anas = (0..<4).map { _ in SquadChameleon(id: UUID(), owner: ana.id, pose: "standing", scale: 0.8) }
    let benses = (0..<3).map { _ in SquadChameleon(id: UUID(), owner: ben.id, pose: "curled", scale: 0.8) }
    for c in anas + benses { SquadRules.apply(.placed(c), to: &tested) }
    check(!SquadRules.everyoneDoneHiding(tested) && SquadRules.apply(.startHunt, to: &tested),
          "time's up with one still to hide: the hunt starts anyway")
    check(SquadRules.apply(.claim(chameleon: anas[0].id, by: ben.id), to: &tested), "Ben finds one of Ana's")
    check(!SquadRules.apply(.claim(chameleon: anas[0].id, by: ben.id), to: &tested)
            && tested.chameleons.first { $0.id == anas[0].id }?.foundBy == ben.id,
          "the same find sent again changes nothing, and it stays Ben's")
    SquadRules.apply(.claim(chameleon: anas[1].id, by: ben.id), to: &tested)
    for c in benses { SquadRules.apply(.claim(chameleon: c.id, by: ana.id), to: &tested) }
    SquadRules.apply(.endRound, to: &tested)
    let board = SquadRules.scores(tested)
    let anaRow = board.first { $0.player.id == ana.id }!, benRow = board.first { $0.player.id == ben.id }!
    print("  Ana: \(anaRow.finds) found + \(anaRow.survivors) never found = \(anaRow.points) · Ben: \(benRow.finds) found + \(benRow.survivors) = \(benRow.points)")
    check(benRow.finds == 2 && benRow.points == 2, "Ben's two finds count on the board")
    check(anaRow.finds == 3 && anaRow.survivors == 2 && anaRow.points == 5, "and Ana's three, plus her two nobody found")

    // Longer games.
    var long = SquadState()
    SquadRules.apply(.join(ana), to: &long)
    var tenMinutes = long.settings
    tenMinutes.hideSeconds = 300; tenMinutes.huntSeconds = 600
    SquadRules.apply(.settings(tenMinutes), to: &long)
    check(long.settings.hideSeconds == 300 && long.settings.huntSeconds == 600, "five minutes to hide and ten to hunt are allowed")
    check(SquadSettings.hideChoices.contains(SquadSettings().hideSeconds)
            && SquadSettings.huntChoices.contains(SquadSettings().huntSeconds), "the defaults are among the host's choices")

    // Dropping off mid-game and coming back.
    var game = SquadState()
    for p in [ana, ben, cy] { SquadRules.apply(.join(p), to: &game) }
    check(!SquadRules.apply(.away(ben.id), to: &game), "nobody's 'away' in the lobby: they just leave")
    SquadRules.apply(.startSync, to: &game)
    for p in [ana, ben, cy] { SquadRules.apply(.synced(p.id), to: &game) }
    SquadRules.apply(.startHiding, to: &game)
    let bens = SquadChameleon(id: UUID(), owner: ben.id, pose: "standing", scale: 0.8)
    SquadRules.apply(.placed(bens), to: &game)
    check(SquadRules.apply(.away(ben.id), to: &game) && game.away.contains(ben.id),
          "a player who drops off mid-game is marked away")
    check(game.players.contains { $0.id == ben.id } && game.chameleons.contains { $0.id == bens.id },
          "…and keeps their place and their chameleons")
    let benColour = game.players.first { $0.id == ben.id }!.colour
    check(SquadRules.apply(.join(ben), to: &game) && !game.away.contains(ben.id), "joining again brings them back")
    check(game.players.first { $0.id == ben.id }!.colour == benColour, "in the same colour")
    SquadRules.apply(.away(cy.id), to: &game)
    SquadRules.apply(.backToLobby, to: &game)
    check(!game.players.contains { $0.id == cy.id } && game.away.isEmpty, "anyone still away by the next lobby is gone")
}

section("A little easier on a phone, a little harder on a big iPad")
do {
    let base: Float = 0.75   // GameConfig.scatterLivingStrength
    func strength(_ w: Float, _ h: Float, pad: Bool) -> Float {
        ScreenDifficulty.livingStrength(base: base, diagonalInches: ScreenDifficulty.diagonalInches(width: w, height: h, isPad: pad))
    }
    let iPhone = strength(402, 874, pad: false)        // iPhone 17 Pro, 6.3"
    let proMax = strength(440, 956, pad: false)        // iPhone Pro Max, 6.9"
    let mini = strength(744, 1133, pad: true)          // iPad mini, 8.3"
    let iPad11 = strength(834, 1210, pad: true)        // iPad Pro 11"
    let iPad13 = strength(1032, 1376, pad: true)       // iPad Pro 13"
    print(String(format: "  living camouflage: iPhone %.3f, Pro Max %.3f, mini %.3f, 11\" %.3f, 13\" %.3f (was %.2f everywhere)",
                 iPhone, proMax, mini, iPad11, iPad13, base))
    check(iPhone < proMax && proMax < mini && mini < iPad11 && iPad11 < iPad13, "the bigger the screen, the better they blend in")
    check(iPhone < base && iPad13 > base, "easier than before on a phone, harder on a big iPad")
    check(abs(iPhone - base) <= 0.07 + 1e-4 && abs(iPad13 - base) <= 0.07 + 1e-4, "only ever a very little either way (0.07 at most)")
    let turned = strength(874, 402, pad: false)
    check(abs(turned - iPhone) < 1e-6, "turning the phone sideways changes nothing")
    let inches = ScreenDifficulty.diagonalInches(width: 402, height: 874, isPad: false)
    check(abs(inches - 6.3) < 0.2, String(format: "an iPhone 17 Pro's screen works out at %.1f inches", inches))
}

section("Sound effects")
do {
    var worstPeak: Float = 0, longest = 0.0, allClean = true
    for effect in SoundEffect.allCases {
        let samples = SoundSynth.render(effect)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        let seconds = Double(samples.count) / SoundSynth.sampleRate
        worstPeak = max(worstPeak, peak)
        longest = max(longest, seconds)
        // No click at either end: it starts and stops near silence.
        let edge = 32
        let startLoud = samples.prefix(edge).reduce(0) { max($0, abs($1)) }
        let endLoud = samples.suffix(edge).reduce(0) { max($0, abs($1)) }
        if samples.isEmpty || peak.isNaN || peak < 0.05 || startLoud > 0.35 || endLoud > 0.05 {
            allClean = false
            print("  \(effect): peak \(peak), start \(startLoud), end \(endLoud), \(seconds) s")
        }
    }
    print(String(format: "  %d effects, loudest peak %.2f, longest %.2f s", SoundEffect.allCases.count, worstPeak, longest))
    check(allClean, "every effect renders, audible, with no click at the start or end")
    check(worstPeak <= 0.9, "none clips")
    check(longest < 1.5, "all short: nothing drones on over the game")
    check(SoundSynth.render(.tap).count < Int(SoundSynth.sampleRate * 0.05), "the key click is a click (under 50 ms)")
    check(SoundSynth.render(.found) == SoundSynth.render(.found), "the same every time")
}

// MARK: - Finding the spot again

section("Finding the hiding spot from anywhere")
do {
    let scene = DemoEnvironment.makeScene(surface: .floor)
    let truth = scene.anchorToWorld
    let scanPoints = SpotRegistration.samplePoints(from: scene.environment)
    var rng = SystemRandomNumberGenerator()
    let (wv0, wv1, wv2) = DemoEnvironment.worldTriangles()
    var live: [Vec3] = []
    for i in 0..<wv0.count {
        for _ in 0..<2 {
            let a = Float.random(in: 0...1, using: &rng), b = Float.random(in: 0...1, using: &rng)
            let (u, v) = a + b > 1 ? (1 - a, 1 - b) : (a, b)
            var p = wv0[i] + (wv1[i] - wv0[i]) * u + (wv2[i] - wv0[i]) * v
            p += Vec3(Float.random(in: -0.015...0.015, using: &rng), Float.random(in: -0.015...0.015, using: &rng),
                      Float.random(in: -0.015...0.015, using: &rng))
            if simd_distance(p, truth.translation) < 1.6 { live.append(p) }
        }
    }
    let grid = SpotRegistration.PointGrid(points: live)

    func search(aimedAt aim: Vec3, viewer: Vec3) -> SpotRegistration.Result? {
        let base = SurfaceFrame.anchorTransform(position: aim, normal: [0, 1, 0], kind: .floor, viewerPosition: viewer)
        var best: SpotRegistration.Result?
        for turn in 0..<8 {
            guard let result = SpotRegistration.refine(scanPoints: scanPoints, live: grid,
                                                       initial: base * SurfaceFrame.yaw(Float(turn) * .pi / 4),
                                                       maxTranslation: 0.35), result.isGood else { continue }
            if result.meanError < (best?.meanError ?? .greatestFiniteMagnitude) { best = result }
        }
        return best
    }

    var found = 0
    let viewpoints: [(String, Vec3, Vec3)] = [
        ("from the side", [1.6, 1.3, 0.2], [0.11, 0, -0.08]),
        ("from behind", [-0.9, 1.1, -1.7], [-0.14, 0, 0.09]),
        ("standing over it", [0.1, 1.7, 0.6], [0.06, 0, 0.13])
    ]
    for (name, viewer, offset) in viewpoints {
        guard let result = search(aimedAt: truth.translation + offset, viewer: viewer),
              result.meanError < 0.035, result.inlierRatio > 0.6 else {
            check(false, "\(name): finds it"); continue
        }
        let position = simd_distance(result.transform.translation, truth.translation)
        let facing = acos(min(1, max(-1, simd_dot(simd_normalize(result.transform.zAxis),
                                                  simd_normalize(truth.zAxis))))) * 180 / .pi
        print(String(format: "  %@: %.1f cm and %.1f° out", name, position * 100, facing))
        check(position < 0.06 && facing < 8, "\(name): puts it back within 6 cm and 8°")
        found += 1
    }
    check(found == viewpoints.count, "every viewpoint recovers the spot automatically")

    if let wrong = search(aimedAt: truth.translation + [2.2, 0, 1.4], viewer: [2.0, 1.4, 2.0]) {
        let confident = wrong.meanError < 0.035 && wrong.inlierRatio > 0.6
        check(!confident || simd_distance(wrong.transform.translation, truth.translation) < 0.1,
              "pointing somewhere else doesn't produce a confident wrong answer")
    } else {
        check(true, "pointing somewhere else finds nothing")
    }
}

print(failures.count == 0 ? "\nALL CORE TESTS PASSED" : "\n\(failures.count) FAILURE(S)")
if failures.count > 0 { exit(1) }
