//
//  HuntKit.swift
//  The look of every screen outside the paint studio: Chameleon Hunt as a game show.
//
//  Who plays: friends in their early twenties, on one device or several, for laughs and
//  bragging rights. The references are the party games that crowd actually plays
//  together, borrowed from rather than copied:
//
//   - Fall Guys: the show. An electric-violet stage with sunburst rays, candy colours,
//     chunky sticker buttons that press down into their lip, and big bouncy words for
//     the big moments (FOUND, 3-2-1, YOU WIN), with confetti when someone wins.
//   - Among Us: the crew. Every squad player is their own coloured chameleon, standing
//     in the lobby line-up, on the scoreboard and on the podium; and the tense moments
//     get a spotlight scene on a dark stage (the seeker's turn, LOOK AWAY).
//   - Nintendo: the polish. Lilita One lettering with a thick ink outline and a drop,
//     white stickers with ink edges for anything over the camera, one job per colour.
//
//  One job per colour: lime is go; sun yellow is time and first place; pink is found;
//  ink (a violet-black) outlines everything; players own their colour.
//
//  What was learnt the hard way: the copy stays short and plain — the words on screen
//  are few, and the jokes are in the show, never in sentences.
//
//  Grounded in Apple's Human Interface Guidelines all the same: 44-point-plus targets,
//  Dynamic Type (sentences in SF Pro Rounded; the display lettering scales too, capped
//  so it fits), SF Symbols, the safe area, and Reduce Motion turning the rays, bounces
//  and confetti into stillness and fades.
//
//  Display type: Lilita One (SIL Open Font License, bundled in Fonts/).
//

import CoreText
import SwiftUI

enum Hunt {
    // The stage behind the menus: electric violet, deeper towards the floor.
    static let stageTop = Color(hex: 0x7D4FFF)
    static let stage = Color(hex: 0x5A2EE2)
    static let stageBottom = Color(hex: 0x3A1AA4)
    /// Cards standing on the stage.
    static let card = Color(hex: 0x2C158C)
    static let cardHigh = Color(hex: 0x4326BC)
    /// Outlines, text on stickers, and the dark of the spotlight scenes.
    static let ink = Color(hex: 0x1A0B3B)
    static let inkMuted = Color(hex: 0x1A0B3B).opacity(0.66)
    /// Sticker white, and the lip it presses into.
    static let paper = Color.white
    static let paperLip = Color(hex: 0xC9BFF0)

    /// Go: the chameleon's own green.
    static let lime = Color(hex: 0x8CE04A)
    static let limeLip = Color(hex: 0x4E9C27)
    /// Time, and first place.
    static let sun = Color(hex: 0xFFD23F)
    static let sunLip = Color(hex: 0xD6960A)
    /// Found.
    static let pink = Color(hex: 0xFF4FA6)
    static let pinkLip = Color(hex: 0xC11B78)
    static let cyan = Color(hex: 0x3ED3FF)
    static let orange = Color(hex: 0xFF8A3D)
    static let cherry = Color(hex: 0xFF5656)

    static let text = Color.white
    static let muted = Color.white.opacity(0.8)

    /// One colour per squad player, in join order — and the chameleon that wears it.
    static let players = [lime, sun, pink, cyan, orange, cherry]
    static let playerTints: [MascotTint] = [.natural, .sun, .bubblegum, .sky, .tangerine, .cherry]
    static func player(_ index: Int) -> Color { players[wrap(index)] }
    static func playerTint(_ index: Int) -> MascotTint { playerTints[wrap(index)] }
    /// Said out loud, e.g. "What you find turns yellow".
    static let playerColourNames = ["green", "yellow", "pink", "blue", "orange", "red"]
    static func playerColourName(_ index: Int) -> String { playerColourNames[wrap(index)] }
    private static func wrap(_ index: Int) -> Int { ((index % players.count) + players.count) % players.count }

    static let gutter: CGFloat = 28
    static let radius: CGFloat = 22
    static let outline: CGFloat = 3
    /// How far a sticker button sits above its lip.
    static let depth: CGFloat = 6

    /// Registers the bundled display face. Called once at launch.
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "LilitaOne-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// Lilita One: titles, buttons, numbers. Scales with Dynamic Type relative to `style`.
    static func hunt(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("LilitaOne", size: size, relativeTo: style)
    }

