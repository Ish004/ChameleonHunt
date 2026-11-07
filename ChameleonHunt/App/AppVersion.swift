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
    static let number = "7.8"
    static let built = "7 Nov 2026"

    /// What changed in this build, for the home screen.
    static let summary = "Squad games that got stuck move on, and finds stay when someone leaves; best times in Swarm, fastest find in Squad; a way back when the camera is off"

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
