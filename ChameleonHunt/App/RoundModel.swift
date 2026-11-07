//
//  RoundModel.swift
//  What a round is, as plain data.
//
//  Kept separate from anything to do with AR or the screen on purpose. Multiplayer is
//  the next step — several people each hiding chameleons, then seeking each other's,
//  and comparing how many they found — and when it comes, what has to travel between
//  iPads is exactly this: who hid which chameleon, where, and who found it. The game on
//  one iPad already runs from these records, so a second iPad only needs to receive them
//  (plus a shared map of the room) to run the same round.
//

import Foundation
import simd

enum GameMode: String, Codable, Sendable {
    /// One chameleon, hidden and hand-painted.
    case classic
    /// Several chameleons dropped quickly; they camouflage themselves.
    case scatter

    var title: String {
        switch self {
        case .classic: return "One chameleon"
        case .scatter: return "Lots of chameleons"
        }
    }
}

/// Someone playing. Only "you" for now; multiplayer will have one per iPad.
struct Player: Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String

    static let local = Player(name: "You")
}

/// One chameleon hidden in the room.
struct HiddenChameleon: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var hiddenBy: Player
    var pose: CharacterPose
    var scale: Float
    /// Where it sits, as a column-major 4×4 in the room's (world) coordinates.
    var transform: [Float]
    var foundBy: Player?
    var foundAfter: TimeInterval?

    init(id: UUID = UUID(), hiddenBy: Player = .local, pose: CharacterPose, scale: Float,
         transform: simd_float4x4) {
        self.id = id
        self.hiddenBy = hiddenBy
        self.pose = pose
        self.scale = scale
        self.transform = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    var matrix: simd_float4x4 {
        guard transform.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(transform[0], transform[1], transform[2], transform[3]),
                             SIMD4(transform[4], transform[5], transform[6], transform[7]),
                             SIMD4(transform[8], transform[9], transform[10], transform[11]),
                             SIMD4(transform[12], transform[13], transform[14], transform[15]))
    }

    var isFound: Bool { foundBy != nil }
}
