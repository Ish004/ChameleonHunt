//
//  StudioView.swift
//  The paint studio.
//
//  Laid out like the iPad painting apps people already know — Procreate above all — so
//  nothing needs explaining: brush size and strength in a slim column on the left, the
//  current colour as a round well at the top right, two-finger tap to undo and three to
//  redo. What's different here is who it's for. Most players won't own a Pencil, so a
//  finger paints; every tool has a word under it, not just an icon; and the single most
//  useful thing in the room — "make it match for me" — is a word button rather than one
//  icon among many, next to Done but never louder than it.
//
//  Every menu, picker and question is the game's own (a DropCard or a Notice), not the
//  system's.
//

import SwiftUI
import RealityKit

struct StudioViewport: UIViewRepresentable {
    let controller: StudioController

    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct StudioView: View {
    @ObservedObject var studio: StudioController
    let isDemo: Bool
    /// False while the camera's AR view is still fading out: only one RealityKit view
    /// may be in the window at a time.
    var showsViewport = true
    let onPlaceInAR: @MainActor () -> Void
    let onExit: @MainActor () -> Void

    @State private var showPoses = false
    @State private var showColours = false
    @State private var showOptions = false
    @Environment(\.showNotice) private var showNotice
    /// A phone: the bars take two rows, and the cards drop from under them.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { sizeClass == .compact }
    /// A phone on its side: the bars fit in one row, but the rails are taller than the
    /// screen, so each folds into two columns (they used to push the top bar off it).
    private var short: Bool { verticalSizeClass == .compact }
    /// A phone upright: two rows of bars, and the cards drop from under them, centred.
    private var upright: Bool { compact && !short }
    private var smallRails: Bool { compact || short }
    private var belowBars: CGFloat { short ? 80 : compact ? 150 : 100 }
    private var cardOpen: Bool { showPoses || showColours || showOptions }
    private var cardTop: CGFloat { short ? 70 : 84 }

    var body: some View {
        ZStack {
            if showsViewport {
                StudioViewport(controller: studio)
                    .ignoresSafeArea()
            }

            // On a phone an open card covers most of both rails, so they step aside
            // rather than poke out from behind it.
            BrushSidebar(studio: studio, compact: smallRails, sideBySide: short)
                .padding(.leading, smallRails ? 10 : 18)
                .padding(.top, belowBars)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(smallRails && cardOpen ? 0 : 1)

            ToolRail(studio: studio, compact: smallRails, twoColumns: short,
                     onFill: studio.fillWithCurrentColor, onClear: confirmClear)
                .padding(.trailing, smallRails ? 10 : 18)
                .padding(.top, belowBars)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(smallRails && cardOpen ? 0 : 1)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                // On a phone on its side an open card reaches down over the bottom bar, so
                // the bar steps aside too; tapping outside the card brings it back.
                bottomBar
                    .opacity(short && cardOpen ? 0 : 1)
                    .allowsHitTesting(!(short && cardOpen))
            }
            .padding(.horizontal, smallRails ? 12 : 18)
            .padding(.vertical, short ? 10 : 16)

            if showPoses {
                DropCard(isPresented: $showPoses, alignment: upright ? .top : .topLeading, width: 300) { posePicker }
                    .padding(.top, upright ? belowBars - 60 : cardTop).padding(.leading, upright ? 0 : 84)
            }
            if showColours {
                DropCard(isPresented: $showColours, alignment: upright ? .top : .topTrailing, width: short ? 520 : 300) {
                    ColourPanel(studio: studio, wide: short) { showColours = false }
                }
                .padding(.top, upright ? belowBars - 20 : cardTop).padding(.trailing, upright ? 0 : 150)
            }
            if showOptions {
                DropCard(isPresented: $showOptions, alignment: upright ? .top : .topTrailing, width: compact ? 300 : 340) { options }
                    .padding(.top, upright ? belowBars - 20 : cardTop).padding(.trailing, upright ? 0 : 124)
            }

            if let message = studio.busyMessage {
                BusyOverlay(message: message, progress: studio.busyProgress)
            }
        }
        .foregroundStyle(Hunt.ink)
        #if DEBUG
        // `-demoPanel poses|colours|options` opens one, for screenshots.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-demoPanel"), i + 1 < args.count else { return }
            switch args[i + 1] {
            case "poses": showPoses = true
            case "colours": showColours = true
            case "options": showOptions = true
            case "pose": confirmPose(studio.pose == .standing ? .curled : .standing)
            case "clear": confirmClear()
            default: break
            }
        }
        #endif
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showPoses)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showColours)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showOptions)
    }

    // MARK: - Questions

    private func confirmClear() {
        showNotice(Notice(title: "Clear all the paint?", message: "It goes back to plain white. You can undo this.",
                          systemImage: "trash.fill", tint: Hunt.cherry,
                          primary: .init(title: "Clear all") { [studio] in studio.resetPaint() },
                          secondary: .init(title: "Keep it")))
    }

    private func confirmPose(_ pose: CharacterPose) {
        showPoses = false
        guard pose != studio.pose else { return }
        showNotice(Notice(title: "Change to \(pose.displayName.lowercased())?",
                          message: "Your paint moves with it. Where the body bends, it may need a touch-up.",
                          systemImage: pose.systemImage, tint: Hunt.lime,
                          primary: .init(title: "Change pose") { [studio] in studio.changePose(to: pose) },
                          secondary: .init(title: "Cancel")))
    }

    private func confirmExit() {
        showNotice(Notice(title: isDemo ? "Stop practising?" : "Stop this game?",
                          message: isDemo ? "This practice paint job won't be kept." : "The hiding spot and the paint job will be lost.",
                          systemImage: "xmark", tint: Hunt.cherry,
                          primary: .init(title: isDemo ? "Leave" : "Stop game", run: onExit),
                          secondary: .init(title: "Keep painting")))
    }

    // MARK: - Top

    private var topBar: some View {
        // On a phone it doesn't all fit in one row: the way out and the pose on top;
        // undo, colour and options under them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                leadingControls
                Spacer(minLength: 0)
                editingControls
            }
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    leadingControls
                    Spacer(minLength: 0)
                }
                editingControls
            }
        }
    }

    private var leadingControls: some View {
        HStack(spacing: 10) {
            IconButton(systemImage: "xmark", label: isDemo ? "Leave" : "Stop game") { confirmExit() }
            if CharacterPose.poses(for: studio.scene.surface).count > 1 { poseButton }
        }
    }

    private var editingControls: some View {
        HStack(spacing: 10) {
            undoRedo
            ColourWell(colour: studio.color) { showColours.toggle() }
            roundButton("slider.horizontal.3", label: "Studio options") { showOptions.toggle() }
        }
    }

    private var poseButton: some View {
        Button { showPoses.toggle() } label: {
            HStack(spacing: 8) {
                MascotImage(pose: studio.pose, view: .hero, resolution: 120)
                    .frame(width: 34, height: 34)
                Text(studio.pose.displayName).font(.hunt(20, relativeTo: .headline))
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .black))
                    .rotationEffect(.degrees(showPoses ? 180 : 0))
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .frame(height: Metric.tap)
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel("Pose: \(studio.pose.displayName)")
    }

    private var undoRedo: some View {
        HStack(spacing: 10) {
            roundButton("arrow.uturn.backward", label: "Undo") { studio.undo() }
                .disabled(!studio.canUndo)
            roundButton("arrow.uturn.forward", label: "Redo") { studio.redo() }
                .disabled(!studio.canRedo)
        }
    }

    private var doneButton: some View {
        Button {
            if isDemo { onExit() } else { onPlaceInAR() }
        } label: {
            Label(isDemo ? "Done" : "Done painting", systemImage: "checkmark").frame(minWidth: 200)
        }
        .buttonStyle(HuntButtonStyle(large: true, fill: compact))
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .black))
                .frame(width: Metric.tap, height: Metric.tap)
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel(label)
    }

    private var posePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POSE").font(.hunt(20, relativeTo: .headline))
            ForEach(CharacterPose.poses(for: studio.scene.surface)) { pose in
                Button { confirmPose(pose) } label: {
                    HStack(spacing: 12) {
                        MascotImage(pose: pose, view: .hero, resolution: 180)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pose.displayName).font(.hunt(22, relativeTo: .title3))
                            Text(pose.hint).font(.rounded(13, .bold)).foregroundStyle(Hunt.inkMuted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if pose == studio.pose {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 22, weight: .black))
                                .foregroundStyle(Hunt.ink, Hunt.lime)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(pose == studio.pose ? Hunt.lime.opacity(0.35) : Hunt.paperLip.opacity(0.35)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pose == studio.pose ? .isSelected : [])
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STUDIO").font(.hunt(20, relativeTo: .headline))
            Group {
                Toggle(isOn: $studio.fingerPaints) { Label("Paint with your finger", systemImage: "hand.draw.fill") }
                Toggle(isOn: $studio.showEnvironment) { Label("Show the room around it", systemImage: "cube.transparent.fill") }
                Toggle(isOn: $studio.shapeShading) { Label("Show its shape", systemImage: "light.max") }
            }
            .toggleStyle(PaperToggleStyle())
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Chameleon size", systemImage: "arrow.up.left.and.arrow.down.right").font(.rounded(15, .bold))
                    Spacer()
                    Text("\(Int((CharacterPose.nominalHeightMeters * studio.characterScale * 100).rounded())) cm")
                        .font(.readout(18))
                }
                StickerSlider(value: $studio.characterScale, range: CharacterPose.scaleRange)
            }
            Button(action: { studio.resetCamera(); showOptions = false }) {
                Label("Centre the view", systemImage: "scope")
            }
            .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
            Label(studio.fingerPaints
                  ? "Finger on it paints. Drag off it to turn. Pinch to zoom. Two-finger tap undoes."
                  : "The Pencil paints. One finger turns, two move, pinch zooms.",
                  systemImage: "hand.tap.fill")
                .font(.rounded(13, .bold))
                .foregroundStyle(Hunt.inkMuted)
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Text(studio.tool.hint + (studio.fingerPaints ? " · drag off it to turn" : ""))
                .font(.rounded(15, .bold))
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(Capsule().fill(Hunt.paper))
                .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2.5))

            // Done is the one big key, like the end of every screen; Magic camouflage is
            // a helper beside it. (It used to be the biggest thing here and drowned Done
            // out.) On a phone they stack, Done at the bottom under the thumb.
            HStack(alignment: .center, spacing: 14) {
                if !studio.recentColors.isEmpty && !compact { recentColours }
                RowOrColumnLayout(columnAlignment: .center, spacing: 14) {
                    magicButton
                    doneButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var recentColours: some View {
        HStack(spacing: 8) {
            ForEach(Array(studio.recentColors.prefix(8).enumerated()), id: \.offset) { _, recent in
                Button {
                    studio.color = recent
                    if studio.tool == .eyedropper { studio.tool = .brush }
                } label: {
                    Circle()
                        .fill(Color(color3: recent))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recent colour")
            }
        }
        .padding(8)
        .background(Capsule().fill(Hunt.paper))
        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: Hunt.outline))
        .background(Capsule().fill(Hunt.ink).offset(y: 4))
    }

    /// The one-tap answer to "make it disappear".
    private var magicButton: some View {
        Button(action: studio.autoCamouflage) {
            Label("Magic camouflage", systemImage: "wand.and.stars")
        }
        .buttonStyle(HuntButtonStyle(kind: .secondary, fill: compact))
    }
}