    /// Lilita One at the size of a Dynamic Type style.
    static func hunt(_ style: Font.TextStyle) -> Font {
        .custom("LilitaOne", size: UIFont.preferredFont(forTextStyle: style.uiStyle,
                                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize,
                relativeTo: style)
    }

    /// Sentences: SF Pro Rounded.
    static func chat(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

private extension Font.TextStyle {
    var uiStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

// MARK: - Lettering

/// Lilita One with a thick ink outline and a drop under it — how the show letters its
/// titles. The outline is a real stroke round the letter shapes, so it stays clean at
/// banner sizes. Scales with Dynamic Type, at most a third larger.
struct ShowText: View {
    let text: String
    var size: CGFloat
    var fill: Color = Hunt.text
    var outline = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let scaled = min(UIFontMetrics(forTextStyle: .largeTitle)
            .scaledValue(for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiCategory)),
                         size * 1.3)
        let glyphs = GlyphOutline(text: text, size: scaled)
        let width = outline ? max(2, scaled * 0.07) : 0
        let drop = outline ? max(2, scaled * 0.07) : 0
        let stroke = StrokeStyle(lineWidth: width * 2, lineCap: .round, lineJoin: .round)
        ZStack {
            if outline {
                glyphs.stroke(Hunt.ink, style: stroke).offset(y: drop)
                glyphs.fill(Hunt.ink).offset(y: drop)
                glyphs.stroke(Hunt.ink, style: stroke)
            }
            glyphs.fill(fill)
        }
        .frame(width: glyphs.bounds.width, height: glyphs.bounds.height)
        .padding(width)
        .padding(.bottom, drop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The outline of a line of Lilita One, as a shape.
struct GlyphOutline: Shape {
    let outline: Path
    let bounds: CGRect

    init(text: String, size: CGFloat) {
        let font = CTFontCreateWithName("LilitaOne" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let combined = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                // CoreText is y-up; flip into the view's y-down space.
                combined.addPath(outline, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: 0))
            }
        }
        let box = combined.boundingBoxOfPath
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        outline = Path(combined.copy(using: &shift) ?? combined)
        bounds = CGRect(origin: .zero, size: box.isNull ? .zero : box.size)
    }

    func path(in rect: CGRect) -> Path { outline }
}

private extension DynamicTypeSize {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// A screen title: outlined Lilita, in capitals. Long titles wrap onto two lines, or
/// shrink if they must.
struct Headline: View {
    let text: String
    var size: CGFloat = 44
    var colour: Color = Hunt.text

    var body: some View {
        let words = text.uppercased()
        let lines = Self.lines(words)
        ViewThatFits(in: .horizontal) {
            ShowText(text: words, size: size, fill: colour)
            // No ForEach in a ViewThatFits (see RowOrColumnLayout); it's at most two lines.
            VStack(alignment: .leading, spacing: -size * 0.12) {
                ShowText(text: lines[0], size: size, fill: colour)
                if lines.count > 1 { ShowText(text: lines[1], size: size, fill: colour) }
            }
            ShowText(text: words, size: size * 0.66, fill: colour)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    /// Splits at the space nearest the middle.
    private static func lines(_ text: String) -> [String] {
        let spaces = text.indices.filter { text[$0] == " " }
        let middle = text.count / 2
        guard let split = spaces.min(by: {
            abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle)
        }) else { return [text] }
        return [String(text[..<split]), String(text[text.index(after: split)...])]
    }
}

/// A row if it fits across, otherwise a column — so a bar laid out for an iPad still
/// works on a phone.
struct RowOrColumn<Content: View>: View {
    var rowAlignment: VerticalAlignment = .center
    var columnAlignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        RowOrColumnLayout(rowAlignment: rowAlignment, columnAlignment: columnAlignment, spacing: spacing) { content }
    }
}

/// Lays its children out side by side at their natural widths when they fit, otherwise
/// one under the other at the full width.
///
/// Use this, not ViewThatFits, for anything with a list or a clock in it. ViewThatFits
/// measures the layout it isn't showing only when it needs to, and SwiftUI may do that
/// measuring on its background render thread; a ForEach or TimelineView in there then
/// builds its views off the main thread, Swift 6 catches it and the app stops. The squad
/// results crashed like that in testing, and the hunt's live scores could have.
struct RowOrColumnLayout: Layout {
    var rowAlignment: VerticalAlignment = .center
    var columnAlignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 12
    var columnSpacing: CGFloat?
    /// In a row, the first child hugs the leading edge and the rest the trailing edge.
    var spread = false

    private func fitsInRow(_ width: CGFloat?, _ sizes: [CGSize]) -> Bool {
        guard let width else { return true }
        return sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0)) <= width + 0.5
    }

    private func columnSizes(_ width: CGFloat?, _ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if fitsInRow(proposal.width, ideal) {
            let natural = ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(ideal.count - 1, 0))
            return CGSize(width: spread ? max(natural, proposal.width ?? 0) : natural, height: ideal.map(\.height).max() ?? 0)
        }
        let sizes = columnSizes(proposal.width, subviews)
        let gap = columnSpacing ?? spacing
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if fitsInRow(bounds.width, ideal) {
            var x = bounds.minX
            if spread, let first = ideal.first {
                // The first on the left; the others packed up against the right.
                let rest = ideal.dropFirst().map(\.width).reduce(0, +) + spacing * CGFloat(max(ideal.count - 2, 0))
                place(subviews[0], size: first, x: x, in: bounds)
                x = bounds.maxX - rest
                for index in subviews.indices.dropFirst() {
                    place(subviews[index], size: ideal[index], x: x, in: bounds)
                    x += ideal[index].width + spacing
                }
                return
            }
            for index in subviews.indices {
                place(subviews[index], size: ideal[index], x: x, in: bounds)
                x += ideal[index].width + spacing
            }
            return
        }
        let sizes = columnSizes(bounds.width, subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let size = sizes[index]
            let x: CGFloat = switch columnAlignment {
            case .trailing: bounds.maxX - size.width
            case .center: bounds.midX - size.width / 2
            default: bounds.minX
            }
            subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            y += size.height + (columnSpacing ?? spacing)
        }
    }

    private func place(_ subview: LayoutSubview, size: CGSize, x: CGFloat, in bounds: CGRect) {
        let y: CGFloat = switch rowAlignment {
        case .top, .firstTextBaseline: bounds.minY
        case .bottom, .lastTextBaseline: bounds.maxY - size.height
        default: bounds.midY - size.height / 2
        }
        subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
}

/// Chips in a row, wrapping onto more rows when they run out of room. (A layout rather
/// than ViewThatFits, for the reason given on RowOrColumnLayout.)
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 14

    private func rows(_ width: CGFloat?, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let width, !rows[rows.count - 1].isEmpty, used + spacing + size.width > width + 0.5 {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width, subviews)
        let widths = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)) }
        let heights = rows.map { row in row.map(\.size.height).max() ?? 0 }
        return CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            let height = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

