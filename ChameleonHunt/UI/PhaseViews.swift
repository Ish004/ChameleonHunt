//
//  PhaseViews.swift
//  Every screen of a one-device round, in the order they're played. Squad screens are
//  in SquadViews.swift; the look is in HuntKit.swift.
//
//  Menus are the show's stage: electric violet, rays turning behind the chameleon, big
//  sticker cards to press. Camera screens keep the room clear: a white sticker at the
//  top saying what to do in a few words, one big button at the bottom to do it, and
//  the way out always first, top left.
//

import CoreMotion
import SwiftUI

// MARK: - Home

/// What this device can do: everything (LiDAR), the cut-down games (AR without LiDAR),
/// or only the paint studio.
fileprivate enum DeviceCapability {
    case lidar, noLiDAR, noAR

    @MainActor static var current: DeviceCapability {
        #if DEBUG
        // For Simulator screenshots: `-debugLiDAR` as on a Pro device, `-debugNoLiDAR` as on the rest.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-debugLiDAR") { return .lidar }
        if args.contains("-debugNoLiDAR") { return .noLiDAR }
        #endif
        if ARSessionController.isLiDARAvailable { return .lidar }
        return ARSessionController.isARAvailable ? .noLiDAR : .noAR
    }
}

/// The title screen, the way the best-loved party games do it (Among Us, Fall Guys,
/// Crossy Road): the logo, the star doing its trick in the middle — tap it — and two big
/// choices at the bottom. Pass & Play is this device, handed round; Squad is everyone on
/// their own. Which one-device game comes next, on its own screen. Help, settings and
/// the practice studio are small round buttons in the corners. No paragraphs.
struct IntroView: View {
    @ObservedObject var store: GameStore
    @State private var showSettings = false
    @State private var showHowTo = false
    @State private var showSkins = false
    @ObservedObject private var wallet = Wallet.shared
    /// The very first launch opens How to play once, before anything else.
    @AppStorage("seenHowTo") private var seenHowTo = false
    private let capability = DeviceCapability.current

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HuntBackground(focus: UnitPoint(x: 0.5, y: 0.48))
                title(in: proxy.size)
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(store: store, ar: store.ar, presenter: store.ar.presenter).statusBarHidden(true)
        }
        .fullScreenCover(isPresented: $showHowTo) { HowToPlaySheet().statusBarHidden(true) }
        .fullScreenCover(isPresented: $showSkins) { SkinShopView().statusBarHidden(true) }
        .onAppear {
            MascotLibrary.shared.warmUp()
            #if DEBUG
            // `-debugSettings` / `-debugHowTo` / `-debugSkins` open straight onto those, for screenshots.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-debugSettings") { showSettings = true }
            if args.contains("-debugHowTo") { showHowTo = true }
            if args.contains("-debugSkins") { showSkins = true }
            #endif
            if !seenHowTo {
                seenHowTo = true
                if !showSettings && !showHowTo && !showSkins { showHowTo = true }
            }
        }
    }

    private func title(in size: CGSize) -> some View {
        // A big screen gets big type and big keys; a phone, the usual.
        let roomy = min(size.width, size.height) > 600
        // A phone on its side hasn't the height for logo, chameleon and keys one above the
        // other (the chameleon shrank to a coin): the chameleon goes on the left instead.
        let sideways = size.width > size.height && size.height < 500
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconButton(systemImage: "paintbrush.pointed.fill", label: "Practice painting") { store.openDemo(surface: .floor) }
                // The coins, and the way to what they buy.
                Button { showSkins = true } label: {
                    HStack(spacing: 8) {
                        CoinIcon(size: 22)
                        Text("\(wallet.coins)").monospacedDigit()
                        // The word where there's room for it; the wardrobe symbol on a phone.
                        if roomy {
                            Text("Skins").opacity(0.55)
                        } else {
                            Image(systemName: "tshirt.fill").font(.system(size: 15, weight: .black)).opacity(0.55)
                        }
                    }
                    .fixedSize()
                }
                .buttonStyle(.huntSecondary)
                .accessibilityLabel("Skins. You have \(wallet.coins) coins.")
                Spacer()
                IconButton(systemImage: "questionmark", label: "How to play") { showHowTo = true }
                IconButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
            }
            .padding(.horizontal, Hunt.gutter)
            .padding(.top, Hunt.gutter)

            if sideways {
                HStack(spacing: 0) {
                    ChameleonStage()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 18) {
                        logo(scales: [0.75])
                        VStack(spacing: 12) {
                            keys(roomy: false)
                            paintAndHide
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Hunt.gutter)
                .padding(.bottom, Hunt.gutter)
            } else {
                logo(scales: roomy ? [1.45, 1.1] : [1, 0.75])
                    .padding(.horizontal, 8)
                    .frame(maxHeight: size.height * 0.26)

                ChameleonStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: roomy ? 18 : 12) {
                    RowOrColumn(columnAlignment: .center, spacing: 16) { keys(roomy: roomy) }
                    paintAndHide
                }
                .padding(.horizontal, Hunt.gutter)
                .padding(.bottom, Hunt.gutter)
            }
        }
    }

    /// The two main games, each saying who it's for — the squad game first — and the
    /// painting game as a smaller key under them.
    @ViewBuilder private func keys(roomy: Bool) -> some View {
        Button {
            if capability == .noAR { store.notice = .needsAR; return }
            store.openSquad()
        } label: {
            ModeKeyLabel(title: "Squad", line: "Everyone on their own phone", icon: "person.3.fill", roomy: roomy)
        }
        .buttonStyle(HuntButtonStyle(large: true, hero: roomy))
        Button {
            if capability == .noAR { store.notice = .needsAR; return }
            store.beginScatter()
        } label: {
            ModeKeyLabel(title: "Swarm",
                         line: UIDevice.current.userInterfaceIdiom == .pad ? "One iPad, passed round" : "One phone, passed round",
                         icon: "lizard.fill", roomy: roomy)
        }
        .buttonStyle(HuntButtonStyle(kind: .secondary, large: true, hero: roomy))
    }

    private var paintAndHide: some View {
        Button {
            if capability == .noAR { store.notice = .needsAR; return }
            capability == .lidar ? store.beginHiding() : (store.notice = .needsLiDAR)
        } label: {
            HStack(spacing: 8) {
                Label("Paint & Hide", systemImage: "paintbrush.pointed.fill")
                if capability != .lidar {
                    Text("NEEDS LIDAR")
                        .font(.hunt(12, relativeTo: .caption2))
                        .foregroundStyle(Hunt.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .sticker(Hunt.sun, radius: 6, shadow: 1.5)
                }
            }
        }
        .buttonStyle(.huntGhost)
    }

    /// The name on one line if it fits, otherwise stacked; at the biggest scale that fits
    /// both ways, falling back to `smallest`. (Measured both ways: at large text sizes the
    /// stacked name used to run off the sides of a phone.)
    private func logo(scales: [CGFloat], smallest: CGFloat = 0.55) -> some View {
        ViewThatFits {
            if let first = scales.first { logoRow(first); logoStack(first) }
            if scales.count > 1 { logoRow(scales[1]); logoStack(scales[1]) }
            logoStack(smallest)
            logoStack(smallest * 0.75)
        }
        .rotationEffect(.degrees(-3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chameleon Hunt")
        .accessibilityAddTraits(.isHeader)
    }

    private func logoRow(_ scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14 * scale) {
            ShowText(text: "CHAMELEON", size: 72 * scale)
            ShowText(text: "HUNT", size: 72 * scale, fill: Hunt.lime)
        }
        .padding(.vertical, 8)
    }

    private func logoStack(_ scale: CGFloat) -> some View {
        VStack(spacing: -10 * scale) {
            ShowText(text: "CHAMELEON", size: 64 * scale)
            ShowText(text: "HUNT", size: 80 * scale, fill: Hunt.lime)
        }
        .padding(.vertical, 8)
    }
}

/// A home key's words: the game, and who it's for, so it's plain which is played together
/// and which on one device.
private struct ModeKeyLabel: View {
    let title: String
    let line: String
    let icon: String
    let roomy: Bool

    var body: some View {
        VStack(spacing: 1) {
            Label(title, systemImage: icon)
            Text(line)
                .font(.chat(roomy ? .subheadline : .caption, weight: .bold))
                .opacity(0.72)
        }
        .padding(.vertical, roomy ? 6 : 4)
        .frame(minWidth: roomy ? 300 : 230)
    }
}


/// The home screen's little show: the chameleon turns the colour of the disc it's on
/// until only its eyes are left, then pops back to green on a new colour.
///
/// The colour washes up it from the feet with a bright edge, the way the chameleons blend
/// in during the game. Tap it and it does the trick on the spot (or pops back out of it).
/// It breathes while it waits, and the whole stage tilts a little as the device does —
/// the parallax of the iOS Home Screen — so it feels like an object, not a picture.
/// Everything here is two pictures and a few transforms, so it stays smooth.
private struct ChameleonStage: View {
    private let colours: [(tint: MascotTint, fill: Color)] = [
        (.sun, Hunt.sun), (.bubblegum, Hunt.pink), (.sky, Hunt.cyan),
    ]
    @State private var index = 0
    /// How far up the colour has washed, 0…1.
    @State private var wash: CGFloat = 0
    @State private var washing = false
    @State private var hop = false
    @State private var breathe = false
    @State private var lastTap = Date.distantPast
    @StateObject private var tilt = DeviceTilt()
    @ObservedObject private var wallet = Wallet.shared
    @AppStorage("pokedChameleon") private var hasPoked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var colour: (tint: MascotTint, fill: Color) { colours[index % colours.count] }

    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width * 0.84, proxy.size.height * 0.84)
            let side = d * 0.8
            ZStack {
                Circle()
                    .fill(colour.fill)
                    .overlay(DotDisc(color: Hunt.ink.opacity(0.1)))
                    .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 5))
                    .background(Circle().fill(Hunt.ink).offset(y: 10))
                    .frame(width: d, height: d)
                    .offset(x: -tilt.x * 6, y: -tilt.y * 6)
                chameleon(side: side)
                    .frame(width: side, height: side)
                    .offset(y: d * 0.05)
                    .scaleEffect(x: hop ? 0.94 : 1, y: hop ? 1.1 : (breathe ? 1.018 : 1), anchor: .bottom)
                    .offset(x: tilt.x * 10, y: tilt.y * 10)
                if !hasPoked {
                    Label("Tap me", systemImage: "hand.tap.fill")
                        .font(.hunt(18, relativeTo: .headline))
                        .foregroundStyle(Hunt.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .sticker(Hunt.paper, radius: 14, shadow: 3)
                        .rotationEffect(.degrees(-6))
                        .offset(x: d * 0.3, y: d * 0.42)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .rotation3DEffect(.degrees(tilt.x * 8), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(-tilt.y * 8), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Circle().inset(by: max(0, (min(proxy.size.width, proxy.size.height) - d) / 2)))
            .onTapGesture { poke() }
        }
        .task { await perform() }
        .onAppear {
            if !reduceMotion {
                tilt.start()
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .onDisappear { tilt.stop() }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasPoked)
        .accessibilityElement()
        .accessibilityLabel("A chameleon that changes colour to disappear into the circle behind it")
        .accessibilityHint("Double-tap to make it hide.")
        .accessibilityAction { poke() }
    }

    /// Green underneath; the disc's colour washing up over it from the feet, with a bright
    /// edge where it's changing.
    private func chameleon(side: CGFloat) -> some View {
        ZStack {
            MascotImage(pose: .standing, view: .hero, resolution: 720, skin: wallet.skin)
            MascotImage(pose: .standing, view: .hero, resolution: 720, tint: colour.tint)
                .mask(alignment: .bottom) { Rectangle().frame(height: side * wash) }
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: side * 0.08)
                .offset(y: side * (0.5 - wash))
                .mask { MascotImage(pose: .standing, view: .hero, resolution: 720) }
                .blendMode(.plusLighter)
                .opacity(washing ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// A tap: it does its trick now, or pops back out of it.
    private func poke() {
        lastTap = Date()
        if !hasPoked { hasPoked = true }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Sound.shared.play(.poke)
        if wash > 0.5 { popOut() } else { blend() }
    }

    private func blend() {
        washing = !reduceMotion
        withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 1.2)) { wash = 1 }
        Task {
            try? await Task.sleep(for: .seconds(1.25))
            washing = false
        }
    }

    private func popOut(nextColour: Bool = false) {
        withAnimation(.easeOut(duration: 0.18)) {
            wash = 0
            if nextColour { index += 1 }
        }
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) { hop = true }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { hop = false }
        }
    }

    private func perform() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            // Let a tapped trick play out before the show carries on.
            guard Date().timeIntervalSince(lastTap) > 4 else { continue }
            if wash < 0.5 { blend() }
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, Date().timeIntervalSince(lastTap) > 4 else { continue }
            popOut(nextColour: true)
        }
    }

    private struct DotDisc: View {
        let color: Color
        var body: some View {
            Canvas { canvas, size in
                let spacing = size.width / 9
                var row = 0
                var y = spacing / 2
                while y < size.height {
                    var x = row % 2 == 0 ? spacing / 2 : spacing
                    while x < size.width {
                        let r = spacing * 0.2
                        canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
                        x += spacing
                    }
                    y += spacing * 0.87
                    row += 1
                }
            }
            .clipShape(Circle())
        }
    }
}

