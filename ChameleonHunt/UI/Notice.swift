//
//  Notice.swift
//  Anything the game has to stop and ask or tell: "Too fast", "Change pose?", "Leave the
//  game?". Shown as a white sticker card that bounces in over a dimmed screen, in the
//  show's own lettering — never the system alert, which looked like a settings app had
//  interrupted the game.
//
//  A title that says what happened in two or three words, one sentence on what to do
//  about it, and at most two buttons: the likely one big and on the right.
//

import SwiftUI

struct Notice: Identifiable {
    struct Action {
        var title: String
        var systemImage: String? = nil
        var kind: HuntButtonStyle.Kind = .primary
        var run: @MainActor () -> Void = {}
    }

    let id = UUID()
    var title: String
    var message: String
    var systemImage: String
    /// The tile behind the symbol.
    var tint: Color = Hunt.sun
    var primary = Action(title: "OK")
    var secondary: Action? = nil

    static var needsLiDAR: Notice {
        Notice(title: "Needs LiDAR",
               message: "Paint & Hide scans the spot in 3D, which needs a Pro iPhone or iPad. Swarm and Squad work on this device.",
               systemImage: "sensor.tag.radiowaves.forward.fill")
    }

    static var needsAR: Notice {
        Notice(title: "No AR here",
               message: "This device can't place things in the room. The paint studio still works.",
               systemImage: "arkit")
    }
}

extension EnvironmentValues {
    /// Shows a notice over the whole app (set up once, in RootView), so a small control
    /// deep in a screen can still ask a full-screen question.
    @Entry var showNotice: @MainActor (Notice) -> Void = { _ in }
}

/// Shows a notice over whatever's underneath, and runs the chosen action.
struct NoticeView: View {
    let notice: Notice
    let dismiss: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Hunt.ink.opacity(shown ? 0.6 : 0).ignoresSafeArea()
                .onTapGesture {}
            VStack(spacing: 16) {
                Image(systemName: notice.systemImage)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(Hunt.ink)
                    .frame(width: 76, height: 76)
                    .sticker(notice.tint, radius: 38)
                Text(notice.title)
                    .font(.hunt(34, relativeTo: .title))
                    .foregroundStyle(Hunt.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(notice.message)
                    .font(.chat(.title3, weight: .medium))
                    .foregroundStyle(Hunt.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        if let secondary = notice.secondary { button(secondary, kind: .secondary) }
                        button(notice.primary, kind: notice.primary.kind)
                    }
                    // On a phone: the likely answer on top.
                    VStack(spacing: 12) {
                        button(notice.primary, kind: notice.primary.kind)
                        if let secondary = notice.secondary { button(secondary, kind: .secondary) }
                    }
                }
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .sticker(Hunt.paper, radius: 30, shadow: 8)
            .padding(Hunt.gutter)
            .scaleEffect(shown || reduceMotion ? 1 : 0.7)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.62)) { shown = true }
        }
        .sensoryFeedback(.warning, trigger: shown) { _, new in new }
        .accessibilityAddTraits(.isModal)
    }

    private func button(_ action: Notice.Action, kind: HuntButtonStyle.Kind) -> some View {
        Button {
            dismiss()
            action.run()
        } label: {
            if let symbol = action.systemImage {
                Label(action.title, systemImage: symbol)
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(HuntButtonStyle(kind: kind, fill: true))
    }
}

extension View {
    /// Shows `notice` as the game's own dialog while it's set.
    func notice(_ notice: Binding<Notice?>) -> some View {
        overlay {
            if let current = notice.wrappedValue {
                NoticeView(notice: current) { notice.wrappedValue = nil }
                    .id(current.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice.wrappedValue?.id)
    }
}
