import Foundation
import RelayStreamGuestFFI

@main
struct RelayStreamGuestFFISmoke {
    static func main() throws {
        do {
            _ = try relayStreamRendezvousHelloBytes(offerCbor: Data())
            throw SmokeFailure("empty offer unexpectedly decoded")
        } catch RelayStreamGuestError.Offer {
            print("RelayStreamGuestFFISmoke: linked")
        } catch {
            throw error
        }
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