/// How far the device is tipped from how it was held when the screen appeared, as −1…1
/// across and up the screen — for a Home Screen–style parallax.
@MainActor
private final class DeviceTilt: ObservableObject {
    @Published private(set) var x: Double = 0
    @Published private(set) var y: Double = 0
    private let motion = CMMotionManager()
    private var rest: (x: Double, y: Double)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let g = data.gravity
            MainActor.assumeIsolated { self?.update(gravityX: g.x, gravityY: g.y) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        rest = nil
    }

    private func update(gravityX gx: Double, gravityY gy: Double) {
        // Device axes to screen axes, for however the screen is turned.
        let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.effectiveGeometry.interfaceOrientation
        let screen: (x: Double, y: Double) = switch orientation {
        case .landscapeLeft: (gy, -gx)
        case .landscapeRight: (-gy, gx)
        case .portraitUpsideDown: (-gx, -gy)
        default: (gx, gy)
        }
        if rest == nil { rest = screen }
        guard let rest else { return }
        let targetX = max(-1, min(1, (screen.x - rest.x) * 3))
        let targetY = max(-1, min(1, (screen.y - rest.y) * 3))
        // Eased, so it glides rather than jitters.
        x += (targetX - x) * 0.2
        y += (targetY - y) * 0.2
    }
}