extension EnvironmentValues {
    /// Keys stretch to the width they're given: ActionBar's stacked phone layout, so the
    /// keys line up instead of being as wide as their words.
    @Entry var huntKeysFill = false
}

/// The bottom of a camera screen: the big action in the middle, lesser ones either side.
/// On a phone the big one goes on top, full width, with the others under it, sharing a
/// row if they fit and full width if not.
struct ActionBar<Leading: View, Primary: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var primary: Primary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                // Spacers, not frames: a frame round an empty side is itself nothing, and
                // the big key then slid off centre.
                HStack(spacing: 0) { leading; Spacer(minLength: 0) }.frame(maxWidth: .infinity)
                primary
                HStack(spacing: 0) { Spacer(minLength: 0); trailing }.frame(maxWidth: .infinity)
            }
            VStack(spacing: 12) {
                primary
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        leading
                        trailing
                    }
                    VStack(spacing: 10) {
                        leading
                        trailing
                    }
                }
            }
            .environment(\.huntKeysFill, true)
        }
    }
}

/// A number on a coloured tile, with what it counts underneath.
struct Stat: View {
    let value: String
    let label: String
    var colour: Color = Hunt.paper

    var body: some View {
        VStack(spacing: 0) {
            // One line each, however tight: "1:00" once broke onto two lines in a narrow card.
            Text(value).font(.hunt(30, relativeTo: .title2)).monospacedDigit().foregroundStyle(Hunt.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.chat(.caption, weight: .heavy)).foregroundStyle(Hunt.inkMuted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 84)
        .sticker(colour, radius: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Surfaces

extension View {
    /// A sticker: a flat colour with an ink edge and a hard ink shadow, as if stuck on.
    func sticker(_ colour: Color = Hunt.paper, radius: CGFloat = Hunt.radius, shadow: CGFloat = 4) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(colour))
            .overlay(shape.strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
            .background(shape.fill(Hunt.ink).offset(y: shadow))
    }

    /// A card on the stage, for lists and grouped controls.
    func huntPanel(padding: CGFloat = 18) -> some View {
        self.padding(padding).sticker(Hunt.card, shadow: 6)
    }

    /// A white sticker, for anything over the camera or said out loud.
    func huntPlate(padding: CGFloat = 14) -> some View {
        self.padding(padding).sticker(Hunt.paper, radius: 18)
    }
}

// MARK: - Buttons

/// A chunky sticker button sitting on a darker lip; pressing pushes it down into it.
struct HuntButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, found, sun, ghost }
    var kind: Kind = .primary
    var large = false
    var fill = false
    /// Bigger still: the title screen's two choices on an iPad.
    var hero = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, style: self)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let style: HuntButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.huntKeysFill) private var fillsWidth

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let height: CGFloat = style.hero ? 84 : style.large ? 66 : 52
            let shape = RoundedRectangle(cornerRadius: height * 0.36, style: .continuous)
            let (face, lip, ink) = colours
            let label = configuration.label
                .font(.hunt(style.hero ? 34 : style.large ? 26 : 20, relativeTo: style.large || style.hero ? .title2 : .title3))
                .labelStyle(PillLabelStyle(size: style.hero ? 30 : style.large ? 24 : 18))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(ink)
                .padding(.horizontal, style.hero ? 40 : style.large ? 28 : 20)
                .frame(maxWidth: style.fill || fillsWidth ? .infinity : nil, minHeight: height)

            Group {
                if style.kind == .ghost {
                    label
                        .overlay(shape.strokeBorder(Hunt.text.opacity(0.9), lineWidth: 2.5))
                        .scaleEffect(pressed ? 0.96 : 1)
                } else {
                    label
                        .background(shape.fill(face))
                        // The glossy band across the top of the key: flat, not a gradient.
                        .overlay(alignment: .top) {
                            Capsule().fill(Color.white.opacity(0.32))
                                .frame(height: 5)
                                .padding(.horizontal, height * 0.3)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                        .overlay(shape.strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                        .offset(y: pressed ? Hunt.depth - 1 : 0)
                        .background(shape.fill(lip).overlay(shape.strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                            .offset(y: Hunt.depth))
                        .padding(.bottom, Hunt.depth)
                }
            }
            .saturation(isEnabled ? 1 : 0.15)
            .opacity(isEnabled ? 1 : 0.6)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, new in new }
            // A soft click as the key goes down, like the lip it presses into.
            .onChange(of: pressed) { _, down in if down { Sound.shared.play(.tap) } }
            .contentShape(Rectangle())
        }

        private var colours: (Color, Color, Color) {
            switch style.kind {
            case .primary: return (Hunt.lime, Hunt.limeLip, Hunt.ink)
            case .secondary: return (Hunt.paper, Hunt.paperLip, Hunt.ink)
            case .found: return (Hunt.pink, Hunt.pinkLip, Hunt.ink)
            case .sun: return (Hunt.sun, Hunt.sunLip, Hunt.ink)
            case .ghost: return (.clear, .clear, Hunt.text)
            }
        }
    }

    private struct PillLabelStyle: LabelStyle {
        let size: CGFloat
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: size * 0.35) {
                configuration.icon.font(.system(size: size * 0.8, weight: .black))
                configuration.title
            }
        }
    }
}

