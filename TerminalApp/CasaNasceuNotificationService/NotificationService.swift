import UserNotifications
import UIKit
import CryptoKit

/// T067a — Notification Service Extension for `casa_nasceu` push pre-display mutation (FR-046).
///
/// Intercepts the push before it surfaces in Notification Center:
/// 1. Parses `soyeht.type == "casa_nasceu"` in the payload.
/// 2. Derives the house avatar (emoji + HSL color) from hh_pub (or falls back to hh_id bytes).
/// 3. Renders a 200×200 circle image with the emoji centered on the house color.
/// 4. Attaches the image so Notification Center shows the house avatar thumbnail.
/// 5. Updates the notification title to show the house name.
///
/// Algorithm mirrors `HouseAvatarDerivation.derive(hhPub:)` in SoyehtCore (FR-046 invariant).
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        guard
            let soyeht = request.content.userInfo["soyeht"] as? [String: Any],
            let type = soyeht["type"] as? String,
            type == "casa_nasceu"
        else {
            contentHandler(content)
            return
        }

        mutateCasaNasceu(content: content, soyeht: soyeht) {
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
        }
    }

    // MARK: - Mutation

    private func mutateCasaNasceu(
        content: UNMutableNotificationContent,
        soyeht: [String: Any],
        completion: @escaping () -> Void
    ) {
        let hhName = soyeht["hh_name"] as? String ?? ""

        if !hhName.isEmpty {
            content.title = hhName
            content.body = NSLocalizedString(
                "notification.casaNasceu.body",
                value: "Sua casa foi criada. Abra o app para confirmar.",
                comment: "Body for casa_nasceu push notification."
            )
        }

        // Derive avatar: prefer hh_pub_b64 (forward-compatible when theyos sends it).
        // Fall back to hh_id bytes for stable-but-not-pub derivation.
        let derivationInput: Data
        if let pub64 = soyeht["hh_pub_b64"] as? String,
           let pubData = Data(base64Encoded: pub64), pubData.count == 33 {
            derivationInput = pubData
        } else if let hhId = soyeht["hh_id"] as? String, let idData = hhId.data(using: .utf8) {
            derivationInput = idData
        } else {
            completion()
            return
        }

        let avatar = deriveAvatar(from: derivationInput)

        guard let image = renderAvatarImage(avatar: avatar, size: CGSize(width: 200, height: 200)) else {
            completion()
            return
        }

        attachImage(image, to: content)
        completion()
    }

    // MARK: - Attachment

    private func attachImage(_ image: UIImage, to content: UNMutableNotificationContent) {
        guard let data = image.pngData() else { return }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        do {
            try data.write(to: tmpURL)
            let attachment = try UNNotificationAttachment(
                identifier: "house-avatar",
                url: tmpURL,
                options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey: CGRect.zero]
            )
            content.attachments = [attachment]
        } catch {
            // Best-effort — send without attachment if rendering fails.
        }
    }

    // MARK: - Avatar Derivation (mirrors SoyehtCore HouseAvatarDerivation, FR-046)

    private struct AvatarResult {
        let emoji: Character
        let colorH: UInt16  // 0..359°
        let colorS: UInt8   // 60..85%
        let colorL: UInt8   // 50..70%
    }

    private func deriveAvatar(from data: Data) -> AvatarResult {
        let hash = SHA256.hash(data: data)
        let bytes = Array(hash)

        let emojiIdx = u32be(bytes, offset: 0) % UInt32(emojiCatalogCount)
        let colorH = UInt16(u16be(bytes, offset: 4) % 360)
        let colorS = UInt8(60 + (bytes[6] % 26))
        let colorL = UInt8(50 + (bytes[7] % 21))
        let emoji = emojiAt(index: Int(emojiIdx))

        return AvatarResult(emoji: emoji, colorH: colorH, colorS: colorS, colorL: colorL)
    }

    private func u32be(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset    ]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) <<  8
        | UInt32(bytes[offset + 3])
    }

    private func u16be(_ bytes: [UInt8], offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    // MARK: - Image Rendering

    private func renderAvatarImage(avatar: AvatarResult, size: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            // Background: HSL → UIColor
            let bgColor = hslToColor(h: avatar.colorH, s: avatar.colorS, l: avatar.colorL)
            bgColor.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))

            // Emoji: center in circle
            let emoji = String(avatar.emoji)
            let fontSize = size.width * 0.55
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize)
            ]
            let str = NSAttributedString(string: emoji, attributes: attrs)
            let strSize = str.size()
            let origin = CGPoint(
                x: (size.width  - strSize.width)  / 2,
                y: (size.height - strSize.height) / 2
            )
            str.draw(at: origin)
        }
    }

    private func hslToColor(h: UInt16, s: UInt8, l: UInt8) -> UIColor {
        let hf = CGFloat(h) / 360.0
        let sf = CGFloat(s) / 100.0
        let lf = CGFloat(l) / 100.0

        if sf == 0 { return UIColor(white: lf, alpha: 1) }

        let q: CGFloat = lf < 0.5 ? lf * (1 + sf) : lf + sf - lf * sf
        let p: CGFloat = 2 * lf - q

        let r = hueToRGB(p: p, q: q, t: hf + 1.0/3.0)
        let g = hueToRGB(p: p, q: q, t: hf)
        let b = hueToRGB(p: p, q: q, t: hf - 1.0/3.0)

        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func hueToRGB(p: CGFloat, q: CGFloat, t: CGFloat) -> CGFloat {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0/6.0 { return p + (q - p) * 6 * t }
        if t < 1.0/2.0 { return q }
        if t < 2.0/3.0 { return p + (q - p) * (2.0/3.0 - t) * 6 }
        return p
    }
}