/// The game in four pages.
struct HowToPlaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages: [(pose: CharacterPose, tint: MascotTint, title: String, line: String)] = [
        (.standing, .natural, "Squad", "Everyone on their own phone. Hide yours, hunt everyone else's."),
        (.lying, .sky, "Swarm", "One phone: hide a few around the room, then pass it on."),
        (.standing, .sun, "Blend", "They change colour to match the room."),
        (.curled, .natural, "Seek", "Tap what you spot. The closer you get, the easier they are to see."),
        (.standing, .tangerine, "Coins", "Quicker finds pay more. The hint halves a hunt's coins. Spend them on skins."),
    ]

    var body: some View {
        GeometryReader { proxy in
            // A phone on its side is only ~400 points tall: there, each page lays out side
            // by side and the dots and button share a row.
            let short = proxy.size.height < 560
            ZStack {
                HuntBackground(focus: UnitPoint(x: 0.5, y: 0.45))
                VStack(spacing: 0) {
                    // A title at the top, like the other full pages.
                    HStack(alignment: .center) {
                        Headline(text: "How to play", size: short ? 30 : 44)
                        Spacer()
                        IconButton(systemImage: "xmark", label: "Close") { dismiss() }
                    }
                    .padding(.horizontal, Hunt.gutter)
                    .padding(.vertical, short ? 10 : Hunt.gutter)

                    Spacer(minLength: 0)
                    // The page, its dots and its button, together in the middle. Only the
                    // page swipes; the dots and the button stay where they are, like every
                    // paged screen in iOS.
                    VStack(spacing: short ? 10 : 22) {
                        TabView(selection: $page) {
                            ForEach(pages.indices, id: \.self) { index in
                                pageView(index, short: short)
                                    .padding(.horizontal, Hunt.gutter)
                                    .frame(maxHeight: .infinity, alignment: .center)
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: short ? max(160, proxy.size.height - 170) : 470)

                        if short {
                            HStack(spacing: 20) { dots; nextButton }
                        } else {
                            dots
                            nextButton
                        }
                    }
                    Spacer(minLength: 0)
                    // Balance the title, so the group sits in the true middle.
                    Color.clear.frame(height: short ? 8 : 60)
                }
            }
        }
    }

    @ViewBuilder private func pageView(_ index: Int, short: Bool) -> some View {
        let picture = MascotImage(pose: pages[index].pose, view: .hero, resolution: 720, tint: pages[index].tint)
        let words = VStack(alignment: short ? .leading : .center, spacing: short ? 6 : 18) {
            Headline(text: pages[index].title, size: short ? 48 : 64)
            Text(pages[index].line)
                .font(.chat(.title3, weight: .bold))
                .foregroundStyle(Hunt.muted)
                .multilineTextAlignment(short ? .leading : .center)
                .frame(maxWidth: 440, alignment: short ? .leading : .center)
        }
        if short {
            HStack(spacing: 28) {
                picture.frame(width: 170, height: 170)
                words
            }
        } else {
            VStack(spacing: 18) {
                picture.frame(width: 280, height: 280)
                words
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { dot in
                Capsule().fill(dot == page ? Hunt.lime : Hunt.card)
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2))
                    .frame(width: dot == page ? 28 : 12, height: 12)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }

    private var nextButton: some View {
        Button {
            if page < pages.count - 1 { withAnimation { page += 1 } } else { dismiss() }
        } label: {
            Label(page < pages.count - 1 ? "Next" : "Let's play",
                  systemImage: page < pages.count - 1 ? "arrow.right" : "play.fill")
                .contentTransition(.interpolate)
        }
        .buttonStyle(.huntBig)
        .animation(.easeInOut(duration: 0.2), value: page)
    }
}

/// Settings, on the stage: time, clue, name, and the few switches that matter.
struct SettingsView: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @ObservedObject var presenter: CharacterPresenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Sound.settingKey) private var soundOn = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HuntBackground(focus: UnitPoint(x: 0.5, y: 0))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Headline(text: "Settings", size: 52)
                    section("Seeker's time", systemImage: "stopwatch.fill") {
                        FlowChips(values: GameConfig.huntDurations, selected: store.huntDuration,
                                  title: GameConfig.stopwatch) { store.huntDuration = $0 }
                    }
                    section("Hint", systemImage: "lightbulb.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowChips(values: [true, false], selected: store.hintsOn,
                                      title: { $0 ? "On" : "Off" }) { store.hintsOn = $0 }
                            Text("There from the start of a hunt. After using it, each find earns half the coins for the rest of that hunt.")
                                .font(.chat(.subheadline, weight: .bold))
                                .foregroundStyle(Hunt.muted)
                        }
                    }
                    section("Your name", systemImage: "person.fill") {
                        NameField(name: $store.playerName)
                    }
                    section("Sound", systemImage: "speaker.wave.2.fill") {
                        Toggle("Sound effects", isOn: $soundOn)
                            .toggleStyle(HuntToggleStyle())
                    }
                    section("Camera", systemImage: "camera.fill") {
                        VStack(spacing: 6) {
                            Toggle("Things in front hide the chameleon", isOn: $presenter.occlusionEnabled)
                            Divider().overlay(Hunt.ink)
                            Toggle("Match the room's lighting", isOn: $ar.lightingMatchEnabled)
                            #if DEBUG
                            Divider().overlay(Hunt.ink)
                            Toggle("Debug info", isOn: $ar.showDiagnostics)
                            Divider().overlay(Hunt.ink)
                            // Off uses the curve fitted to the playtest screenshots only.
                            Toggle("Debug: measure colours", isOn: $ar.measuresColours)
                            #endif
                        }
                        .toggleStyle(HuntToggleStyle())
                    }
                    Text(AppVersion.label)
                        .font(.chat(.caption, weight: .bold))
                        .foregroundStyle(Hunt.muted)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(Hunt.gutter)
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
            }
            // Pinned to the corner, like the other full-screen pages.
            IconButton(systemImage: "xmark", label: "Done") { dismiss() }
                .padding(Hunt.gutter)
        }
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
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