extension ButtonStyle where Self == HuntButtonStyle {
    static var huntPrimary: HuntButtonStyle { HuntButtonStyle() }
    static var huntBig: HuntButtonStyle { HuntButtonStyle(large: true) }
    static var huntSecondary: HuntButtonStyle { HuntButtonStyle(kind: .secondary) }
    static var huntGhost: HuntButtonStyle { HuntButtonStyle(kind: .ghost) }
}

/// A coin: sun yellow, an ink edge, a darker ring. The game's one currency (Coins.swift).
struct CoinIcon: View {
    var size: CGFloat = 22

    var body: some View {
        Circle().fill(Hunt.sun)
            .overlay(Circle().strokeBorder(Hunt.sunLip, lineWidth: size * 0.12).padding(size * 0.17))
            .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: max(1.5, size * 0.1)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Coins earned so far this hunt, over the camera. Pops as it climbs, and wears a HALF
/// tag once the hint is on, so the cost stays in view.
struct CoinPill: View {
    let amount: Int
    var halved = false
    @State private var pop = false

    var body: some View {
        HStack(spacing: 7) {
            CoinIcon(size: 22)
            Text("\(amount)")
                .font(.hunt(22, relativeTo: .title3)).monospacedDigit()
                .foregroundStyle(Hunt.ink)
                .contentTransition(.numericText(value: Double(amount)))
            if halved {
                Text("HALF")
                    .font(.hunt(13, relativeTo: .caption))
                    .foregroundStyle(Hunt.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Hunt.cherry))
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(Capsule().fill(Hunt.paper))
        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        .background(Capsule().fill(Hunt.ink).offset(y: 3))
        .fixedSize()
        .scaleEffect(pop ? 1.14 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: amount)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: halved)
        .onChange(of: amount) { old, new in
            guard new > old else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.45)) { pop = true }
            Task {
                try? await Task.sleep(for: .seconds(0.25))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = false }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(amount) coins this hunt" + (halved ? ", at half" : ""))
    }
}

/// The hint key: there from the start of a hunt. Pressing it asks first, and that card
/// is where its cost is said (half the coins for the rest of the hunt). The key itself
/// stays a plain "Hint": a price tag on it read as clutter in testing.
struct HintKey: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Hint", systemImage: "lightbulb.fill") }
            .buttonStyle(HuntButtonStyle(kind: .sun))
    }
}