// MARK: - Sidebar

/// Brush size on top, strength underneath — the column every iPad painting app has,
/// under the off-hand thumb.
private struct BrushSidebar: View {
    @ObservedObject var studio: StudioController
    var compact = false
    /// A phone on its side: the two bars next to each other, and shorter.
    var sideBySide = false

    var body: some View {
        let height: CGFloat = sideBySide ? 110 : compact ? 130 : 170
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            // Squared, so the fine sizes get as much of the bar as the big ones.
            VerticalSlider(value: $studio.brushSizeCentimeters, range: 0.15...8, curve: 2,
                           readout: { $0 < 1 ? String(format: "%.2f cm", $0) : String(format: "%.1f cm", $0) },
                           icon: "circle.fill", label: "Size", height: height)
            VerticalSlider(value: $studio.opacity, range: 0.05...1,
                           readout: { "\(Int($0 * 100))%" }, icon: "drop.fill", label: "Strength", height: height)
        }
        .padding(8)
        .sticker(Hunt.paper, radius: 24)
    }
}

/// Drag anywhere along it. The whole bar is the control, not a small knob on a hairline.
private struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// 1 is linear; 2 gives the low end more room.
    var curve: Float = 1
    let readout: (Float) -> String
    let icon: String
    let label: String
    var height: CGFloat = 170

    @State private var dragging = false
    private let width: CGFloat = 46

    private var fraction: CGFloat {
        CGFloat(pow((value - range.lowerBound) / (range.upperBound - range.lowerBound), 1 / curve))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Hunt.paperLip.opacity(0.5))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Hunt.lime)
                    .frame(height: max(18, height * fraction))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Hunt.ink)
                    .padding(.bottom, 9)
            }
            .frame(width: width, height: height)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Hunt.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if dragging {
                    Text(readout(value))
                        .font(.readout(18))
                        .foregroundStyle(Hunt.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Hunt.sun))
                        .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2.5))
                        .fixedSize()
                        .offset(x: 96)
                        .transition(.opacity)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let t = Float(1 - min(max(drag.location.y / height, 0), 1))
                        value = range.lowerBound + pow(t, curve) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragging = false }
            )
            Text(label.uppercased()).font(.hunt(13, relativeTo: .caption)).foregroundStyle(Hunt.ink)
        }
        .animation(.easeOut(duration: 0.12), value: dragging)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(readout(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - Tools

private struct ToolRail: View {
    @ObservedObject var studio: StudioController
    var compact = false
    /// A phone on its side: the tools in one column, Fill all and Clear all in another.
    var twoColumns = false
    let onFill: () -> Void
    let onClear: () -> Void

    var body: some View {
        Group {
            if twoColumns {
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 6) { tools }
                    Rectangle().fill(Hunt.ink).frame(width: 2.5, height: 44).clipShape(Capsule()).padding(.horizontal, 3)
                        .padding(.top, 4)
                    VStack(spacing: 6) { actions }
                }
            } else {
                VStack(spacing: 6) {
                    tools
                    Rectangle().fill(Hunt.ink).frame(width: 44, height: 2.5).clipShape(Capsule()).padding(.vertical, 3)
                    actions
                }
            }
        }
        .padding(7)
        .sticker(Hunt.paper, radius: 24)
    }

    private var tools: some View {
        ForEach(StudioController.Tool.allCases) { tool in
            RailButton(title: tool.title, systemImage: tool.systemImage, selected: studio.tool == tool, compact: compact) {
                studio.tool = tool
            }
        }
    }

    @ViewBuilder private var actions: some View {
        RailButton(title: "Fill all", systemImage: "drop.fill", selected: false, compact: compact, action: onFill)
        RailButton(title: "Clear all", systemImage: "trash.fill", selected: false, compact: compact, action: onClear)
    }
}

