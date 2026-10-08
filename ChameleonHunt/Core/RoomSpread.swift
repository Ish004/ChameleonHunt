//
//  RoomSpread.swift
//  A hunt in a big space is a little easier than one in a small room.
//
//  The game doesn't know how big the room is, but it knows where the chameleons are: how
//  far apart the two furthest ones are says how much ground the seekers have to cover.
//  Playtesting found the difficulty right in a small room and too hard across a big
//  space, where a seeker is never close to most of them and walks a long way to check
//  each place. So the further apart they were hidden, the easier they get, a little:
//  - they fade out less with distance (DistanceFade.range), and
//  - they match the room slightly less (camouflageScale), leaving a little more of the
//    paint from where they were hidden, which is what a sharp eye catches.
//
//  Close up, they also match the room slightly less, in any room: right next to one, it
//  should be a little easier to see what you're looking at.
//
//  Worked out from the chameleons, so every device in a squad gets the same answer.
//

import Foundation

enum RoomSpread {

    /// Metres between the two furthest chameleons, at or below which it's a small room.
    static let smallWithin: Float = 3.5
    /// Metres from which it's a big space: the most help it gets.
    static let bigFrom: Float = 9

    /// How much the camouflage eases off at most in a big space.
    static let bigRoomCamouflageEase: Float = 0.12
    /// How much it eases off right next to one (any room).
    static let closeUpCamouflageEase: Float = 0.08
    /// Metres: this close, the full close-up ease; it's gone by `closeUpEnds`.
    static let closeUpWithin: Float = 0.4
    static let closeUpEnds: Float = 1.0

    /// The widest gap between any two of them, along the floor (height doesn't count: a
    /// shelf above a table isn't more room to search).
    static func width(of points: [SIMD3<Float>]) -> Float {
        var widest: Float = 0
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = points[i].x - points[j].x, dz = points[i].z - points[j].z
                widest = max(widest, (dx * dx + dz * dz).squareRoot())
            }
        }
        return widest
    }

    /// 0 in a small room, 1 across a big space, easing between.
    static func ease(width: Float) -> Float {
        let t = min(max((width - smallWithin) / (bigFrom - smallWithin), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// What a chameleon's living camouflage is multiplied by, `distance` metres from the
    /// seeker in a room this spread out: 1 in a small room from a step away, a little less
    /// close up or across a big space.
    static func camouflageScale(distance: Float, roomEase: Float) -> Float {
        let t = min(max((distance - closeUpWithin) / (closeUpEnds - closeUpWithin), 0), 1)
        let close = 1 - t * t * (3 - 2 * t)
        return 1 - bigRoomCamouflageEase * min(max(roomEase, 0), 1) - closeUpCamouflageEase * close
    }
}