/// What a round paid, on the results: a sun sticker with the amount, and a line under it
/// (what it was for, or what the player has now). `compact`: just the sticker, smaller,
/// for a phone on its side, where there's no height for the line.
struct CoinsEarned: View {
    let amount: Int
    /// What it was for, if there's more than one thing ("56 finds · 20 never found · 30 top").
    var detail: String?
    var compact = false
    @ObservedObject private var wallet = Wallet.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: compact ? 7 : 10) {
                CoinIcon(size: compact ? 24 : 32)
                Text("+\(amount)")
                    .font(.hunt(compact ? 26 : 36, relativeTo: .title)).monospacedDigit()
                    .foregroundStyle(Hunt.ink)
            }
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 4 : 6)
            .sticker(Hunt.sun, radius: compact ? 16 : 20)
            .fixedSize()
            if !compact {
                Text(detail ?? "You have \(wallet.coins)")
                    .font(.chat(.subheadline, weight: .bold))
                    .foregroundStyle(Hunt.text.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(amount) coins earned. You have \(wallet.coins).")
    }
}

/// A round white sticker button with one symbol: close, back, pause, settings.
struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(Hunt.ink)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(RoundPress())
        .accessibilityLabel(label)
    }

    private struct RoundPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Circle().fill(Hunt.paper))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                .offset(y: configuration.isPressed ? 4 : 0)
                .background(Circle().fill(Hunt.paperLip).overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline)).offset(y: 5))
                .padding(.bottom, 5)
                .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, down in if down { Sound.shared.play(.tap) } }
                .contentShape(Circle())
        }
    }
}

/// One option in a row of choices (time, clue, mode). The chosen one is lime.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.hunt(18, relativeTo: .headline))
                .foregroundStyle(selected ? Hunt.ink : Hunt.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 46)
                .background(Capsule().fill(selected ? Hunt.lime : Hunt.cardHigh))
                .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                .background(Capsule().fill(Hunt.ink).offset(y: selected ? 2 : 4))
                .offset(y: selected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
        .onChange(of: selected) { _, now in if now { Sound.shared.play(.tap) } }
    }
}

/// An on/off switch: a chunky knob in an ink-edged track, lime when on.
struct HuntToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label
                    .font(.chat(.body))
                    .foregroundStyle(Hunt.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Hunt.lime : Hunt.cardHigh)
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                    .frame(width: 60, height: 36)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Hunt.paper)
                            .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
                            .frame(width: 30, height: 30)
                            .padding(3)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isOn)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The same switch on a white card (the studio's options, the hunt's menu).
struct PaperToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.font(.rounded(15, .bold)).foregroundStyle(Hunt.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Hunt.lime : Hunt.paperLip)
                    .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2.5))
                    .frame(width: 52, height: 32)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Hunt.paper).overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2.5))
                            .frame(width: 26, height: 26).padding(3)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isOn)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The player's name, editable in place: what other devices see in squad games.
struct NameField: View {
    @Binding var name: String
    var colour: Int = 0
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name, colour: colour, size: 40)
            TextField("Name", text: $name)
                .font(.hunt(24, relativeTo: .title3))
                .foregroundStyle(Hunt.ink)
                .tint(Hunt.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($editing)
                .onChange(of: name) { _, value in
                    if value.count > 16 { name = String(value.prefix(16)) }
                }
            Image(systemName: "pencil").font(.system(size: 17, weight: .black)).foregroundStyle(Hunt.inkMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 62)
        .sticker(editing ? Hunt.sun : Hunt.paper, radius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { editing = true }
    }
}

