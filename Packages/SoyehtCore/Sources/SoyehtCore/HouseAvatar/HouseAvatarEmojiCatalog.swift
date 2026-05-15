import Foundation

/// Curated 512-emoji catalog for house avatar derivation (research R4).
///
/// Selection criteria (Unicode 12, stable across all Apple platforms):
/// - No skin-tone variants (no Fitzpatrick modifiers U+1F3FB..1F3FF)
/// - No country flags (geopolitically sensitive)
/// - No person/profession/activity emojis (avoids unintended associations)
/// - No violent emojis; no ZWJ sequences
/// - Visually distinct; renders consistently on iOS 16+ / macOS 13+
/// - Categories: animals, plants/nature, food/drink, objects, symbols, geometric,
///               transport, buildings
///
/// **Invariant**: NEVER reorder, remove, or replace entries already shipped.
/// `HouseAvatarDerivation.derive(hhPub:)` addresses this array by index;
/// any mutation changes the avatar for every existing house (FR-046).
/// To extend in a future spec: append to the end and update the modulus.
public enum HouseAvatarEmojiCatalog {
    /// Returns the emoji at `index`. `index` must be in 0..<count.
    public static func emoji(at index: Int) -> Character { catalog[index] }

    /// Total catalog size — always 512.
    public static let count: Int = 512

