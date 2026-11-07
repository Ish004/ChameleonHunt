//
//  DesignSystem.swift
//  The paint studio's kit. Laid out like iPad painting apps (Procreate above all), dressed
//  like the rest of the show (HuntKit.swift): white stickers with ink edges floating over
//  the 3D view, lime for what's chosen, Lilita for labels.
//

import SwiftUI

enum Palette {
    static let text = Hunt.ink
    static let textDim = Hunt.inkMuted
    static let hairline = Hunt.ink
    static let ink = Hunt.ink
    /// The chameleon's green, as everywhere else in the game.
    static let leaf = Hunt.lime
    static let lichen = Hunt.lime
}

enum Metric {
    static let gutter: CGFloat = 24
    static let cardRadius: CGFloat = 24
    static let controlRadius: CGFloat = 16
    /// Minimum comfortable hit target.
    static let tap: CGFloat = 50
    /// Width of the single column that menu screens use on an iPad.
    static let column: CGFloat = 460
}

extension Font {
    /// Sentences in the studio: SF Rounded.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Numbers that line up as they change.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("LilitaOne", size: size, relativeTo: .headline).monospacedDigit()
    }
}

// MARK: - Buttons

/// The studio's main action: the lime sticker key, as everywhere else.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Hunt.lime

    func makeBody(configuration: Configuration) -> some View {
        HuntButtonStyle().makeBody(configuration: configuration)
    }
}

/// A white sticker for controls over the studio's 3D view.
struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .foregroundStyle(Hunt.ink)
            .background(Capsule().fill(Hunt.paper))
            .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
            .offset(y: pressed ? 3 : 0)
            .background(Capsule().fill(Hunt.ink).offset(y: 4))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
    }
}

/// A tool in the rail: lime and pressed in when it's the one in use.
struct ToolButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
        configuration.label
            .foregroundStyle(Hunt.ink)
            .background(shape.fill(selected ? Hunt.lime : (configuration.isPressed ? Hunt.paperLip : Hunt.paper)))
            .overlay(shape.strokeBorder(Hunt.ink, lineWidth: selected ? Hunt.outline : 0))
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: selected)
    }
}

/// A full-screen "working on it" for when there really is nothing to do but wait.
struct BusyOverlay: View {
    let message: String
    let progress: Float

    var body: some View {
        ZStack {
            Hunt.ink.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                MascotImage(pose: .curled, view: .hero, resolution: 360)
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)
                Text(message).font(.hunt(26, relativeTo: .title2)).foregroundStyle(Hunt.ink)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Hunt.paperLip)
                        Capsule().fill(Hunt.lime).frame(width: max(16, proxy.size.width * CGFloat(max(progress, 0.03))))
                    }
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                }
                .frame(width: 260, height: 18)
            }
            .padding(28)
            .sticker(Hunt.paper, radius: 28, shadow: 6)
        }
    }
}

/// A card that drops down from a button: a white sticker with a little pointer, and a
/// tap anywhere else closes it. Used instead of the system popover and menus, which
/// looked like a settings app had interrupted the game.
struct DropCard<Content: View>: View {
    @Binding var isPresented: Bool
    var alignment: Alignment = .topTrailing
    var width: CGFloat = 340
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: alignment) {
            Color.black.opacity(0.001).ignoresSafeArea()
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)
            content
                .frame(width: width)
                .padding(18)
                .sticker(Hunt.paper, radius: 24, shadow: 6)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: alignment == .topLeading ? .topLeading : .topTrailing)
                    .combined(with: .opacity))
        }
        .accessibilityAddTraits(.isModal)
    }
}