// MARK: - The crew

/// A player: their chameleon, in their colour, on a white token.
struct Avatar: View {
    let name: String
    let colour: Int
    var size: CGFloat = 40

    var body: some View {
        MascotImage(pose: .standing, view: .front, resolution: Int(size * 3), tint: Hunt.playerTint(colour))
            .scaleEffect(1.25)
            .offset(y: size * 0.08)
            .frame(width: size, height: size)
            .background(Circle().fill(Hunt.paper))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: max(2, size * 0.07)))
            .accessibilityHidden(true)
    }
}

/// Players as chameleons standing in a row on the stage, names underneath — the lobby
/// line-up. The host wears the crown.
struct CrewLineup: View {
    let players: [SquadPlayer]
    var me: UUID?
    var hostID: UUID?
    var size: CGFloat = 96
    var ticked: Set<UUID>? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.08) {
            ForEach(players) { player in
                VStack(spacing: 4) {
                    ZStack(alignment: .top) {
                        let busy = ticked.map { !$0.contains(player.id) } ?? false
                        MascotImage(pose: .standing, view: .hero, resolution: Int(size * 3), tint: Hunt.playerTint(player.colour))
                            .frame(width: size, height: size)
                            // Still busy (still hiding, say): a silhouette, like the tally's
                            // unfound ones, until they're done.
                            .overlay {
                                if busy {
                                    Hunt.ink.mask {
                                        MascotImage(pose: .standing, view: .hero, resolution: Int(size * 3),
                                                    tint: Hunt.playerTint(player.colour))
                                    }
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if let ticked {
                                    if ticked.contains(player.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: size * 0.24, weight: .black))
                                            .foregroundStyle(Hunt.ink, Hunt.lime)
                                            .accessibilityLabel("Ready")
                                    } else {
                                        LoadingDots(colour: Hunt.text, size: max(6, size * 0.07))
                                            .padding(.top, size * 0.06)
                                            .accessibilityLabel("Still going")
                                    }
                                }
                            }
                            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: busy)
                        if player.id == hostID {
                            Image(systemName: "crown.fill")
                                .font(.system(size: size * 0.22, weight: .black))
                                .foregroundStyle(Hunt.sun)
                                .shadow(color: Hunt.ink, radius: 0, x: 0, y: 2)
                                .offset(x: size * 0.08, y: -size * 0.1)
                                .accessibilityLabel("Host")
                        }
                    }
                    Text(player.id == me ? "You" : player.name)
                        .font(.hunt(size * 0.19, relativeTo: .headline))
                        .foregroundStyle(Hunt.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .sticker(Hunt.player(player.colour), radius: 10, shadow: 3)
                        .frame(maxWidth: size * 1.1)
                }
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: players)
    }
}

// MARK: - Over the camera

/// A white sticker pill: an icon and a few words or a number.
struct HUDPill: View {
    let systemImage: String
    let text: String
    var tint: Color = Hunt.ink
    /// Paper, or a player's colour when it's about them.
    var fill: Color = Hunt.paper

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .black)).foregroundStyle(tint)
            Text(text).font(.hunt(19, relativeTo: .headline)).foregroundStyle(Hunt.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        .background(Capsule().fill(Hunt.ink).offset(y: 3))
        .accessibilityElement(children: .combine)
    }
}

/// The clock, big, on a sun-yellow sticker. In the last ten seconds it turns pink and
/// beats once a second (dims, under Reduce Motion).
struct ClockPill: View {
    let seconds: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var beat: Bool { seconds > 0 && seconds <= 10 && seconds % 2 == 0 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stopwatch.fill").font(.system(size: 20, weight: .black))
            Text(GameConfig.stopwatch(max(0, seconds))).font(.hunt(32, relativeTo: .title)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(Hunt.ink)
        .fixedSize()
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .background(Capsule().fill(Hunt.sun))
        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        .background(Capsule().fill(Hunt.ink).offset(y: 4))
        .scaleEffect(beat && !reduceMotion ? 1.1 : 1)
        .opacity(beat && reduceMotion ? 0.7 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: seconds)
        // The last ten seconds tick, in time with the beat.
        .onChange(of: seconds) { old, new in
            if new < old, new > 0, new <= 10 { Sound.shared.play(.tick) }
        }
        .accessibilityLabel("\(seconds) seconds left")
    }
}

/// Three dots hopping in turn: waiting for something (in place of the system spinner).
/// Still dots under Reduce Motion.
struct LoadingDots: View {
    var colour: Color = Hunt.ink
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(colour)
                        .frame(width: size, height: size)
                        .offset(y: -max(0, sin((t * 2.4 - Double(i) * 0.33) * .pi * 2)) * size * 0.8)
                }
            }
            .frame(height: size * 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Waiting")
    }
}

