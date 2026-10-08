//
//  AppVersion.swift
//  One place to say which build this is.
//
//  Shown on the home screen so there is never any doubt that a change actually reached
//  the iPad — a rebuild that didn't install looks exactly like a fix that didn't work.
//  Bump `number` with every change, and say what changed in `summary`.
//

import Foundation

enum AppVersion {
    static let number = "7.5"
    static let built = "8 Oct 2026"

    /// What changed in this build, for the home screen.
    static let summary = "Hint key is a plain Hint again (its cost is on the card it opens) · the card says it plainly: each find earns half the coins for the rest of the hunt"

    /// The build label while testing; in the App Store build, the version players see
    /// there ("Version 1.0"), so the two never disagree.
    static var label: String {
        #if DEBUG
        "v\(number) · \(built)"
        #else
        "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
        #endif
    }
}
