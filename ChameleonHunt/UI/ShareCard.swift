//
//  ShareCard.swift
//  A picture of the round to send to friends or post: the room as the camera sees it,
//  with the chameleon in it, and the show's strip underneath.
//
//  Shared with the paint job showing, it's a puzzle — "Can you spot it?" — that works on
//  anyone's feed, whether or not they have the game. Shared in pink, it's the answer.
//  It's the game's cheapest marketing: every round played can turn into a post.
//

import SwiftUI
import UIKit

@MainActor
enum ShareCard {

    /// Composes the card: the snapshot on top, a violet strip with `headline` in the
    /// game's lettering and `detail` under it.
    static func make(snapshot: UIImage, headline: String, detail: String) -> UIImage {
        let photo = snapshot.size
        let band = max(140, min(photo.width, photo.height) * 0.28)
        let size = CGSize(width: photo.width, height: photo.height + band)
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            snapshot.draw(in: CGRect(origin: .zero, size: photo))

            // The stage: violet, darker at the bottom, with an ink edge along the top.
            let strip = CGRect(x: 0, y: photo.height, width: size.width, height: band)
            let colours = [UIColor(Hunt.stageTop).cgColor, UIColor(Hunt.stageBottom).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                cg.saveGState()
                cg.clip(to: strip)
                cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: strip.minY), end: CGPoint(x: 0, y: strip.maxY), options: [])
                cg.restoreGState()
            }
            UIColor(Hunt.ink).setFill()
            cg.fill(CGRect(x: 0, y: photo.height, width: size.width, height: max(4, band * 0.04)))

            // The mascot on the right, if it's been drawn already (it has, by the home screen).
            let margin = band * 0.16
            var textRight = size.width - margin
            if let mascot = MascotLibrary.shared.image(.init(pose: .standing, view: .hero, size: 720)) {
                let side = band * 0.86
                let frame = CGRect(x: size.width - margin - side, y: strip.midY - side / 2 + band * 0.02, width: side, height: side)
                mascot.draw(in: frame)
                textRight = frame.minX - margin * 0.5
            }

            // The headline: white Lilita with a thick ink outline, like the slams — on one
            // line, shrunk to fit if it's long (as the slams do).
            let title = headline.uppercased()
            let textWidth = max(10, textRight - margin)
            func font(_ size: CGFloat) -> UIFont { UIFont(name: "LilitaOne", size: size) ?? .systemFont(ofSize: size, weight: .black) }
            let natural = NSAttributedString(string: title, attributes: [.font: font(band * 0.3)]).size().width
            let headlineSize = band * 0.3 * max(0.5, min(1, (textWidth - band * 0.06) / max(natural, 1)))
            let lettering = font(headlineSize)
            let origin = CGPoint(x: margin, y: strip.minY + band * 0.16)
            let outline: [NSAttributedString.Key: Any] = [
                .font: lettering, .foregroundColor: UIColor(Hunt.ink),
                .strokeColor: UIColor(Hunt.ink), .strokeWidth: 14,
            ]
            let fill: [NSAttributedString.Key: Any] = [.font: lettering, .foregroundColor: UIColor.white]
            let titleBox = CGRect(origin: origin, size: CGSize(width: textWidth, height: headlineSize * 1.3))
            NSAttributedString(string: title, attributes: outline)
                .draw(with: titleBox.offsetBy(dx: 0, dy: headlineSize * 0.07), options: .usesLineFragmentOrigin, context: nil)
            NSAttributedString(string: title, attributes: outline)
                .draw(with: titleBox, options: .usesLineFragmentOrigin, context: nil)
            NSAttributedString(string: title, attributes: fill)
                .draw(with: titleBox, options: .usesLineFragmentOrigin, context: nil)

            // Under it, what this is (two lines at most).
            let detailSize = band * 0.12
            let body = UIFont.systemFont(ofSize: detailSize, weight: .bold)
            let rounded = body.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: detailSize) } ?? body
            NSAttributedString(string: detail, attributes: [.font: rounded, .foregroundColor: UIColor.white.withAlphaComponent(0.85)])
                .draw(with: CGRect(x: margin, y: titleBox.maxY + band * 0.03, width: textWidth, height: detailSize * 2.7),
                      options: .usesLineFragmentOrigin, context: nil)
        }
    }

    /// What goes with the picture when it's sent.
    static func message(_ text: String) -> String {
        if let link = AppLinks.appStore { return "\(text) \(link.absoluteString)" }
        return text
    }

    /// The system share sheet, over whatever's showing. (Sharing is the one place the
    /// system's own sheet is right: it's where the player's apps and friends are.)
    static func present(image: UIImage, message: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [image, message], applicationActivities: nil)
        // On an iPad it's a popover, and needs somewhere to point: the bottom middle.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 90, width: 1, height: 1)
            popover.permittedArrowDirections = [.down]
        }
        top.present(sheet, animated: true)
    }
}

/// Where the game lives online. Fill these in once they exist; until then anything that
/// would use them leaves them out.
enum AppLinks {
    /// The App Store page: https://apps.apple.com/app/id<the number App Store Connect
    /// shows under App Information → Apple ID>.
    static let appStore: URL? = nil
}