/// Counts down to a date, a few times a second.
struct Countdown<Content: View>: View {
    let until: Date?
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            content(Int(ceil(max(0, (until ?? context.date).timeIntervalSince(context.date)))))
        }
    }
}

// MARK: - Backgrounds

/// The stage: electric violet with sunburst rays turning slowly behind `focus`, like the
/// show's lights. Still under Reduce Motion.
struct HuntBackground: View {
    var focus: UnitPoint = .center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The rays turn slowly, so 15 redraws a second is plenty and leaves the rest of the
        // screen room to breathe.
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(Gradient(colors: [Hunt.stageTop, Hunt.stage, Hunt.stageBottom]),
                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                let centre = CGPoint(x: size.width * focus.x, y: size.height * focus.y)
                let reach = hypot(size.width, size.height)
                let rays = 18
                let step = 2 * Double.pi / Double(rays)
                let turn = (t * 0.035).truncatingRemainder(dividingBy: step * 2)
                for i in stride(from: 0, to: rays, by: 2) {
                    let start = Double(i) * step + turn
                    var wedge = Path()
                    wedge.move(to: centre)
                    wedge.addLine(to: CGPoint(x: centre.x + cos(start) * reach, y: centre.y + sin(start) * reach))
                    wedge.addLine(to: CGPoint(x: centre.x + cos(start + step) * reach, y: centre.y + sin(start + step) * reach))
                    wedge.closeSubpath()
                    canvas.fill(wedge, with: .color(.white.opacity(0.055)))
                }
                // A soft pool of light behind the focus.
                let glow = reach * 0.3
                canvas.fill(Path(ellipseIn: CGRect(x: centre.x - glow, y: centre.y - glow, width: glow * 2, height: glow * 2)),
                            with: .radialGradient(Gradient(colors: [.white.opacity(0.16), .clear]), center: centre,
                                                  startRadius: 0, endRadius: glow))
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The dark stage for the tense moments — the seeker's turn, "look away" — with one
/// spotlight coming down on whoever it's about. Mark the one in the light with
/// `.spotlightSubject()`: the beam finds it wherever the layout puts it, in either
/// orientation, and lands at its feet.
struct SpotlightStage<Content: View>: View {
    var colour: Color = Hunt.paper
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backgroundPreferenceValue(SpotlightSubjectKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        SpotlightBeam(subject: proxy[anchor], colour: colour, reachAbove: proxy.safeAreaInsets.top + 40)
                    }
                }
            }
            .background(Hunt.ink.ignoresSafeArea())
    }
}

struct SpotlightSubjectKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// The one the spotlight shines on (see SpotlightStage).
    func spotlightSubject() -> some View {
        anchorPreference(key: SpotlightSubjectKey.self, value: .bounds) { $0 }
    }
}

/// A beam from above the top of the screen down onto `subject`'s feet, and the pool of
/// light it makes on the floor.
private struct SpotlightBeam: View {
    let subject: CGRect
    let colour: Color
    let reachAbove: CGFloat

