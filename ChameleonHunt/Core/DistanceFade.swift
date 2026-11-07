//
//  DistanceFade.swift
//  Far away, a chameleon is very hard to see; walk up to it and it's as plain as ever.
//
//  Playtesters wanted the hunt to reward searching the room rather than scanning it from
//  the doorway. So during a hunt each chameleon shows less of itself the further the
//  seeker is — never quite gone, so a sharp eye across the room can still catch one — and
//  all of itself close up. The fade eases in and out (smoothstep), so walking towards one
//  brings it up gently instead of popping.
//
//  How far "far" is depends on the room (RoomSpread): chameleons spread over a big space
//  stay clear from further off and never get quite as faint, since a seeker there can't
//  be close to most of them. In a small room it's as it was playtested, a little more
//  generous close up (v6.9).
//
//  Only while hunting, and only for chameleons still to be found: the hider sees theirs
//  in full while hiding, and a found one (a solid colour) stays solid.
//

import Foundation

enum DistanceFade {

    struct Range: Equatable {
        /// Metres: this close, it's as visible as it has always been.
        var clearWithin: Float
        /// Metres: this far and beyond, it's at its faintest.
        var faintBeyond: Float
        /// How much of it shows at its faintest (0 would be invisible).
        var faintest: Float
    }

    /// A small room (everything hidden within a few metres of everything else).
    static let smallRoom = Range(clearWithin: 1.0, faintBeyond: 4.0, faintest: 0.2)
    /// Chameleons spread over a big space.
    static let bigRoom = Range(clearWithin: 1.5, faintBeyond: 6.5, faintest: 0.3)

    /// The range for a room this spread out (RoomSpread.ease: 0 small … 1 big), at the
    /// hunt's difficulty.
    static func range(roomEase: Float, difficulty: HuntDifficulty = .easy) -> Range {
        let t = min(max(roomEase, 0), 1)
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        let scale = difficulty.fadeScale
        return Range(clearWithin: mix(smallRoom.clearWithin, bigRoom.clearWithin) * scale.clear,
                     faintBeyond: mix(smallRoom.faintBeyond, bigRoom.faintBeyond) * scale.faint,
                     faintest: mix(smallRoom.faintest, bigRoom.faintest) * scale.faintest)
    }

    /// How much of a chameleon shows from `distance` metres away, 0…1.
    static func opacity(distance: Float, roomEase: Float = 0, difficulty: HuntDifficulty = .easy) -> Float {
        let r = range(roomEase: roomEase, difficulty: difficulty)
        let t = min(max((distance - r.clearWithin) / (r.faintBeyond - r.clearWithin), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return 1 + (r.faintest - 1) * eased
    }
}
