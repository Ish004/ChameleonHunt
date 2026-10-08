//
//  ChameleonTags.swift
//  Name tags over the chameleons in a squad game, so it's plain who found which.
//
//  In playtesting, found chameleons turning the finder's colour wasn't enough on its own:
//  people didn't know what the colours meant. A tag says it outright, on a sticker in the
//  same colour as the chameleon:
//   - a found one: who found whose ("Ben found Cy's", "You found Dee's", "Ana found
//     yours"), in the finder's colour, with a magnifier;
//   - at the end (or once you've given up), one nobody found: "Cy's · not found", in the
//     hider's colour, with a crossed-out eye;
//   - your own during the hunt, if you've chosen to see them: "Yours", on white.
//  (v6.8's tags gave only the finder's name, which read as "whose" as often as "who".)
//
//  Kept apart from the session controller so a dozen tags moving a dozen times a second
//  only redraw the tags, not every view watching the controller.
//

import SwiftUI

@MainActor
final class ChameleonTags: ObservableObject {

    struct Tag: Identifiable, Equatable {
        enum Kind: Equatable { case found, notFound, mine }
        let id: UUID
        var point: CGPoint
        var name: String
        var colour: Color
        var kind: Kind
    }

    @Published private(set) var tags: [Tag] = []

    func show(_ next: [Tag]) {
        // Positions to the nearest half point: no redraw for sub-pixel wobble.
        let rounded = next.map { tag -> Tag in
            var t = tag
            t.point = CGPoint(x: (tag.point.x * 2).rounded() / 2, y: (tag.point.y * 2).rounded() / 2)
            return t
        }
        if rounded != tags { tags = rounded }
    }

    func clear() {
        if !tags.isEmpty { tags = [] }
    }

    #if DEBUG
    /// Tags where chameleons might be, to lay them out in the Simulator (which has no AR).
    func debugSample(in size: CGSize) {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: size.width * x, y: size.height * y) }
        tags = [
            Tag(id: UUID(), point: at(0.28, 0.42), name: "You found Cy's", colour: Hunt.player(0), kind: .found),
            Tag(id: UUID(), point: at(0.7, 0.3), name: "Ben found yours", colour: Hunt.player(1), kind: .found),
            Tag(id: UUID(), point: at(0.5, 0.6), name: "Dee's · not found", colour: Hunt.player(3), kind: .notFound),
            Tag(id: UUID(), point: at(0.3, 0.75), name: "Yours", colour: Hunt.paper, kind: .mine),
        ]
    }
    #endif
}
