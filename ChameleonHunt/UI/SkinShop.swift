//
//  SkinShop.swift
//  Where coins go: the chameleon's skins, as a wardrobe (v7.9).
//
//  Laid out the way character customisers are in the games and apps people already know
//  (Tolan, Snapchat's Bitmoji, Meta's avatars, Replika, Alan): the chameleon big on its
//  stage, wearing whatever was tapped last; every skin a small tile underneath with its
//  price on it; and one key under the chameleon that does the one thing that skin allows
//  — wear it, get it, or nothing yet, with how many more coins it takes. Until v7.8
//  every skin was a card with its own key, and nothing could be tried on before buying.
//
//  Skins are looks only (Core/ChameleonSkin.swift); the page says so, once, at the bottom.
//

import SwiftUI

struct SkinShopView: View {
    @ObservedObject private var wallet = Wallet.shared
    @Environment(\.dismiss) private var dismiss
    @State private var notice: Notice?
    /// The skin being tried on; nil shows the one worn.
    @State private var trying: ChameleonSkin?
    /// A little hop when one is put on.
    @State private var hop = false

    private var shown: ChameleonSkin { trying ?? wallet.skin }

    /// The rails of the wardrobe, cheapest first.
    private struct Rail: Identifiable {
        let title: String
        let skins: [ChameleonSkin]
        var id: String { title }
    }

    private static let rails: [Rail] = [
        Rail(title: "Colours", skins: ChameleonSkin.allCases.filter { $0.price <= 150 }),
        Rail(title: "Patterns", skins: ChameleonSkin.allCases.filter { $0.price > 150 && $0.price < 1000 }),
        Rail(title: "Rare", skins: ChameleonSkin.allCases.filter { $0.price >= 1000 }),
    ]

    private let columns = [GridItem(.adaptive(minimum: 86, maximum: 124), spacing: 12)]

    var body: some View {
        GeometryReader { proxy in
            // Wide (an iPad, or a phone on its side): the chameleon on the left, the rails
            // on the right. Upright: the chameleon on top.
            let wide = proxy.size.width > proxy.size.height
            ZStack(alignment: .topTrailing) {
                HuntBackground(focus: wide ? UnitPoint(x: 0.24, y: 0.55) : UnitPoint(x: 0.5, y: 0.22))
                if wide {
                    HStack(alignment: .center, spacing: Hunt.gutter) {
                        stage(disc: min(proxy.size.height * 0.4, 300))
                            .frame(width: proxy.size.width * 0.4)
                        VStack(alignment: .leading, spacing: 14) {
                            title
                            rails
                        }
                    }
                    .padding(Hunt.gutter)
                } else {
                    VStack(spacing: 14) {
                        title
                        stage(disc: min(proxy.size.width * 0.52, proxy.size.height * 0.24, 260))
                        rails
                    }
                    .padding(.horizontal, Hunt.gutter)
                    .padding(.top, Hunt.gutter)
                }
                IconButton(systemImage: "xmark", label: "Close") { dismiss() }
                    .padding(Hunt.gutter)
            }
        }
        .notice($notice)
    }

