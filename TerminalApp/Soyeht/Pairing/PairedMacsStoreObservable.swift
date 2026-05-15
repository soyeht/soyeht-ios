import Foundation
import Combine

/// SwiftUI adapter for `PairedMacsStore`. The underlying store uses a
/// closure-based `onChange` callback (not Combine), so this object bridges
/// that to `@Published` for `@ObservedObject` consumers.
@MainActor
final class PairedMacsStoreObservable: ObservableObject {
    static let shared = PairedMacsStoreObservable()

    @Published private(set) var macs: [PairedMac] = []

    private var previousCallback: (() -> Void)?

    private init() {
        self.macs = PairedMacsStore.shared.macs
        // Compose with any previous handler so this wrapper does not displace
        // other observers (e.g. tests) the store may already have.
        self.previousCallback = PairedMacsStore.shared.onChange
        PairedMacsStore.shared.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.previousCallback?()
            }
        }
    }

    func refresh() {
        macs = PairedMacsStore.shared.macs
    }
}