/// A wrapping row of chips.
struct FlowChips<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    let title: (Value) -> String
    let choose: (Value) -> Void

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 14) { chips }
    }

    private var chips: some View {
        ForEach(values, id: \.self) { value in
            Chip(title: title(value), selected: value == selected) { choose(value) }
        }
    }
}

// MARK: - Over the camera

/// The top of a camera screen: the way out, and what to do.
struct CameraHeader<Trailing: View>: View {
    let leading: AnyView
    let title: String
    var detail: String? = nil
    var trailing: Trailing

    init(systemImage: String, buttonLabel: String, action: @escaping () -> Void, title: String, detail: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        leading = AnyView(IconButton(systemImage: systemImage, label: buttonLabel, action: action))
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    /// With its own way out (say, one that asks first).
    init(leading: some View, title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.leading = AnyView(leading)
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        // On a phone, anything on the right drops under the title.
        RowOrColumnLayout(rowAlignment: .top, spacing: 12, columnSpacing: 10, spread: true) {
            heading
            HStack(alignment: .top, spacing: 12) { trailing }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(.hunt(26, relativeTo: .title2)).foregroundStyle(Hunt.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.chat(.subheadline, weight: .bold)).foregroundStyle(Hunt.inkMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .sticker(Hunt.paper, radius: 18)
        }
    }
}

extension CameraHeader where Trailing == EmptyView {
    init(systemImage: String, buttonLabel: String, action: @escaping () -> Void, title: String, detail: String? = nil) {
        self.init(systemImage: systemImage, buttonLabel: buttonLabel, action: action, title: title, detail: detail) {
            EmptyView()
        }
    }
}

/// A short note over the camera.
struct CamHint: View {
    let text: String
    var systemImage = "hand.point.up.left.fill"
    var tint: Color = Hunt.ink

    var body: some View {
        HUDPill(systemImage: systemImage, text: text, tint: tint)
    }
}

/// The one button that puts a chameleon somewhere, the same in every game.
struct PlaceButton: View {
    let title: String
    var systemImage = "arrow.down.to.line"
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(minWidth: 260)
        }
        .buttonStyle(.huntBig)
        .disabled(!enabled)
    }
}

// MARK: - Choosing a spot

struct PlacementHUD: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController

    private var placeable: Bool { ar.probe?.isPlaceable == true }

    var body: some View {
        ZStack {
            Reticle(state: Reticle.State(probe: ar.probe)).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                CameraHeader(systemImage: "xmark", buttonLabel: "Close", action: store.exitToIntro,
                             title: "Where to hide", detail: "Point at a surface")
                PlacementHints(ar: ar, blockedReason: blockedReason)
                Spacer()
                VStack(spacing: 12) {
                    poseRow
                    CamHint(text: "Pinch to resize · twist to turn", systemImage: "hand.pinch.fill")
                    PlaceButton(title: "Hide here", enabled: placeable, action: store.placeHere)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Hunt.gutter)
        }
    }

    private var blockedReason: String? {
        guard let probe = ar.probe, !probe.isPlaceable else { return nil }
        return probe.surface == nil ? ar.noSurfaceHint : nil
    }

    @ViewBuilder
    private var poseRow: some View {
        let surface = ar.probe?.surface ?? ar.pose.surface
        let poses = CharacterPose.poses(for: surface)
        if poses.count > 1 {
            HStack(spacing: 14) {
                ForEach(poses) { pose in
                    PoseBubble(pose: pose, selected: ar.pose == pose) { ar.pose = pose }
                }
            }
        }
    }
}

/// What's stopping them, shiny surfaces, tracking trouble — one at a time.
struct PlacementHints: View {
    @ObservedObject var ar: ARSessionController
    var blockedReason: String?

    var body: some View {
        Group {
            if ar.isRefindingRoom {
                // Nothing can be dropped until the device knows where it is again.
                CamHint(text: "Look around · finding the room again", systemImage: "location.viewfinder")
            } else if let blockedReason {
                CamHint(text: blockedReason)
            } else if ar.probe?.looksShiny == true {
                CamHint(text: "Shiny. Matte spots hide better.", systemImage: "sparkles", tint: Hunt.sunLip)
            } else if let hint = ar.trackingHint {
                CamHint(text: hint)
            } else if !ARSessionController.isLiDARAvailable && !ar.hasRoomMap {
                CamHint(text: "Flat surfaces only", systemImage: "square.dashed")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ar.probe?.looksShiny)
    }
}

/// A pose as a little portrait of the chameleon doing it.
struct PoseBubble: View {
    let pose: CharacterPose
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MascotImage(pose: pose, view: .hero, resolution: 240)
                    .padding(8)
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(selected ? Hunt.lime : Hunt.paper))
                    .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                    .background(Circle().fill(Hunt.ink).offset(y: selected ? 2 : 5))
                    .offset(y: selected ? 3 : 0)
                ShowText(text: pose.displayName.uppercased(), size: 16, fill: selected ? Hunt.lime : Hunt.text)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pose.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct Reticle: View {
    enum State: Equatable {
        case searching
        case invalid
        case locked

        init(probe: ARSessionController.Probe?) {
            guard let probe else { self = .searching; return }
            self = probe.isPlaceable ? .locked : .invalid
        }
    }

    let state: State

    var body: some View {
        ZStack {
            Circle().strokeBorder(Hunt.ink, lineWidth: 8).frame(width: 62, height: 62)
            Circle()
                .strokeBorder(state == .locked ? Hunt.lime : Hunt.paper,
                              style: StrokeStyle(lineWidth: 4, dash: state == .locked ? [] : [7, 7]))
                .frame(width: 60, height: 60)
            Circle().fill(state == .locked ? Hunt.lime : Hunt.paper).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2))
        }
        .scaleEffect(state == .locked ? 1 : 0.9)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: state)
    }
}

// MARK: - Swarm

