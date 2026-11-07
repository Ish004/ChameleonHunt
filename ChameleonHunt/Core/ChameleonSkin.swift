//
//  ChameleonSkin.swift
//  What the player's chameleon looks like when it isn't hiding.
//
//  A skin is the chameleon's own colours: what follows the aim while hiding, what lands
//  before the room's colours wash over it, and the one on the home screen. It changes
//  nothing about how well a chameleon hides; once it has blended in, every skin is the
//  room's colours. Bought with coins (Coins.swift).
//
//  Colours cost least, patterns more, and two are something to save up for.
//

import Foundation
import simd

enum ChameleonSkin: String, CaseIterable, Codable, Sendable, Identifiable {
    case classic
    case bubblegum, lemon, sky, tangerine, cherry, grape, snow, midnight
    case bumblebee, tiger, zebra, ladybird, strawberry
    case gold, rainbow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .bubblegum: "Bubblegum"
        case .lemon: "Lemon"
        case .sky: "Sky"
        case .tangerine: "Tangerine"
        case .cherry: "Cherry"
        case .grape: "Grape"
        case .snow: "Snow"
        case .midnight: "Midnight"
        case .bumblebee: "Bumblebee"
        case .tiger: "Tiger"
        case .zebra: "Zebra"
        case .ladybird: "Ladybird"
        case .strawberry: "Strawberry"
        case .gold: "Gold"
        case .rainbow: "Rainbow"
        }
    }

    var price: Int {
        switch self {
        case .classic: 0
        case .bubblegum, .lemon, .sky, .tangerine, .cherry, .grape, .snow, .midnight: 150
        case .bumblebee, .tiger, .zebra, .ladybird, .strawberry: 400
        case .gold: 1000
        case .rainbow: 1500
        }
    }

    /// The chameleon's colours in this skin (as a designer would pick them, sRGB).
    var palette: MascotRenderer.Palette {
        func plain(_ c: Vec3, belly: Vec3? = nil) -> MascotRenderer.Palette {
            var palette = MascotRenderer.Palette()
            palette.body = c
            palette.back = c * 0.82
            palette.belly = belly ?? c + (Vec3(repeating: 1) - c) * 0.45
            return palette
        }
        func patterned(_ c: Vec3, _ accent: Vec3, _ pattern: MascotRenderer.Pattern, belly: Vec3? = nil) -> MascotRenderer.Palette {
            var palette = plain(c, belly: belly)
            palette.accent = accent
            palette.pattern = pattern
            return palette
        }
        switch self {
        case .classic: return MascotRenderer.Palette()
        case .bubblegum: return plain([1.0, 0.36, 0.68])
        case .lemon: return plain([1.0, 0.84, 0.22])
        case .sky: return plain([0.25, 0.78, 0.96])
        case .tangerine: return plain([1.0, 0.55, 0.20])
        case .cherry: return plain([0.93, 0.22, 0.27])
        case .grape: return plain([0.56, 0.36, 0.95])
        case .snow: return plain([0.95, 0.96, 0.98], belly: [1, 1, 1])
        case .midnight: return plain([0.16, 0.18, 0.42], belly: [0.55, 0.62, 0.95])
        case .bumblebee: return patterned([1.0, 0.80, 0.12], [0.12, 0.10, 0.10], .stripes)
        case .tiger: return patterned([1.0, 0.58, 0.14], [0.16, 0.10, 0.08], .stripes, belly: [1.0, 0.94, 0.82])
        case .zebra: return patterned([0.96, 0.96, 0.96], [0.10, 0.10, 0.12], .stripes)
        case .ladybird: return patterned([0.90, 0.16, 0.16], [0.10, 0.09, 0.10], .spots)
        case .strawberry: return patterned([0.96, 0.24, 0.36], [1.0, 0.93, 0.70], .spots, belly: [1.0, 0.80, 0.82])
        case .gold: return patterned([0.90, 0.60, 0.08], [1.0, 0.93, 0.55], .sheen, belly: [1.0, 0.84, 0.36])
        case .rainbow: return patterned([1.0, 0.36, 0.36], [0.36, 0.56, 1.0], .rainbow, belly: [1.0, 0.97, 0.90])
        }
    }
}
