//
//  TrackingGuard.swift
//  When the chameleons can be shown, and when the device has to find its place in the
//  room again, from how well ARKit says it's tracking.
//
//  Two bugs from playtesting came from getting this wrong:
//
//  - A chameleon vanished the moment it was dropped, with no melting-in. Every chameleon
//    was hidden the instant tracking was anything but perfect, and for most of a second
//    after. But ARKit reports "moving too fast" or "not enough detail here" (a plain
//    white desk, close up) for a frame or two all the time, while still knowing where
//    it is. So: those states hide nothing unless they last, and nothing at all while
//    hiding, when the hider has to see what they've just put down.
//
//  - A hunt was paused, the iPad put down for a minute and picked up again, and the
//    chameleons were floating in mid-air. With its camera covered ARKit can't see, and it
//    doesn't notice being lifted off the floor; when it can see again it carries on from
//    where it thought it was, a metre below where it is, and draws everything a metre
//    out. Fading the chameleons while it couldn't see (the earlier fix) hid the wrong
//    moment: the picture is wrong *after* it can see again. So: once it has been blind
//    long enough during a hunt that it may have been moved, it must relocalise — match
//    what the camera sees against a map of the room saved while everything was right
//    (ARSessionController.refindRoom) — before anything is shown again.
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

struct TrackingGuard {

    /// ARKit's tracking state, boiled down.
    enum Quality: Equatable {
        /// Tracking normally.
        case good
        /// Still tracking, less surely: moving too fast, or little detail in view. Also
        /// what a covered camera reports.
        case shaky
        /// Not tracking: starting up, relocalising, or unavailable. Where things are
        /// drawn means nothing.
        case blind
    }

    /// Seconds a shaky spell can last during a hunt before the chameleons are hidden.
    static let shakyGrace: TimeInterval = 1.0
    /// Seconds of shaky tracking after which the device may have been moved without
    /// knowing it, and has to find its place again.
    static let lostAfter: TimeInterval = 3.0
    /// Seconds of good tracking before hidden chameleons come back.
    static let settle: TimeInterval = 0.4

    /// The chameleons shouldn't be drawn right now.
    private(set) var hidden = false
    private var shakySince: TimeInterval?
    private var goodSince: TimeInterval?
    private var askedToRefind = false

    /// Feed in each frame's tracking quality. `guarding`: a hunt is under way (or about
    /// to be), so where the chameleons are drawn has to be right; while hiding it's
    /// false, and only blindness hides them.
    /// Returns true, once per spell, when the device should find its place in the room
    /// again.
    mutating func update(_ quality: Quality, time: TimeInterval, guarding: Bool) -> Bool {
        switch quality {
        case .good:
            shakySince = nil
            askedToRefind = false
            if goodSince == nil { goodSince = time }
            if hidden, time - (goodSince ?? time) >= Self.settle { hidden = false }
            return false
        case .blind:
            // Not the same as shaky: this ends with ARKit knowing where it is (it has
            // relocalised), so it's no reason to ask again.
            goodSince = nil
            shakySince = nil
            hidden = true
            return false
        case .shaky:
            goodSince = nil
            guard guarding else {
                // Hiding: ARKit still knows where it is, near enough to see what's been
                // put down.
                shakySince = nil
                hidden = false
                return false
            }
            let since = shakySince ?? time
            shakySince = since
            if time - since >= Self.shakyGrace { hidden = true }
            if time - since >= Self.lostAfter, !askedToRefind {
                askedToRefind = true
                return true
            }
            return false
        }
    }

    mutating func reset() {
        self = TrackingGuard()
    }
}
