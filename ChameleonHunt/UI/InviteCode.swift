//
//  InviteCode.swift
//  "Get the game": a QR code for the App Store page, on a sticker in the squad lobby, for
//  friends in the room who don't have it yet — they scan the host's screen and they're in
//  the next game. A squad game needs everyone to have the app, so every game night is a
//  chance for it to spread.
//
//  Shows nothing until the game has a store link (AppLinks.appStore).
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct InviteCode: View {
    var size: CGFloat = 116

    var body: some View {
        if let link = AppLinks.appStore, let code = Self.code(for: link.absoluteString) {
            HStack(spacing: 14) {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GET THE GAME").font(.hunt(22, relativeTo: .headline)).foregroundStyle(Hunt.ink)
                    Text("Friends scan this, then join from Games nearby.")
                        .font(.chat(.subheadline, weight: .bold))
                        .foregroundStyle(Hunt.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            .padding(14)
            .sticker(Hunt.paper, radius: 20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Code to get the game from the App Store")
        }
    }

    /// The QR code in ink on white — dark on light, as phone cameras expect.
    static func code(for text: String) -> UIImage? {
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data(text.utf8)
        qr.correctionLevel = "M"
        let colour = CIFilter.falseColor()
        colour.inputImage = qr.outputImage
        colour.color0 = CIColor(red: 0.102, green: 0.043, blue: 0.231)
        colour.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let output = colour.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