    // swiftformat:disable all
    static let catalog: [Character] = [
        // MARK: Animals (0–103)
        // 0–7 domestic pets
        "🐶","🐱","🐭","🐹","🐰","🐼","🐨","🐯",
        // 8–15 big cats / ungulates
        "🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦",
        // 16–23 birds
        "🐤","🦆","🦅","🦉","🦇","🦚","🦜","🦢",
        // 24–31 more birds / equines
        "🦩","🕊","🐓","🦤","🐺","🐗","🐴","🦄",
        // 32–39 wild canines / rodents
        "🦊","🐻","🦝","🦡","🦔","🐿","🐇","🐁",
        // 40–47 hoofed mammals
        "🐀","🦌","🐐","🐑","🦙","🐪","🐫","🦒",
        // 48–55 insects
        "🐝","🐛","🦋","🐌","🐞","🐜","🕷","🦂",
        // 56–63 reptiles / mythical
        "🐢","🐍","🦎","🐊","🐉","🐲","🦕","🦖",
        // 64–71 cephalopods / crustaceans
        "🐙","🦑","🦐","🦀","🦞","🐡","🐠","🐟",
        // 72–79 sea mammals / shells
        "🐬","🐳","🐋","🦈","🦭","🐚","🪸","🪼",
        // 80–87 farm animals
        "🐃","🐂","🐄","🐎","🐖","🐏","🐕","🐈",
        // 88–95 exotic large mammals
        "🦬","🦧","🦣","🦫","🦦","🦘","🐘","🦛",
        // 96–103 more insects / microbes
        "🦏","🪲","🪳","🦟","🦗","🪰","🦠","🪱",

        // MARK: Plants & Nature (104–159)
        // 104–111 trees / terrain
        "🌵","🌲","🌳","🌴","🎍","🎋","🪵","🏔",
        // 112–119 small plants
        "🌱","🌿","🍀","🍃","🍂","🍁","🌾","🍄",
        // 120–127 flowers
        "🌺","🌸","🌼","🌻","🌹","🥀","🌷","💐",
        // 128–135 more flowers / water / fire
        "🪷","🪻","🌰","🥜","🪴","🌊","💧","🔥",
        // 136–143 moon phases
        "🌞","🌝","🌛","🌜","🌚","🌕","🌖","🌗",
        // 144–151 more moon / stars
        "🌘","🌑","🌒","🌓","🌔","🌙","🌟","⭐",
        // 152–159 sky / weather effects
        "💫","✨","🌠","☄","🌈","❄","⛄","🌁",

        // MARK: Food & Drink (160–255)
        // 160–167 citrus / tropical fruit
        "🍇","🍈","🍉","🍊","🍋","🍌","🍍","🥭",
        // 168–175 stone fruit / berries
        "🍎","🍏","🍐","🍑","🍒","🍓","🫐","🥝",
        // 176–183 more fruit / avocado
        "🍅","🥥","🥑","🫒","🍆","🥔","🥕","🌽",
        // 184–191 vegetables / salad
        "🌶","🥒","🥬","🥦","🧄","🧅","🫑","🥗",
        // 192–199 bread / breakfast
        "🍞","🥐","🥖","🥨","🧀","🥚","🍳","🥞",
        // 200–207 meat / fast food
        "🥓","🍗","🍖","🌭","🍔","🍟","🍕","🌮",
        // 208–215 wrapped / stewed
        "🌯","🥙","🍲","🍛","🍜","🍝","🍠","🍱",
        // 216–223 japanese bites
        "🍣","🍤","🍥","🍢","🍡","🥟","🥠","🥡",
        // 224–231 frozen / baked sweets
        "🍦","🍧","🍨","🍩","🍪","🎂","🍰","🧁",
        // 232–239 chocolate / candy / savory
        "🍫","🍬","🍭","🍮","🍯","🧆","🫙","🥘",
        // 240–247 hot / fermented drinks
        "🍵","☕","🍶","🍺","🍻","🍷","🍸","🍹",
        // 248–255 cold / sparkling drinks
        "🧃","🥤","🧋","🧊","🍾","🫗","🥂","🫖",

        // MARK: Objects (256–367)
        // 256–263 screens / capture
        "📱","💻","⌨","🖥","📺","📻","📷","📸",
        // 264–271 video / gaming / broadcast
        "📹","🎥","🎞","🎮","🕹","🎛","📡","🛰",
        // 272–279 hand tools
        "🔧","🔩","⚙","🔨","⚒","🛠","⛏","🔬",
        // 280–287 light / magnets / locks
        "🔭","💡","🔦","🕯","🪔","🧲","🔐","🔑",
        // 288–295 security / magic
        "🗝","🔒","🔓","🔍","🔎","🪄","🔮","🧿",
        // 296–303 furniture / toys
        "🪑","🛋","🚪","🛏","🪞","🪟","🧸","🎁",
        // 304–311 containers / cleaning
        "📦","🪣","🧹","🧺","🧻","🧼","🫧","🪥",
        // 312–319 hats / eyewear
        "👒","🎩","🧢","👓","🕶","🧣","🧤","🧥",
        // 320–327 bags / writing
        "👜","👝","🎒","💼","📝","✏","🖊","🖋",
        // 328–335 office supplies
        "📌","📍","📎","📏","📐","✂","🗂","📋",
        // 336–343 books / documents
        "📚","📖","📓","📒","📃","📄","📑","📜",
        // 344–351 science / medical
        "⚗","🧪","🧫","🧬","🩺","💊","🩹","🩻",
        // 352–359 musical instruments
        "🎵","🎶","🎸","🎹","🥁","🎷","🎺","🎻",
        // 360–367 more instruments / audio
        "🪕","🎤","🎧","🎙","🪘","🪗","🪈","🎼",

        // MARK: Symbols & Signs (368–431)
        // 368–375 ball sports
        "⚽","🏀","🏈","⚾","🎾","🏐","🏉","🎱",
        // 376–383 paddle / target / games
        "🏓","🏸","🎯","🎳","⛳","🎣","🧩","🎲",
        // 384–391 rides / art / casino
        "🎠","🎡","🎢","🎪","🎭","🎨","🎰","🗿",
        // 392–399 directional arrows
        "↗","↘","↙","↖","↕","↔","↩","↪",
        // 400–407 media control
        "🔄","🔃","🔀","🔁","🔂","⏩","⏪","⏫",
        // 408–415 more media / audio
        "⏬","⏯","▶","⏸","⏹","⏺","🔇","🔔",
        // 416–423 warning / prohibit
        "⚠","🚫","⛔","🔞","💯","❓","❗","‼",
        // 424–431 checks / recycle
        "⁉","✅","❌","☑","✔","♻","🔱","⭕",

        // MARK: Geometric (432–463)
        // 432–439 color squares
        "⬛","⬜","🟥","🟧","🟨","🟩","🟦","🟪",
        // 440–447 color circles
        "🔴","🟠","🟡","🟢","🔵","🟣","⚫","⚪",
        // 448–455 diamonds / small shapes
        "🔲","🔳","🔶","🔷","🔸","🔹","▪","▫",
        // 456–463 misc geometric
        "◾","◽","◼","◻","🟤","💠","🔘","🔆",

        // MARK: Transport (464–495)
        // 464–471 rail / emergency
        "🚂","🚃","🚄","🚅","🚆","🚇","🚌","🚑",
        // 472–479 road vehicles
        "🚒","🚓","🚗","🚙","🚕","🚐","🛻","🚛",
        // 480–487 air / sea
        "✈","🚀","🛸","🛩","🚁","⛵","🚤","🛥",
        // 488–495 more sea / special
        "🛳","⛴","🚢","🪂","🛶","🏎","🏍","🛵",

        // MARK: Buildings & Places (496–511)
        // 496–503 residential / commercial
        "🏠","🏡","🏢","🏣","🏥","🏦","🏨","🏩",
        // 504–511 specialty buildings
        "🏪","🏫","🏬","🏭","🏯","🏰","⛪","🕌",
    ]
    // swiftformat:enable all
}