    /// The page's name and the coins, with room on the right for the close key.
    private var title: some View {
        HStack(spacing: 14) {
            Headline(text: "Skins", size: 44)
            HStack(spacing: 8) {
                CoinIcon(size: 24)
                Text("\(wallet.coins)")
                    .font(.hunt(26, relativeTo: .title2)).monospacedDigit()
                    .foregroundStyle(Hunt.ink)
                    .contentTransition(.numericText(value: Double(wallet.coins)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .sticker(Hunt.paper, radius: 18)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: wallet.coins)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(wallet.coins) coins")
            Spacer(minLength: 64)
        }
    }

    /// The chameleon on its stage in what's being tried on, its name, and the one key.
    private func stage(disc: CGFloat) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Hunt.cardHigh)
                    .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 4))
                    .background(Circle().fill(Hunt.ink).offset(y: 8))
                    .frame(width: disc, height: disc)
                MascotImage(pose: .standing, view: .hero, resolution: 720, skin: shown)
                    .frame(width: disc * 0.88, height: disc * 0.88)
                    .offset(y: disc * 0.03)
                    .scaleEffect(x: hop ? 0.94 : 1, y: hop ? 1.1 : 1, anchor: .bottom)
                    .animation(.spring(response: 0.25, dampingFraction: 0.45), value: hop)
            }
            .accessibilityElement()
            .accessibilityLabel("Your chameleon in \(shown.title)")
            Text(shown.title.uppercased())
                .font(.hunt(30, relativeTo: .title2))
                .foregroundStyle(Hunt.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            key.frame(minHeight: 72)
        }
    }

    /// What can be done with the skin on the stage: wear it, get it, or nothing yet.
    @ViewBuilder private var key: some View {
        if shown == wallet.skin {
            // A tag, not a key: there's nothing to do.
            Label("Wearing", systemImage: "checkmark")
                .font(.hunt(22, relativeTo: .title3))
                .foregroundStyle(Hunt.ink)
                .padding(.horizontal, 24)
                .frame(minHeight: 52)
                .sticker(Hunt.lime, radius: 18, shadow: 0)
        } else if wallet.owns(shown) {
            Button { wear(shown) } label: {
                Label("Wear", systemImage: "tshirt.fill").frame(minWidth: 180)
            }
            .buttonStyle(.huntBig)
        } else if wallet.canAfford(shown) {
            Button { askToBuy(shown) } label: {
                HStack(spacing: 10) {
                    CoinIcon(size: 26)
                    Text("Get for \(shown.price)").monospacedDigit()
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(HuntButtonStyle(kind: .sun, large: true))
            .accessibilityLabel("Get for \(shown.price) coins")
        } else {
            // Not a key: there's nothing to press yet, only a number to play for.
            HStack(spacing: 8) {
                CoinIcon(size: 22)
                Text("\(shown.price)").monospacedDigit()
                Text("· \(shown.price - wallet.coins) more").opacity(0.8)
            }
            .font(.hunt(22, relativeTo: .title3))
            .foregroundStyle(Hunt.muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(shown.price) coins. \(shown.price - wallet.coins) more to go.")
        }
    }

    /// Every skin, on its rail.
    private var rails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.rails) { rail in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(rail.title.uppercased())
                            .font(.hunt(18, relativeTo: .headline))
                            .foregroundStyle(Hunt.text)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(rail.skins) { skin in tile(skin) }
                        }
                    }
                }
                Label("Find chameleons to earn coins. Skins show before yours blends in; they all hide the same.",
                      systemImage: "info.circle.fill")
                    .font(.chat(.subheadline, weight: .bold))
                    .foregroundStyle(Hunt.muted)
            }
            .padding(.top, 4)
            .padding(.bottom, Hunt.gutter)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// One skin: tap to try it on.
    private func tile(_ skin: ChameleonSkin) -> some View {
        let selected = skin == shown
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let status: String = skin == wallet.skin ? "Wearing" : wallet.owns(skin) ? "Yours" : "\(skin.price) coins"
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { trying = skin }
            Sound.shared.play(.tap)
        } label: {
            MascotImage(pose: .standing, view: .hero, resolution: 240, skin: skin)
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(shape.fill(selected ? Hunt.cardHigh : Hunt.card))
                .overlay(shape.strokeBorder(selected ? Hunt.lime : Hunt.ink, lineWidth: selected ? 4 : Hunt.outline))
                .background(shape.fill(Hunt.ink).offset(y: 4))
                .overlay(alignment: .bottomTrailing) { badge(skin).offset(x: 4, y: 6) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skin.title)
        .accessibilityValue(status)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The corner of a tile: a tick on the one worn, the price on the ones not owned yet
    /// (sun when it can be had now), nothing on the rest.
    @ViewBuilder private func badge(_ skin: ChameleonSkin) -> some View {
        if skin == wallet.skin {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Hunt.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Hunt.lime))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2.5))
        } else if !wallet.owns(skin) {
            HStack(spacing: 4) {
                CoinIcon(size: 13)
                Text("\(skin.price)").font(.hunt(14, relativeTo: .caption)).monospacedDigit()
            }
            .foregroundStyle(Hunt.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(wallet.canAfford(skin) ? Hunt.sun : Hunt.paper))
            .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2))
        }
    }

    private func askToBuy(_ skin: ChameleonSkin) {
        notice = Notice(title: "Get \(skin.title)?", message: "\(skin.price) coins. You'll have \(wallet.coins - skin.price) left.",
                        systemImage: "tshirt.fill", tint: Hunt.sun,
                        primary: .init(title: "Get it") { buy(skin) },
                        secondary: .init(title: "Not now"))
    }

    private func buy(_ skin: ChameleonSkin) {
        guard wallet.buy(skin) else { return }
        Sound.shared.play(.found)
        putOn()
    }

    private func wear(_ skin: ChameleonSkin) {
        wallet.wear(skin)
        Sound.shared.play(.poke)
        putOn()
    }

    /// Now it's the one worn: the stage shows that, with a hop.
    private func putOn() {
        trying = nil
        hop = true
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            hop = false
        }
    }
}
