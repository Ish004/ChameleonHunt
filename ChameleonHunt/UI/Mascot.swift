//
//  Mascot.swift
//  The chameleon as a picture, for menus, pickers and the clue.
//
//  Rendered from the game's own model by MascotRenderer, off the main thread, once per
//  pose and view, then cached — so it costs a few tens of milliseconds the first time
//  it's shown and nothing after.
//

import SwiftUI

@MainActor
final class MascotLibrary: ObservableObject {
    static let shared = MascotLibrary()

    struct Key: Hashable {
        let pose: CharacterPose
        let view: MascotRenderer.View
        let size: Int
        var tint: MascotTint = .natural
        /// The skin it wears when it's in its own colours (`tint` is `.natural`).
        var skin: ChameleonSkin = .classic
    }

    @Published private(set) var images: [Key: UIImage] = [:]
    private var pending: Set<Key> = []

    func image(_ key: Key) -> UIImage? {
        if let image = images[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        Task.detached(priority: .userInitiated) {
            let palette = key.tint == .natural ? key.skin.palette : key.tint.palette
            let rendered = MascotRenderer.render(key.pose, view: key.view, size: key.size, palette: palette)
            let image = Self.makeImage(rendered)
            await MainActor.run {
                self.images[key] = image
                self.pending.remove(key)
            }
        }
        return nil
    }

    /// Renders the ones the start screen needs before it appears, so it doesn't pop in.
    func warmUp() {
        _ = image(Key(pose: .standing, view: .hero, size: 720))
        for tint in MascotTint.allCases { _ = image(Key(pose: .standing, view: .hero, size: 720, tint: tint)) }
        for pose in CharacterPose.allCases { _ = image(Key(pose: pose, view: .hero, size: 240)) }
    }

    nonisolated static func makeImage(_ rendered: MascotRenderer.Image) -> UIImage? {
        let data = Data(rendered.pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: rendered.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }
}

/// The chameleon wearing another colour — how it looks having blended into something,
/// or a squad player's colour. Its eyes never change, which is the joke on the home
/// screen: only they give it away.
enum MascotTint: String, CaseIterable, Hashable, Sendable {
    case natural, sun, bubblegum, sky, tangerine, cherry

    var palette: MascotRenderer.Palette {
        func camo(_ c: Vec3) -> MascotRenderer.Palette {
            var palette = MascotRenderer.Palette()
            palette.body = c
            palette.back = c * 0.86
            palette.belly = c + (Vec3(repeating: 1) - c) * 0.3
            return palette
        }
        switch self {
        case .natural: return MascotRenderer.Palette()
        case .sun: return camo([1.0, 0.824, 0.247])
        case .bubblegum: return camo([1.0, 0.31, 0.65])
        case .sky: return camo([0.247, 0.816, 0.957])
        case .tangerine: return camo([1.0, 0.541, 0.239])
        case .cherry: return camo([1.0, 0.337, 0.337])
        }
    }
}

/// The chameleon, in a pose, as a picture. Fades in once it's ready.
struct MascotImage: View {
    var pose: CharacterPose = .standing
    var view: MascotRenderer.View = .hero
    var resolution: Int = 360
    var tint: MascotTint = .natural
    /// Worn when it's in its own colours.
    var skin: ChameleonSkin = .classic

    @ObservedObject private var library = MascotLibrary.shared

    var body: some View {
        let key = MascotLibrary.Key(pose: pose, view: view, size: resolution, tint: tint, skin: tint == .natural ? skin : .classic)
        ZStack {
            if let image = library.image(key) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeOut(duration: 0.25), value: library.image(key) != nil)
    }
}