/// An icon with its name under it. Icons alone are a quiz.
private struct RailButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: compact ? 18 : 20, weight: .black))
                Text(title).font(.hunt(compact ? 11 : 13, relativeTo: .caption)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: compact ? 60 : 72, height: compact ? 52 : 60)
        }
        .buttonStyle(ToolButtonStyle(selected: selected))
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The current colour, as a well that opens the picker.
private struct ColourWell: View {
    let colour: Color3
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(color3: colour))
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 3))
                .frame(width: 36, height: 36)
                .frame(width: Metric.tap, height: Metric.tap)
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel("Colour")
    }
}

/// Picking a colour: a hue bar, a shade square, recent colours, and a shortcut to take
/// one straight from the room — which is usually quicker than matching by eye.
private struct ColourPanel: View {
    @ObservedObject var studio: StudioController
    /// A phone on its side: the shade square beside the rest, so the card fits the height.
    var wide = false
    let close: () -> Void
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    shades.frame(width: 200, height: 200)
                    VStack(alignment: .leading, spacing: 14) { controls }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    shades.frame(height: 170)
                    hueAndMore
                }
            }
        }
        .onAppear { load(studio.color) }
        .onChange(of: hue) { _, _ in apply() }
        .onChange(of: saturation) { _, _ in apply() }
        .onChange(of: brightness) { _, _ in apply() }
    }

    @ViewBuilder private var controls: some View {
        header
        hueAndMore
    }

    private var header: some View {
        HStack {
            Text("COLOUR").font(.hunt(20, relativeTo: .headline))
            Spacer()
            Circle().fill(current)
                .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 3))
                .frame(width: 40, height: 40)
        }
    }

    private var shades: some View {
        ShadeSquare(hue: hue, saturation: $saturation, brightness: $brightness, onEnd: commit)
    }

    @ViewBuilder private var hueAndMore: some View {
        HueBar(hue: $hue, onEnd: commit)
            .frame(height: 34)
        if !studio.recentColors.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(studio.recentColors.prefix(7).enumerated()), id: \.offset) { _, recent in
                    Button { load(recent); commit() } label: {
                        Circle().fill(Color(color3: recent))
                            .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 2.5))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recent colour")
                }
            }
        }
        Button {
            studio.tool = .eyedropper
            close()
        } label: {
            Label("Pick from the room", systemImage: "eyedropper.halffull")
        }
        .buttonStyle(HuntButtonStyle(kind: .secondary, fill: true))
    }

    private var current: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    private func load(_ colour: Color3) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h); saturation = Double(s); brightness = Double(b)
    }

    private var picked: Color3 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color3(clamp01(Float(r)), clamp01(Float(g)), clamp01(Float(b)))
    }

    private func apply() {
        studio.color = picked
        if studio.tool != .brush { studio.tool = .brush }
    }

    /// Remembered once the finger lifts, not on every step of a drag.
    private func commit() {
        studio.remember(picked)
    }
}