    var body: some View {
        Canvas { canvas, _ in
            let centre = subject.midX
            // The chameleon's feet sit a little above the bottom of its picture.
            let floorY = subject.maxY - subject.height * 0.1
            let spread = subject.width * 0.62
            var beam = Path()
            beam.move(to: CGPoint(x: centre - spread * 0.28, y: -reachAbove))
            beam.addLine(to: CGPoint(x: centre + spread * 0.28, y: -reachAbove))
            beam.addLine(to: CGPoint(x: centre + spread, y: floorY))
            beam.addLine(to: CGPoint(x: centre - spread, y: floorY))
            beam.closeSubpath()
            canvas.fill(beam, with: .linearGradient(Gradient(colors: [colour.opacity(0.04), colour.opacity(0.26)]),
                                                    startPoint: CGPoint(x: centre, y: -reachAbove),
                                                    endPoint: CGPoint(x: centre, y: floorY)))
            canvas.fill(Path(ellipseIn: CGRect(x: centre - spread, y: floorY - spread * 0.17, width: spread * 2, height: spread * 0.34)),
                        with: .color(colour.opacity(0.32)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Big moments

/// A spiky starburst sticker, for behind a big word.
struct Burst: Shape {
    var points = 14
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<(points * 2) {
            let angle = Double(i) / Double(points * 2) * 2 * .pi - .pi / 2
            let reach = i.isMultiple(of: 2) ? 1.0 : 0.8
            let point = CGPoint(x: centre.x + cos(angle) * rect.width / 2 * reach, y: centre.y + sin(angle) * rect.height / 2 * reach)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A big word that lands: in large and tilted, bouncing into place — the show's
/// announcer. Optionally on a starburst. Reduce Motion: a fade.
struct Slam: View {
    let text: String
    var colour: Color = Hunt.text
    var size: CGFloat = 96
    var trigger: Int = 0
    var burst: Color? = nil
    @State private var scale: CGFloat = 1
    @State private var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Shrinks to fit a phone rather than running off the sides.
        ViewThatFits(in: .horizontal) {
            lettering(size)
            lettering(size * 0.75)
            lettering(size * 0.56)
            lettering(size * 0.42)
        }
            .rotationEffect(.degrees(-4))
            .scaleEffect(scale)
            .opacity(shown ? 1 : 0)
            .onAppear(perform: slam)
            .onChange(of: trigger) { _, _ in slam() }
            .accessibilityAddTraits(.isHeader)
    }

    private func lettering(_ size: CGFloat) -> some View {
        ShowText(text: text.uppercased(), size: size, fill: colour)
            .padding(.horizontal, burst == nil ? 0 : size * 0.55)
            .padding(.vertical, burst == nil ? 0 : size * 0.5)
            .background {
                if let burst {
                    Burst().fill(burst).overlay(Burst().stroke(Hunt.ink, lineWidth: Hunt.outline + 1))
                }
            }
    }

    private func slam() {
        if reduceMotion {
            shown = false
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
            return
        }
        scale = 1.8
        shown = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.52)) {
            scale = 1
            shown = true
        }
    }
}

/// Confetti for a win, in the show's colours.
struct Confetti: View {
    private struct Piece {
        let x: Double, delay: Double, speed: Double, spin: Double, size: Double, colour: Color
    }

    private let pieces: [Piece] = (0..<110).map { _ in
        Piece(x: .random(in: 0...1), delay: .random(in: 0...0.5), speed: .random(in: 0.5...0.95),
              spin: .random(in: -6...6), size: .random(in: 9...15),
              colour: [Hunt.lime, Hunt.sun, Hunt.pink, Hunt.cyan, Hunt.orange, .white].randomElement()!)
    }
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start)
                Canvas { canvas, size in
                    guard t < 4 else { return }
                    for piece in pieces {
                        let local = t - piece.delay
                        guard local > 0 else { continue }
                        let y = -20 + local * piece.speed * size.height * 0.6
                        guard y < size.height + 20 else { continue }
                        let x = piece.x * size.width + sin(local * 2 + piece.spin) * 22
                        var shape = canvas
                        shape.translateBy(x: x, y: y)
                        shape.rotate(by: .radians(local * piece.spin))
                        shape.opacity = max(0, 1 - max(0, t - 3))
                        let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                        shape.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(piece.colour))
                        shape.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(Hunt.ink), lineWidth: 1.5)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Found so far, as a row of little chameleons on a white sticker: found ones pink,
/// the rest dark silhouettes. Where a row won't fit (a phone, and a big swarm), one pink
/// chameleon and the count.
struct FoundTally: View {
    let found: Int
    let total: Int
    var size: CGFloat = 34
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 6) {
                    MascotImage(pose: .standing, view: .hero, resolution: 120, tint: .bubblegum)
                        .frame(width: size, height: size)
                    Text("\(found)/\(total)")
                        .font(.hunt(26, relativeTo: .title2)).monospacedDigit()
                        .foregroundStyle(Hunt.ink)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: found)
                }
            } else {
                HStack(spacing: -size * 0.2) {
                    ForEach(0..<max(total, 0), id: \.self) { index in
                        MascotImage(pose: .standing, view: .hero, resolution: 120, tint: index < found ? .bubblegum : .natural)
                            .frame(width: size, height: size)
                            .colorMultiply(index < found ? .white : Hunt.ink.opacity(0.35))
                            .scaleEffect(index < found ? 1.1 : 0.9)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: found)
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(Capsule().fill(Hunt.paper))
        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        .background(Capsule().fill(Hunt.ink).offset(y: 3))
        .accessibilityElement()
        .accessibilityLabel("\(found) of \(total) found")
    }
}
