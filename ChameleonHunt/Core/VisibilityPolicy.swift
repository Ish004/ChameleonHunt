//
//  VisibilityPolicy.swift
//  Whether to draw a chameleon at all, given how much of it is behind something real.
//
//  Two states — shown and hidden — and a fade between them, never a pop. This is the
//  whole-chameleon decision: once it's mostly covered, all of it goes rather than
//  leaving a sliver. Partly covered, only the covered chunks fade (ChameleonChunks).
//
//  It's deliberately lopsided — quick to hide, slow to come back — because the two
//  mistakes aren't equal. A chameleon that vanishes a moment early behind a wall costs
//  nothing. One still drawn over the wall for a second after the iPad swept past is a
//  white lizard on a black TV cabinet, which is how it got found in testing. (An earlier
//  version held every decision while the iPad moved, to stop blinks from bad depth
//  during fast motion; it stopped the blinks, but it also meant a quick sweep behind
//  something left it hanging in plain view.) So:
//
//   - Hiding happens at once, fast motion or not, and fades out in under a tenth of a
//     second.
//   - Coming back needs the iPad to have settled and the way to have been clear for
//     about 0.4 s, and fades in gently. A burst of bad depth during a swing therefore
//     hides it once, briefly — never flickers it.
//

import Foundation

struct VisibilityPolicy: Sendable {

    enum State: String, Sendable {
        case shown = "shown"
        case hidden = "hidden behind something"
    }

    struct Settings: Sendable {
        /// Coverage smoothing, rising and falling.
        var riseTime: Float = 0.02
        var fallTime: Float = 0.30
        /// Hide all of it once this much is behind something (less than that, the covered
        /// chunks fade on their own — see ChameleonChunks)…
        var hideAbove: Float = 0.6
        /// …and show it again once it's clearly coming out.
        var showBelow: Float = 0.4
        /// How long a change must hold before it happens.
        var dwellToHide: TimeInterval = 0
        var dwellToShow: TimeInterval = 0.40
        /// Camera speed (m/s plus rad/s) above which it won't come back.
        var freezeAboveMotion: Float = 0.9
        /// Fades: quick out, gentle in.
        var fadeOutTime: Float = 0.08
        var fadeInTime: Float = 0.3
    }

    private(set) var state: State = .shown
    private(set) var smoothedCoverage: Float = 0
    /// What to draw at, 0…1.
    private(set) var opacity: Float = 1

    private let settings: Settings
    private var pending: State?
    private var pendingSince: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    mutating func reset() {
        state = .shown
        smoothedCoverage = 0
        opacity = 1
        pending = nil
        lastTimestamp = 0
    }

    /// - Parameters:
    ///   - coverage: share of the chameleon behind real surfaces, 0…1.
    ///   - motion: camera speed, metres per second plus radians per second.
    /// - Returns: the opacity to draw at.
    @discardableResult
    mutating func update(coverage: Float, motion: Float = 0, timestamp: TimeInterval) -> Float {
        let elapsed = lastTimestamp > 0 ? Float(min(max(timestamp - lastTimestamp, 0), 0.5)) : 0
        lastTimestamp = timestamp

        let moving = motion > settings.freezeAboveMotion
        if coverage > smoothedCoverage {
            // Rising readings count at once, moving or not.
            smoothedCoverage += (coverage - smoothedCoverage) * (elapsed > 0 ? min(1, elapsed / settings.riseTime) : 1)
        } else if !moving {
            // Falling ones only once the iPad has settled.
            smoothedCoverage += (coverage - smoothedCoverage) * (elapsed > 0 ? min(1, elapsed / settings.fallTime) : 1)
        }

        let threshold = state == .shown ? settings.hideAbove : settings.showBelow
        let wanted: State = smoothedCoverage > threshold ? .hidden : .shown

        if wanted == state {
            pending = nil
        } else if wanted == .hidden {
            if settings.dwellToHide <= 0 {
                state = .hidden
                pending = nil
            } else if pending != .hidden {
                pending = .hidden
                pendingSince = timestamp
            } else if timestamp - pendingSince >= settings.dwellToHide {
                state = .hidden
                pending = nil
            }
        } else if moving {
            // Not while it's swinging round; start counting again once it settles.
            pending = nil
        } else if pending != .shown {
            pending = .shown
            pendingSince = timestamp
        } else if timestamp - pendingSince >= settings.dwellToShow {
            state = .shown
            pending = nil
        }

        let target: Float = state == .shown ? 1 : 0
        if elapsed > 0 {
            if opacity < target {
                opacity = min(target, opacity + elapsed / max(settings.fadeInTime, 0.001))
            } else {
                opacity = max(target, opacity - elapsed / max(settings.fadeOutTime, 0.001))
            }
        } else {
            opacity = target
        }
        return opacity
    }
}