/// Saturation across, brightness down, for the current hue.
private struct ShadeSquare: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                shape.fill(LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                                          startPoint: .leading, endPoint: .trailing))
                shape.fill(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 1.5).padding(-1.5))
                    .frame(width: 28, height: 28)
                    .position(x: saturation * proxy.size.width, y: (1 - brightness) * proxy.size.height)
            }
            .overlay(shape.strokeBorder(Hunt.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    saturation = min(max(drag.location.x / proxy.size.width, 0), 1)
                    brightness = 1 - min(max(drag.location.y / proxy.size.height, 0), 1)
                }
                .onEnded { _ in onEnd() })
        }
        .accessibilityElement()
        .accessibilityLabel("Shade")
        .accessibilityValue("\(Int(saturation * 100))% colour, \(Int(brightness * 100))% bright")
        .accessibilityAdjustableAction { direction in
            brightness = min(max(brightness + (direction == .increment ? 0.1 : -0.1), 0), 1)
            onEnd()
        }
    }
}

/// The rainbow, left to right.
private struct HueBar: View {
    @Binding var hue: Double
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let shape = Capsule()
            ZStack(alignment: .leading) {
                shape.fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                          startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .overlay(Circle().strokeBorder(Hunt.ink, lineWidth: 1.5).padding(-1.5))
                    .frame(width: proxy.size.height, height: proxy.size.height)
                    .offset(x: hue * (proxy.size.width - proxy.size.height))
            }
            .overlay(shape.strokeBorder(Hunt.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in hue = min(max(drag.location.x / proxy.size.width, 0), 0.999) }
                .onEnded { _ in onEnd() })
        }
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int(hue * 360)) degrees")
        .accessibilityAdjustableAction { direction in
            hue = min(max(hue + (direction == .increment ? 0.05 : -0.05), 0), 0.999)
            onEnd()
        }
    }
}

/// A horizontal slider in the same style as the brush column.
struct StickerSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { proxy in
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Hunt.paperLip.opacity(0.5))
                Capsule().fill(Hunt.lime).frame(width: max(proxy.size.height, proxy.size.width * t))
            }
            .overlay(Capsule().strokeBorder(Hunt.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = Float(min(max(drag.location.x / proxy.size.width, 0), 1))
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// A switch for the studio's white panels: ink text, lime when on.
extension Color {
    init(color3 c: Color3) {
        self.init(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