/// No reticle: the bright chameleon following the aim point is the cursor. The next one
/// waits until the last has blended in.
struct ScatterHUD: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @ObservedObject var scatter: ScatterStage

    private var full: Bool { scatter.count >= ScatterStage.maximum }
    private var canDrop: Bool { ar.probe?.isPlaceable == true && !full && scatter.geometriesReady && scatter.previewReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraHeader(systemImage: "xmark", buttonLabel: "Close", action: store.exitToIntro,
                         title: "Drop them", detail: "Aim, then drop") {
                HUDPill(systemImage: "lizard.fill", text: "\(scatter.count)/\(ScatterStage.maximum)",
                        tint: scatter.count > 0 ? Hunt.limeLip : Hunt.ink)
            }
            Group {
                if !scatter.geometriesReady {
                    CamHint(text: "Loading…", systemImage: "hourglass")
                } else if ar.isRefindingRoom {
                    PlacementHints(ar: ar, blockedReason: nil)
                } else if full {
                    CamHint(text: "That's ten", systemImage: "checkmark.circle.fill", tint: Hunt.limeLip)
                } else if !scatter.previewReady && scatter.count > 0 {
                    CamHint(text: "Blending in…", systemImage: "wand.and.stars", tint: Hunt.limeLip)
                } else {
                    PlacementHints(ar: ar, blockedReason: ar.probe?.surface == nil && ar.probe != nil ? ar.noSurfaceHint : nil)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: scatter.previewReady)
            Spacer()
            ActionBar {
                Button(action: store.undoChameleon) { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.huntSecondary)
                    .disabled(scatter.count == 0)
            } primary: {
                PlaceButton(title: "Drop", enabled: canDrop, action: store.dropChameleon)
                    .sensoryFeedback(.impact(weight: .medium), trigger: scatter.count)
            } trailing: {
                Button(action: store.finishScattering) { Label("Done hiding", systemImage: "checkmark") }
                    .buttonStyle(.huntSecondary)
                    .disabled(scatter.count == 0)
            }
        }
        .padding(Hunt.gutter)
    }
}

// MARK: - Scanning

/// Face ID, pointed at the room: a ring that fills as you walk round. It only lights for
/// pictures that were actually kept, and says what's wrong when they aren't.
struct ScanHUD: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @State private var celebrating = false

    private var complete: Bool { celebrating || store.isSavingScan }
    private var canStopEarly: Bool {
        ar.keyframeCount >= GameConfig.minimumKeyframes && (ar.ringProgress >= 0.45 || ar.scanStalled)
    }
    private var stuck: Bool { ar.scanStalled && ar.ringProgress < 0.45 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraHeader(systemImage: "chevron.backward", buttonLabel: "Back", action: store.backToPlacement,
                         title: complete ? "Got it" : "Scan the spot", detail: complete ? nil : "Walk slowly around it")
                .animation(.easeInOut, value: complete)
            if !complete, let nudge = ar.scanNudge {
                CamHint(text: nudge, systemImage: Self.symbol(for: nudge), tint: Hunt.pinkLip)
            }
            Spacer()
            VStack(spacing: 18) {
                ScanProgressRing(progress: ar.ringProgress, complete: complete)
                    .frame(width: 156, height: 156)
                ZStack {
                    if !complete && canStopEarly {
                        Button { finish() } label: { Label("Finish scan", systemImage: "checkmark") }
                            .buttonStyle(HuntButtonStyle(kind: stuck ? .primary : .secondary))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 60)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Hunt.gutter)
        .animation(.easeInOut(duration: 0.25), value: ar.scanNudge)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canStopEarly)
        .onChange(of: ar.ringProgress) { _, progress in
            if progress >= 0.9, !complete { finish() }
        }
    }

    private static func symbol(for nudge: String) -> String {
        if nudge.contains("Slow") { return "tortoise.fill" }
        if nudge.contains("light") { return "lightbulb.fill" }
        if nudge.contains("steady") { return "hand.raised.fill" }
        if nudge.contains("middle") { return "scope" }
        if nudge.contains("moved") { return "figure.walk" }
        if nudge.contains("way") { return "hand.raised.fill" }
        return "arrow.left.and.right"
    }

    private func finish() {
        guard !complete else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { celebrating = true }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            store.finishScan()
            try? await Task.sleep(for: .milliseconds(300))
            if store.phase == .scanning, !store.isSavingScan {
                withAnimation { celebrating = false }
            }
        }
    }
}

private struct ScanProgressRing: View {
    let progress: Float
    let complete: Bool

    var body: some View {
        ZStack {
            Circle().fill(Hunt.paper)
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                .background(Circle().fill(Hunt.ink).offset(y: 5))
            ForEach(0..<ScanRing.tickCount, id: \.self) { index in
                let lit = complete || Float(index) < progress * Float(ScanRing.tickCount)
                Capsule()
                    .fill(lit ? Hunt.lime : Hunt.paperLip)
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: lit ? 1.5 : 0))
                    .frame(width: 6, height: lit ? 18 : 12)
                    .offset(y: -60)
                    .rotationEffect(.degrees(Double(index) / Double(ScanRing.tickCount) * 360))
            }
            Group {
                if complete {
                    Image(systemName: "checkmark").font(.system(size: 50, weight: .black)).foregroundStyle(Hunt.limeLip)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(Int((progress * 100).rounded()))%").font(.hunt(36, relativeTo: .title)).monospacedDigit()
                        .foregroundStyle(Hunt.ink).contentTransition(.numericText())
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress)
        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: complete)
        .accessibilityElement()
        .accessibilityLabel(complete ? "Scan complete" : "Scan \(Int(progress * 100)) percent done")
    }
}

// MARK: - Waiting

struct ProcessingView: View {
    let message: String
    let progress: Float

    var body: some View {
        ZStack {
            HuntBackground(focus: UnitPoint(x: 0.5, y: 0.4))
            VStack(spacing: 22) {
                MascotImage(pose: .curled, view: .hero, resolution: 720)
                    .frame(width: 280, height: 280)
                    .accessibilityHidden(true)
                Headline(text: "Getting ready", size: 44)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Hunt.card)
                        Capsule().fill(Hunt.lime).frame(width: max(18, proxy.size.width * CGFloat(max(progress, 0.02))))
                    }
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                    .background(Capsule().fill(Hunt.ink).offset(y: 4))
                }
                .frame(width: 340, height: 22)
                .animation(.easeOut(duration: 0.25), value: progress)
                .accessibilityElement()
                .accessibilityLabel("\(Int(progress * 100)) percent")
            }
        }
    }
}

// MARK: - Putting it back and checking it

