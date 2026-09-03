import Foundation

/// The six words, derived one way.
///
/// A pairing link comes in two shapes — the engine's `soyeht://household/pair-device`
/// and the Mac's own `soyeht://household/device-pairing` — and both carry the
/// same two ingredients the code is made of: the household public key and a
/// nonce. Five places used to open one shape or the other and re-implement the
/// derivation around it, which is how the Mac and the iPhone could end up
/// showing different words for the same house.
public enum PairingCodePresentation {
    /// Six, as the fingerprint derives them. Truncating for display was
    /// considered and rejected: the words a person compares must be the words
    /// the engine compares, or a mismatch means nothing.
    public static var wordCount: Int { OperatorFingerprint.wordCount }

    public enum Failure: Error, Equatable {
        /// Neither link shape parsed. The caller has something that is not a
        /// pairing link.
        case unrecognizedLink
        /// A `pair-device` link whose window has closed. The words behind it
        /// are already dead; showing them would send someone to type a code
        /// that cannot match.
        case expired
        case derivationFailed
    }

    /// Derives the words from either link shape.
    ///
    /// `now` is taken rather than read so a caller can test the expiry edge,
    /// and so a view that re-renders does not silently change its own answer.
    public static func words(pairingURL url: URL, now: Date = Date()) throws -> [String] {
        let wordlist: BIP39Wordlist
        do {
            wordlist = try BIP39Wordlist()
        } catch {
            throw Failure.derivationFailed
        }

        if let qr = try? PairDeviceQR(url: url, now: Date.distantPast) {
            // Parsed as an engine link. Its own expiry is the authority, so
            // check it explicitly rather than letting the parse decide: the
            // caller needs to tell "not this shape" apart from "too late".
            guard qr.expiresAt > now else { throw Failure.expired }
            return try derive(publicKey: qr.householdPublicKey, nonce: qr.nonce, wordlist: wordlist)
        }

        if let link = try? HouseholdDevicePairingLink(url: url) {
            // A Mac-minted link carries no expiry: the Mac holds it for as
            // long as the sheet is open and mints a new one next time.
            return try derive(
                publicKey: link.householdPublicKey,
                nonce: link.pairingNonce,
                wordlist: wordlist
            )
        }

        throw Failure.unrecognizedLink
    }

    /// Convenience for the common case of a link that arrives as a string.
    public static func words(pairingURI: String, now: Date = Date()) throws -> [String] {
        guard let url = URL(string: pairingURI) else { throw Failure.unrecognizedLink }
        return try words(pairingURL: url, now: now)
    }

    private static func derive(
        publicKey: Data,
        nonce: Data,
        wordlist: BIP39Wordlist
    ) throws -> [String] {
        let fingerprint: OperatorFingerprint
        do {
            fingerprint = try OperatorFingerprint.derive(
                machinePublicKey: publicKey,
                pairingNonce: nonce,
                wordlist: wordlist
            )
        } catch {
            throw Failure.derivationFailed
        }
        guard fingerprint.words.count == wordCount else { throw Failure.derivationFailed }
        return fingerprint.words
    }
}
