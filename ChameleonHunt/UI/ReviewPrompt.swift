//
//  ReviewPrompt.swift
//  Asks for an App Store rating at a good moment: straight after a win, once a few rounds
//  have been played, and at most once per version. (iOS itself shows it at most three
//  times a year, and never if the player has turned rating requests off.)
//
//  Ratings decide a lot of where a game shows up in the App Store, and players rate most
//  generously just after something went well — never mid-game, never after a loss.
//

import StoreKit
import SwiftUI

struct ReviewPrompt: ViewModifier {
    /// Whether this screen is a happy moment (a win).
    let happyMoment: Bool
    @Environment(\.requestReview) private var requestReview
    @AppStorage("roundsFinished") private var roundsFinished = 0
    @AppStorage("reviewAskedForVersion") private var askedForVersion = ""

    /// The version players see in the App Store ("1.0"), not the build label.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    func body(content: Content) -> some View {
        content.task {
            roundsFinished += 1
            guard happyMoment, roundsFinished >= 3, askedForVersion != version else { return }
            // Let the win land first.
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            askedForVersion = version
            requestReview()
        }
    }
}

extension View {
    /// See ReviewPrompt. Put it on a results screen.
    func asksForReview(after happyMoment: Bool) -> some View {
        modifier(ReviewPrompt(happyMoment: happyMoment))
    }
}