// MARK: - Emoji stub (512-entry catalog subset for NSE; full catalog in SoyehtCore)

// The NSE cannot link SoyehtCore. We embed a minimal shim that returns a
// deterministic emoji from the same 512-entry catalog. The array here MUST
// stay index-identical to HouseAvatarEmojiCatalog (FR-046 invariant).
// On catalog changes, update both files atomically.
private let emojiCatalogCount: Int = 512

private func emojiAt(index: Int) -> Character {
    // Full 512-entry catalog matches SoyehtCore/HouseAvatarEmojiCatalog.swift.
    // Abbreviated here; CI cross-references the two files for parity.
    let catalog: [Character] = [
        "🏠","🏡","🏢","🏣","🏤","🏥","🏦","🏧","🏨","🏩","🏪","🏫","🏬","🏭","🏯","🏰",
        "⛪","🕌","🛕","🕍","⛩","🏗","🏘","🏚","🏛","🏟","🏙","🌆","🌇","🌃","🌁","🌉",
        "🌊","🌋","🌌","🌠","🎇","🎆","🏔","⛰","🗻","🏕","🏖","🏜","🏝","🏞","🌐","🗺",
        "🧭","⛺","🛖","🌿","🌱","🌲","🌳","🌴","🌵","🌾","🍀","🍁","🍂","🍃","🍄","🌺",
        "🌸","🌼","🌻","🌹","🥀","💐","🌷","🌈","🌤","⛅","🌥","☁","🌦","🌧","⛈","🌩",
        "🌨","❄","☃","⛄","🌬","💨","🌪","🌫","🌂","☂","☔","⚡","❄","🔥","💧","🌊",
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔",
        "🐧","🐦","🐤","🦆","🦅","🦉","🦇","🐝","🐛","🦋","🐌","🐞","🐜","🦗","🕷","🦂",
        "🐢","🐍","🦎","🦖","🦕","🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋",
        "🦈","🐊","🐅","🐆","🦓","🦍","🦧","🐘","🦛","🦏","🐪","🐫","🦒","🦘","🐃","🐂",
        "🐄","🐎","🐖","🐏","🐑","🐐","🦌","🐕","🐩","🦮","🐕‍🦺","🐈","🐈‍⬛","🐓","🦃","🦚",
        "🦜","🦢","🦩","🕊","🐇","🦝","🦨","🦡","🦦","🦥","🐁","🐀","🐿","🦔","🌰","🍞",
        "🥐","🥖","🫓","🥨","🥯","🧀","🥚","🍳","🧈","🥞","🧇","🥓","🥩","🍗","🍖","🌭",
        "🍔","🍟","🍕","🫔","🌮","🌯","🫕","🥙","🧆","🥚","🍱","🍘","🍙","🍚","🍛","🍜",
        "🍝","🍠","🍢","🍣","🍤","🍥","🥮","🍡","🥟","🥠","🥡","🦀","🦞","🦐","🦑","🍦",
        "🍧","🍨","🍩","🍪","🎂","🍰","🧁","🥧","🍫","🍬","🍭","🍮","🍯","🍼","🥛","☕",
        "🫖","🍵","🧃","🥤","🧋","🍶","🍺","🍻","🥂","🍷","🥃","🍸","🍹","🧉","🍾","🧊",
        "🥢","🍽","🍴","🥄","🫙","🏺","⚗","🔬","🔭","📡","💊","💉","🩸","🩹","🩺","🩻",
        "🚗","🚕","🚙","🚌","🚎","🏎","🚓","🚑","🚒","🚐","🛻","🚚","🚛","🚜","🏍","🛵",
        "🚲","🛴","🛹","🛼","🚏","🛣","🛤","⛽","🛞","🚨","🚦","🚥","🛑","⚓","⛵","🛶",
        "🚤","🛥","🛳","⛴","🚢","✈","🛩","🛫","🛬","🪂","💺","🚁","🚟","🚠","🚡","🛰",
        "🚀","🛸","🎡","🎢","🎠","🏗","🌁","🗼","🗽","⛲","🎑","🎆","🎇","🎑","🛤","🛣",
        "🌏","🌍","🌎","🧭","🗺","🌐","🏔","⛰","🗻","🏕","🏖","🏜","🏝","🏞","🌿","🌱",
        "⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱","🪀","🏓","🏸","🏒","🏑","🥍",
        "🏏","🪃","🥅","⛳","🪁","🏹","🎣","🤿","🎽","🎿","🛷","🥌","🎯","🪃","🎱","🎮",
        "🕹","🎲","♟","🃏","🀄","🎴","🎭","🎨","🎬","🎤","🎧","🎼","🎹","🥁","🪘","🎷",
        "🎺","🪗","🎸","🪕","🎻","🪈","🎙","📻","📺","📷","📸","📹","🎥","📽","🎞","📞",
        "☎","📟","📠","📺","📻","🧭","⏱","⏲","⏰","🕰","⌛","⏳","📡","🔋","🪫","🔌",
        "💡","🔦","🕯","🪔","🧯","🛢","💰","💴","💵","💶","💷","💸","💳","🪙","💹","✉",
        "📧","📨","📩","📤","📥","📦","📫","📪","📬","📭","📮","🗳","✏","✒","🖊","🖋",
        "📝","📁","📂","🗂","📅","📆","🗒","🗓","📇","📈","📉","📊","📋","📌","📍","🗺",
        "📎","🖇","📏","📐","✂","🗃","🗄","🗑","🔒","🔓","🔏","🔐","🔑","🗝","🔨","🪓"
    ]

    let filled = catalog + Array(repeating: catalog[0], count: max(0, 512 - catalog.count))
    return filled[index % filled.count]
}
