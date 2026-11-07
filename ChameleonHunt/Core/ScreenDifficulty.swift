//
//  ScreenDifficulty.swift
//  The same chameleon is harder to spot on a phone than on a big iPad.
//
//  A chameleon across the room might be a centimetre tall on an iPhone's screen and two
//  and a half on a 13-inch iPad, and small things are much harder to pick out from what's
//  around them. Playtesters found Swarm and Squad a little too hard on a phone and a
//  little too easy on a big iPad. So during the hunt the chameleons adapt to the room a
//  touch less on a small screen and a touch more on a big one. It's a small change, and
//  it's worked out from the screen's physical size, so an iPad mini or a Pro Max falls
//  in between rather than landing on one side or the other.
//
//  What changes is the living camouflage's strength (LiveSkin.Settings.strength): the
//  most of the live camera colour that may show over the hider's paint. Less of it leaves
//  a little more of the paint, which was made from where the hider stood and so is a
//  little wrong from anywhere else. That is what a sharp-eyed seeker catches.
//

import Foundation

enum ScreenDifficulty {

    /// The screen size (diagonal, inches) that gets the base strength unchanged: between
    /// a phone and a big iPad, where playtesting said it was right.
    static let neutralInches: Float = 9.5
    /// How many inches either side of neutral reach the full shift.
    static let spanInches: Float = 3.5
    /// The most it moves the strength either way. Deliberately small.
    static let maximumShift: Float = 0.07

    /// The hunt's living camouflage strength on a screen this size.
    static func livingStrength(base: Float, diagonalInches: Float) -> Float {
        let t = min(max((diagonalInches - neutralInches) / spanInches, -1), 1)
        return min(max(base + maximumShift * t, 0), 1)
    }

    /// The screen's diagonal in inches, from its size in points. iOS doesn't say how many
    /// points make an inch, but it's close to fixed for each kind of device: about 153 on
    /// an iPhone, 132 on the bigger iPads and 163 on the iPad mini.
    static func diagonalInches(width: Float, height: Float, isPad: Bool) -> Float {
        let points = (width * width + height * height).squareRoot()
        let pointsPerInch: Float = isPad ? (points < 1400 ? 163 : 132) : 153
        return points / pointsPerInch
    }
}