struct ARCheckHUD: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @ObservedObject var presenter: CharacterPresenter

    var body: some View {
        ZStack {
            switch ar.characterStatus {
            case .replacing: replacing
            case .visible: visible
            case .locating, .none: locating
            }
            if ar.showDiagnostics {
                DiagnosticsPanel(ar: ar)
                    .padding(.top, 150)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var locating: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraHeader(systemImage: "chevron.backward", buttonLabel: "Back to painting", action: store.backToStudio,
                         title: "Find your spot", detail: "Sweep across it slowly")
            if let photo = ar.spotPhoto {
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 180, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
                    .sticker(Hunt.paper, radius: 16)
                    .rotationEffect(.degrees(-3))
                    .padding(.leading, 64)
                    .accessibilityLabel("Where you hid it")
            }
            Spacer()
            SearchingPulse(found: ar.searchState == .confirming)
                .frame(width: 120, height: 120)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let waited = context.date.timeIntervalSince(ar.locatingSince ?? context.date)
                if waited > 10 {
                    Button { store.replaceCharacterHere() } label: { Label("Place by hand", systemImage: "hand.point.up.left.fill") }
                        .buttonStyle(.huntSecondary)
                        .transition(.opacity)
                }
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
        }
        .padding(Hunt.gutter)
    }

    private var replacing: some View {
        ZStack {
            Reticle(state: Reticle.State(probe: ar.probe)).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                CameraHeader(systemImage: "chevron.backward", buttonLabel: "Back to painting", action: store.backToStudio,
                             title: "Put it back", detail: "It snaps into place if the room matches")
                if let hint = ar.trackingHint { CamHint(text: hint) }
                Spacer()
                ActionBar {
                    Button { store.retryFindingSpot() } label: { Label("Keep looking", systemImage: "viewfinder") }
                        .buttonStyle(.huntSecondary)
                } primary: {
                    PlaceButton(title: "Put it here", enabled: ar.probe?.isPlaceable == true) { _ = ar.confirmPlacement() }
                } trailing: {
                    EmptyView()
                }
            }
            .padding(Hunt.gutter)
        }
    }

    private var visible: some View {
        ZStack {
            if let direction = ar.offscreenDirection {
                OffscreenArrow(direction: direction).allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 12) {
                CameraHeader(systemImage: "chevron.backward", buttonLabel: "Back to painting", action: store.backToStudio,
                             title: "Spot check", detail: "Look from where they'll stand")
                Spacer()
                // The way back to painting is the button top left, as on every camera
                // screen; a second one down here said the same thing.
                ActionBar {
                    EmptyView()
                } primary: {
                    PlaceButton(title: "Ready to hunt", systemImage: "checkmark", action: store.readyToSeek)
                } trailing: {
                    // Same words as the results, for the same thing: it turns solid pink.
                    Button { presenter.setHighlighted(!presenter.isHighlighted) } label: {
                        Label(presenter.isHighlighted ? "Show paint job" : "Show in pink",
                              systemImage: presenter.isHighlighted ? "paintpalette.fill" : "eye.fill")
                    }
                    .buttonStyle(.huntSecondary)
                }
            }
            .padding(Hunt.gutter)
        }
    }
}

private struct SearchingPulse: View {
    let found: Bool
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(found ? Hunt.lime : Hunt.paper, lineWidth: 5)
                .scaleEffect(breathe ? 1 : 0.8).opacity(breathe ? 0.3 : 1)
            Image(systemName: found ? "checkmark" : "viewfinder")
                .font(.system(size: 28, weight: .black)).foregroundStyle(Hunt.ink)
                .frame(width: 72, height: 72)
                .background(Circle().fill(found ? Hunt.lime : Hunt.paper))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityLabel(found ? "Found it" : "Looking")
    }
}

/// Points toward the hidden thing from the edge of the screen when it's out of view.
struct OffscreenArrow: View {
    let direction: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let dx = cos(direction), dy = sin(direction)
            let halfW = size.width / 2 - 70, halfH = size.height / 2 - 70
            let scale = min(abs(dx) > 1e-3 ? halfW / abs(dx) : .infinity, abs(dy) > 1e-3 ? halfH / abs(dy) : .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(Hunt.ink)
                .rotationEffect(.radians(direction))
                .frame(width: 62, height: 62)
                .background(Circle().fill(Hunt.lime))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                .background(Circle().fill(Hunt.ink).offset(y: 4))
                .position(x: center.x + dx * scale, y: center.y + dy * scale)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct DiagnosticsPanel: View {
    @ObservedObject var ar: ARSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ar.diagnosticLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced())
                }
            }
            .padding(14)
        }
        .frame(width: 380, height: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Hunt.ink.opacity(0.92)))
        .foregroundStyle(Hunt.text)
    }
}

// MARK: - Handing over

/// The seeker's turn: a spotlight on a dark stage, like a role reveal. Covers the camera
/// so the seeker doesn't start from the hider's view.
struct HandoffView: View {
    @ObservedObject var store: GameStore
    let onStart: () -> Void
    let onBack: () -> Void

    private var swarm: Bool { store.mode == .scatter }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            // A phone on its side: everything smaller, and the two keys side by side.
            let short = !portrait && proxy.size.height < 500
            SpotlightStage(colour: Hunt.pink) {
                if short && swarm {
                    // Sideways with the difficulty too, there's no height for the chameleon:
                    // two columns, and the spotlight on the title.
                    HStack(alignment: .center, spacing: 36) {
                        VStack(alignment: .leading, spacing: 12) {
                            title(size: 50, alignment: .leading).spotlightSubject()
                            lookAway
                            stats
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            DifficultyPicker(store: store, alignment: .leading)
                            HStack(spacing: 14) {
                                goKey(minWidth: 150)
                                backKey(large: true)
                            }
                        }
                    }
                    .padding(Hunt.gutter)
                } else {
                    let layout = portrait ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(spacing: short ? 24 : 40))
                    layout {
                        // A phone upright has room for the difficulty too only with a smaller chameleon.
                        let art: CGFloat = portrait ? min(280, proxy.size.height * (swarm ? 0.24 : 0.32)) : short ? 230 : 380
                        MascotImage(pose: .standing, view: .hero, resolution: 720)
                            .frame(width: art, height: art)
                            .spotlightSubject()
                            .accessibilityHidden(true)
                        VStack(alignment: portrait ? .center : .leading, spacing: short ? 12 : 18) {
                            title(size: short ? 50 : 72, alignment: portrait ? .center : .leading)
                            lookAway
                            stats
                            if swarm { DifficultyPicker(store: store, alignment: portrait ? .center : .leading) }
                            let keys = short ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: portrait ? .center : .leading, spacing: 18))
                            keys {
                                goKey(minWidth: short ? 150 : 220)
                                // In a row beside Go, the same height as Go.
                                backKey(large: short)
                            }
                        }
                    }
                    .padding(Hunt.gutter)
                }
            }
        }
    }

    private func title(size: CGFloat, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: -10) {
            ShowText(text: "SEEKER'S", size: size)
            ShowText(text: "TURN", size: size * 1.22, fill: Hunt.pink)
        }
        .rotationEffect(.degrees(-3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seeker's turn")
        .accessibilityAddTraits(.isHeader)
    }

    private var lookAway: some View {
        Label("Hider, look away.", systemImage: "eye.slash.fill")
            .font(.chat(.title3, weight: .bold))
            .foregroundStyle(Hunt.muted)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            if swarm { Stat(value: "\(store.hiddenCount)", label: "Hidden") }
            Stat(value: GameConfig.stopwatch(store.roundDuration), label: "Time", colour: Hunt.sun)
            Stat(value: store.hintsOn ? "On" : "Off", label: "Hint")
        }
    }

    private func goKey(minWidth: CGFloat) -> some View {
        Button(action: onStart) { Label("Go", systemImage: "play.fill").frame(minWidth: minWidth) }
            .buttonStyle(.huntBig)
    }

    private func backKey(large: Bool) -> some View {
        Button(swarm ? "Back to hiding" : "Back to painting", action: onBack)
            .buttonStyle(HuntButtonStyle(kind: .ghost, large: large))
    }
}

