//
//  SkinShop.swift
//  Where coins go: the chameleon's skins.
//
//  A full page in the game's own look, like Settings: the coins you have, and every skin
//  as a card with the chameleon wearing it. A card's one key says what tapping it does:
//  the price (with the coin), "Wear", or nothing at all on the one being worn, which
//  carries a tag instead. A skin you can't afford yet says how many more coins it takes,
//  so there's always a number to play for.
//
//  Skins are looks only (Core/ChameleonSkin.swift); the page says so, once, at the bottom.
//

import SwiftUI

struct SkinShopView: View {
    @ObservedObject private var wallet = Wallet.shared
    @Environment(\.dismiss) private var dismiss
    @State private var notice: Notice?
    /// The one just bought, for its little hop.
    @State private var celebrated: ChameleonSkin?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 14, alignment: .top)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HuntBackground(focus: UnitPoint(x: 0.5, y: 0))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Headline(text: "Skins", size: 52)
                    HStack(spacing: 10) {
                        CoinIcon(size: 30)
                        Text("\(wallet.coins)")
                            .font(.hunt(34, relativeTo: .title)).monospacedDigit()
                            .foregroundStyle(Hunt.ink)
                            .contentTransition(.numericText(value: Double(wallet.coins)))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .sticker(Hunt.paper, radius: 20)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: wallet.coins)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(wallet.coins) coins")

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ChameleonSkin.allCases) { skin in
                            SkinCard(skin: skin, wallet: wallet, hopping: celebrated == skin) { tapped(skin) }
                        }
                    }

                    Label("Find chameleons to earn coins. Skins show before yours blends in; they all hide the same.",
                          systemImage: "info.circle.fill")
                        .font(.chat(.subheadline, weight: .bold))
                        .foregroundStyle(Hunt.muted)
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(Hunt.gutter)
                .frame(maxWidth: .infinity)
            }
            IconButton(systemImage: "xmark", label: "Close") { dismiss() }
                .padding(Hunt.gutter)
        }
        .notice($notice)
    }

    private func tapped(_ skin: ChameleonSkin) {
        if wallet.owns(skin) {
            wallet.wear(skin)
            Sound.shared.play(.tap)
        } else if wallet.canAfford(skin) {
            notice = Notice(title: "Get \(skin.title)?", message: "\(skin.price) coins. You'll have \(wallet.coins - skin.price) left.",
                            systemImage: "tshirt.fill", tint: Hunt.sun,
                            primary: .init(title: "Get it") { buy(skin) },
                            secondary: .init(title: "Not now"))
        }
    }

    private func buy(_ skin: ChameleonSkin) {
        guard wallet.buy(skin) else { return }
        Sound.shared.play(.found)
        celebrated = skin
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            if celebrated == skin { celebrated = nil }
        }
    }
}

/// One skin: the chameleon in it, its name, and the one thing you can do with it.
private struct SkinCard: View {
    let skin: ChameleonSkin
    @ObservedObject var wallet: Wallet
    let hopping: Bool
    let action: () -> Void

    private var wearing: Bool { wallet.skin == skin }
    private var owned: Bool { wallet.owns(skin) }
    private var affordable: Bool { wallet.canAfford(skin) }

    var body: some View {
        VStack(spacing: 8) {
            MascotImage(pose: .standing, view: .hero, resolution: 360, skin: skin)
                .frame(maxWidth: 150)
                .scaleEffect(x: hopping ? 0.94 : 1, y: hopping ? 1.12 : 1, anchor: .bottom)
                .animation(.spring(response: 0.25, dampingFraction: 0.4), value: hopping)
                .accessibilityHidden(true)
            Text(skin.title.uppercased())
                .font(.hunt(20, relativeTo: .headline))
                .foregroundStyle(Hunt.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            key
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .sticker(wearing ? Hunt.cardHigh : Hunt.card, radius: 22, shadow: 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var key: some View {
        if wearing {
            Label("Wearing", systemImage: "checkmark")
                .font(.hunt(18, relativeTo: .headline))
                .foregroundStyle(Hunt.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .sticker(Hunt.lime, radius: 18, shadow: 0)
                .padding(.bottom, Hunt.depth)
        } else if owned {
            Button(action: action) { Text("Wear") }
                .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
        } else if affordable {
            Button(action: action) {
                HStack(spacing: 7) {
                    CoinIcon(size: 20)
                    Text("\(skin.price)").monospacedDigit()
                }
            }
            .buttonStyle(HuntButtonStyle(kind: .sun, fill: true))
            .accessibilityLabel("Get for \(skin.price) coins")
        } else {
            // Not a key: there's nothing to press yet, only a number to play for.
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    CoinIcon(size: 18)
                    Text("\(skin.price)").font(.hunt(18, relativeTo: .headline)).monospacedDigit()
                }
                Text("\(skin.price - wallet.coins) more")
                    .font(.chat(.caption, weight: .bold))
            }
            .foregroundStyle(Hunt.muted)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Hunt.ink.opacity(0.3)))
            .padding(.bottom, Hunt.depth)
            .accessibilityLabel("\(skin.price) coins. \(skin.price - wallet.coins) more to go.")
        }
    }
}
