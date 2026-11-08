//
//  ProfileView.swift
//  You, as the game knows you (v7.9): your chameleon in its skin, your name, your record
//  (played, found, wins) and your best Swarm times.
//
//  The party games this one takes after all have a corner of the home screen that's
//  the player (Brawl Stars' profile, Among Us's stats, Fall Guys' crowns), and a game
//  played for bragging rights needs somewhere to keep them. It's also where the name
//  lives now (it was in Settings): Apple's guidelines ask games to let players present
//  themselves, and the name is what friends see in a squad.
//
//  A full page like Settings: a few cards on the stage, numbers as Readouts (facts, not
//  keys), nothing to press but the name.
//

import SwiftUI

struct ProfileView: View {
    @ObservedObject var store: GameStore
    @ObservedObject private var wallet = Wallet.shared
    @ObservedObject private var stats = Stats.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HuntBackground(focus: UnitPoint(x: 0.5, y: 0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Headline(text: "Profile", size: 52)
                    identity
                    card("Your record", systemImage: "chart.bar.fill") {
                        Readouts(items: [
                            .init(value: "\(stats.record.played)", label: "Played"),
                            .init(value: "\(stats.record.found)", label: "Found", tint: Hunt.pink),
                            .init(value: "\(stats.record.wins)", label: "Wins", tint: Hunt.sun),
                        ])
                        .frame(maxWidth: .infinity)
                    }
                    card("Swarm best times", systemImage: "trophy.fill") { bestTimes }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(Hunt.gutter)
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Pinned to the corner, like the other full-screen pages.
            IconButton(systemImage: "xmark", label: "Done") { dismiss() }
                .padding(Hunt.gutter)
        }
    }

    /// The chameleon in the skin being worn, and the name friends see.
    private var identity: some View {
        HStack(spacing: 18) {
            MascotImage(pose: .standing, view: .hero, resolution: 360, skin: wallet.skin)
                .padding(8)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Hunt.cardHigh))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                .background(Circle().fill(Hunt.ink).offset(y: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                NameField(name: $store.playerName, colour: SquadGame.preferredColour)
                Text("What friends see in a squad.")
                    .font(.chat(.subheadline, weight: .bold))
                    .foregroundStyle(Hunt.muted)
            }
        }
    }

    /// Each level's record: the most hidden, all found, the quickest.
    private var bestTimes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HuntDifficulty.allCases, id: \.self) { level in
                if level != HuntDifficulty.allCases.first {
                    Rectangle().fill(Hunt.text.opacity(0.22)).frame(height: 2)
                }
                HStack(spacing: 12) {
                    Text(level.title.uppercased())
                        .font(.hunt(22, relativeTo: .headline))
                        .foregroundStyle(Hunt.text)
                    Spacer(minLength: 8)
                    if let best = SwarmRecords.best(for: level, in: stats.swarmBests) {
                        Text("\(best.hidden) in \(GameConfig.stopwatch(best.seconds))")
                            .font(.hunt(22, relativeTo: .headline))
                            .monospacedDigit()
                            .foregroundStyle(Hunt.sun)
                    } else {
                        Text("Not yet")
                            .font(.chat(.subheadline, weight: .bold))
                            .foregroundStyle(Hunt.muted)
                    }
                }
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
            }
            Text("Every one found, without the hint. Each number hidden has its own record.")
                .font(.chat(.footnote, weight: .bold))
                .foregroundStyle(Hunt.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.hunt(20, relativeTo: .headline))
                .foregroundStyle(Hunt.text)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .huntPanel(padding: 18)
    }
}