/// Swarm's difficulty, on SEEKER'S TURN: three chips and a line saying what the chosen
/// one means (it changes the time above, too).
private struct DifficultyPicker: View {
    @ObservedObject var store: GameStore
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            HStack(spacing: 10) {
                chip(.easy)
                chip(.medium)
                chip(.hard)
            }
            Text(store.swarmDifficulty.detail)
                .font(.chat(.subheadline, weight: .bold))
                .foregroundStyle(Hunt.muted)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Difficulty")
    }

    private func chip(_ level: HuntDifficulty) -> some View {
        Chip(title: level.title, selected: store.swarmDifficulty == level) {
            withAnimation(.easeOut(duration: 0.15)) { store.swarmDifficulty = level }
        }
    }
}

// MARK: - Hunting

struct HuntHUD: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @State private var showFound = false
    @State private var foundBanner = 0
    /// The "-5 s" by the clock after a miss costs time (Swarm, Medium and Hard).
    @State private var penaltyShown = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.showNotice) private var showNotice

    private var penalty: Int { store.mode == .scatter ? store.swarmDifficulty.missPenalty : 0 }

    /// There from the start; it asks before it costs anything, and says what it costs.
    private var hintKey: some View {
        HintKey { showNotice(hintNotice) }
    }

    private var hintNotice: Notice {
        Notice(title: "Use the hint?",
               message: store.mode == .scatter
                   ? "An arrow points to the nearest one. For the rest of this hunt, each one you find earns half the coins."
                   : "It tells you the pose and the size. Finding it then earns half the coins.",
               systemImage: "lightbulb.fill", tint: Hunt.sun,
               primary: .init(title: "Keep looking"),
               secondary: .init(title: "Use hint", systemImage: "lightbulb.fill") { [store] in store.useHint() })
    }

    var body: some View {
        ZStack {
            if store.mode == .scatter, let direction = ar.offscreenDirection {
                OffscreenArrow(direction: direction).allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 12) {
                // Same order as every camera screen: the way out first, then the clock.
                HStack(alignment: .center, spacing: 12) {
                    IconButton(systemImage: "pause.fill", label: "Pause", action: store.pauseHunt)
                    ClockPill(seconds: store.secondsRemaining)
                    if penaltyShown {
                        Text("−\(penalty) s")
                            .font(.hunt(24, relativeTo: .title3))
                            .foregroundStyle(Hunt.ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .sticker(Hunt.cherry, radius: 20, shadow: 3)
                            .fixedSize()
                            .rotationEffect(.degrees(-4))
                            .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
                            .accessibilityLabel("\(penalty) seconds off")
                    }
                    Spacer(minLength: 0)
                    if store.mode == .scatter {
                        FoundTally(found: store.foundCount, total: store.hiddenCount,
                                   compact: sizeClass == .compact && store.hiddenCount > 4)
                    } else if store.missCount > 0 {
                        HUDPill(systemImage: "xmark", text: "\(store.missCount)")
                            .accessibilityLabel("\(store.missCount) misses")
                    }
                }
                .opacity(store.countdown == nil ? 1 : 0)
                if ar.isRefindingRoom {
                    // Put down and picked up again: it's matching the room to its map.
                    CamHint(text: "Look around · finding the room again", systemImage: "location.viewfinder")
                } else if store.isWaitingForSpot {
                    CamHint(text: "Hold still. Clock paused.", systemImage: "pause.circle.fill")
                } else if let hint = ar.trackingHint {
                    CamHint(text: hint)
                }
                Spacer()
                VStack(spacing: 10) {
                    if store.hintDropped {
                        ClueBanner(store: store, ar: ar).transition(.scale.combined(with: .opacity))
                    }
                    CamHint(text: penalty > 0 ? "Tap what you spot · a miss costs \(penalty) s"
                                              : "Tap what you spot · closer is easier",
                            systemImage: "hand.tap.fill")
                    // This hunt's coins on the left, the hint on the right.
                    // Giving up is on the pause screen, with the other ways out.
                    HStack(alignment: .bottom) {
                        CoinPill(amount: store.coinsThisRound, halved: store.hintDropped)
                        Spacer(minLength: 0)
                        if store.hintAvailable, !store.hintDropped { hintKey }
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(store.countdown == nil ? 1 : 0)
            }
            .padding(Hunt.gutter)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: store.hintDropped)

            if showFound {
                Slam(text: "Found", colour: Hunt.text, size: 88, trigger: foundBanner, burst: Hunt.pink)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let count = store.countdown {
                ZStack {
                    Hunt.ink.opacity(0.55).ignoresSafeArea()
                    Slam(text: "\(count)", colour: Hunt.text, size: 180, trigger: count, burst: count == 1 ? Hunt.lime : Hunt.sun)
                }
            }
            if store.isHuntPaused {
                HuntPausedView(store: store).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.isHuntPaused)
        .animation(.easeInOut(duration: 0.2), value: store.countdown == nil)
        .onChange(of: store.penaltiesTaken) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { penaltyShown = true }
            let shown = store.penaltiesTaken
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if store.penaltiesTaken == shown { withAnimation(.easeOut(duration: 0.25)) { penaltyShown = false } }
            }
        }
        .sensoryFeedback(.warning, trigger: store.penaltiesTaken)
        #if DEBUG
        // `-debugHintNotice` opens the hint's card, for screenshots.
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-debugHintNotice") { showNotice(hintNotice) } }
        #endif
        .onChange(of: store.foundCount) { _, found in
            guard found > 0, store.phase == .seeking else { return }
            foundBanner += 1
            let shown = foundBanner
            showFound = true
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                if foundBanner == shown { withAnimation(.easeOut(duration: 0.2)) { showFound = false } }
            }
        }
    }
}

/// The clue, near the end.
private struct ClueBanner: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill").font(.system(size: 22, weight: .black))
            Text(text).font(.hunt(24, relativeTo: .title3))
        }
        .foregroundStyle(Hunt.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .sticker(Hunt.sun, radius: 18)
        .rotationEffect(.degrees(-2))
        .sensoryFeedback(.warning, trigger: store.hintDropped)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if store.mode == .scatter { return ar.hintTargetInView ? "It's in view" : "Follow the arrow" }
        let size = Int((CharacterPose.nominalHeightMeters * store.ar.characterScale * 100).rounded())
        return "\(store.ar.pose.displayName) · \(size) cm"
    }
}

/// Opaque, so pausing can't be used to study the room.
private struct HuntPausedView: View {
    @ObservedObject var store: GameStore
    @Environment(\.showNotice) private var showNotice

    var body: some View {
        GeometryReader { proxy in
            // A phone on its side hasn't the height for the lot in one column.
            let sideways = proxy.size.width > proxy.size.height && proxy.size.height < 500
            ZStack {
                HuntBackground(focus: UnitPoint(x: sideways ? 0.3 : 0.5, y: 0.3))
                let layout = sideways ? AnyLayout(HStackLayout(spacing: 48)) : AnyLayout(VStackLayout(spacing: 22))
                layout {
                    VStack(spacing: 22) {
                        Headline(text: "Paused", size: 72)
                        Stat(value: GameConfig.stopwatch(store.secondsRemaining), label: "Left", colour: Hunt.sun)
                    }
                    choices
                }
                .padding(Hunt.gutter)
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 12) {
            Button(action: store.resumeHunt) { Label("Resume", systemImage: "play.fill") }
                .buttonStyle(HuntButtonStyle(large: true, fill: true))
            Button { showNotice(giveUp) } label: { Label("Give up", systemImage: "flag.fill") }
                .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
            Button { store.restartHunt() } label: { Label("Restart hunt", systemImage: "arrow.counterclockwise") }
                .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
            Button { store.backFromHandoff() } label: {
                Label(store.mode == .scatter ? "Back to hiding" : "Back to painting",
                      systemImage: store.mode == .scatter ? "arrow.down.to.line" : "paintbrush.fill")
            }
            .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
            Button { showNotice(endGame) } label: { Label("End game", systemImage: "xmark") }
                .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
        }
        .frame(minWidth: 300, maxWidth: 420)
    }

    private var giveUp: Notice {
        Notice(title: "Give up?", message: store.mode == .scatter ? "The ones still hidden light up, and the round's over."
                                                                  : "It lights up, and the round's over.",
               systemImage: "flag.fill", tint: Hunt.cherry,
               primary: .init(title: "Keep looking"),
               secondary: .init(title: "Give up", systemImage: "flag.fill") { [store] in store.giveUp() })
    }

    private var endGame: Notice {
        Notice(title: "End this game?", message: "You'll go back to the start.", systemImage: "flag.checkered",
               tint: Hunt.cherry,
               primary: .init(title: "End game") { [store] in store.exitToIntro() },
               secondary: .init(title: "Keep playing"))
    }
}

// MARK: - The end

/// The camera stays live so both players can walk over and look.
struct ResultView: View {
    @ObservedObject var store: GameStore
    @ObservedObject var ar: ARSessionController
    @ObservedObject var presenter: CharacterPresenter

    /// A phone on its side: a narrower Play again, so the three keys fit in one row
    /// instead of stacking down past the bottom edge.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var seekerWon: Bool { store.phase == .seekerWon }
    private var swarm: Bool { store.mode == .scatter }

    var body: some View {
        ZStack {
            if let direction = ar.offscreenDirection, !swarm {
                OffscreenArrow(direction: direction).allowsHitTesting(false)
            }
            if seekerWon { Confetti() }
            VStack(spacing: 18) {
                RowOrColumn(columnAlignment: .center, spacing: 0) {
                    MascotImage(pose: seekerWon ? .curled : .standing, view: .hero, resolution: 480,
                                tint: seekerWon ? .bubblegum : .natural)
                        .frame(width: 150, height: 150)
                        .accessibilityHidden(true)
                    Slam(text: headline, colour: Hunt.text, size: 64, burst: seekerWon ? Hunt.pink : Hunt.lime)
                }
                HStack(spacing: 12) {
                    if swarm {
                        Stat(value: "\(store.foundCount)/\(store.hiddenCount)", label: "Found · \(store.swarmDifficulty.title)",
                             colour: Hunt.pink)
                    }
                    Stat(value: GameConfig.stopwatch(max(0, store.roundDuration - store.secondsRemaining)), label: "Time",
                         colour: Hunt.sun)
                    Stat(value: "\(store.missCount)", label: "Misses")
                    // A phone on its side: the coins go in the row, not under it.
                    if verticalSizeClass == .compact { CoinsEarned(amount: store.coinsThisRound, compact: true) }
                }
                if verticalSizeClass != .compact { CoinsEarned(amount: store.coinsThisRound) }
                Spacer()
                ActionBar {
                    Button(action: store.exitToIntro) { Label("Home", systemImage: "house.fill") }
                        .buttonStyle(HuntButtonStyle(kind: .secondary, large: true))
                } primary: {
                    Button(action: store.playAgain) {
                        Label("Play again", systemImage: "arrow.clockwise").frame(minWidth: verticalSizeClass == .compact ? 160 : 220)
                    }
                    .buttonStyle(.huntBig)
                } trailing: {
                    if !swarm {
                        // It turns pink when the round ends; this swaps between that and
                        // the paint job, so both players can see how well it was hidden.
                        Button { presenter.setMarked(!presenter.isMarked) } label: {
                            Label(presenter.isMarked ? "Show paint job" : "Show in pink",
                                  systemImage: presenter.isMarked ? "paintpalette.fill" : "eye.fill")
                        }
                        .buttonStyle(HuntButtonStyle(kind: .secondary, large: true))
                    }
                }
            }
            .padding(Hunt.gutter)
        }
        .overlay(alignment: .topTrailing) {
            IconButton(systemImage: "square.and.arrow.up", label: "Share") { share() }
                .padding(Hunt.gutter)
        }
        .sensoryFeedback(seekerWon ? .success : .warning, trigger: store.phase)
        .asksForReview(after: seekerWon)
    }

    private var headline: String {
        if swarm { return seekerWon ? "All found" : "\(store.foundCount) found" }
        return seekerWon ? "Found" : "Escaped"
    }

    /// A picture of the room to send. With the paint job showing it's a puzzle; in pink,
    /// the answer.
    private func share() {
        let seconds = max(0, store.roundDuration - store.secondsRemaining)
        let puzzle = !swarm && !presenter.isMarked
        let title: String = if puzzle {
            "Can you spot it?"
        } else if swarm {
            seekerWon ? "All \(store.hiddenCount) found" : "\(store.foundCount) of \(store.hiddenCount) found"
        } else {
            seekerWon ? "Found in \(GameConfig.stopwatch(seconds))" : "Never found"
        }
        let detail = swarm ? "ChameleonHunt · Swarm on \(store.swarmDifficulty.title)" : "ChameleonHunt · hide and seek"
        let message = ShareCard.message(puzzle ? "There's a chameleon hiding in this room. Can you spot it?"
                                               : "Hide and seek with a chameleon in our room.")
        ar.snapshot { image in
            ShareCard.present(image: ShareCard.make(snapshot: image, headline: title, detail: detail), message: message)
        }
    }
}
