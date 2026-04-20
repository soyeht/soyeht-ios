import Foundation
import Observation

/// Lifecycle handle returned by `ObservationTracker.observe(_:reads:onChange:)`.
/// Callers must retain the token for as long as they want observation to keep
/// re-installing; dropping the last reference (or calling `cancel()`) breaks
/// the chain on the next `onChange` cycle.
///
/// `withObservationTracking` is one-shot: after it fires once, observation is
/// dead until re-installed. `ObservationTracker` re-installs automatically via
/// `DispatchQueue.main.async` inside the onChange closure, but it gates each
/// reinstall on `token.isActive` so cancelled consumers stop cleanly.
@MainActor
final class ObservationToken {
    fileprivate var isActive = true
    func cancel() { isActive = false }
    deinit { isActive = false }
}

@MainActor
enum ObservationTracker {
    /// Install an observation loop on `target`.
    ///
    /// - Parameters:
    ///   - target: the object whose properties to read (weakly captured).
    ///   - reads:  closure that reads every observable property the handler
    ///             consumes. Every property touched here is observed; anything
    ///             not touched will NOT invalidate the tracker. Extract into a
    ///             named `observationReads()` on the target so refactors can't
    ///             drift between the handler and the observed surface.
    ///   - onChange: invoked on the main queue after any observed property
    ///               mutates. N synchronous mutations within the same run-loop
    ///               tick coalesce into a single `onChange` (same contract as
    ///               the legacy `NotificationCenter + pendingNotify` pattern).
    @discardableResult
    static func observe<V: AnyObject>(
        _ target: V,
        reads: @escaping @MainActor (V) -> Void,
        onChange: @escaping @MainActor (V) -> Void
    ) -> ObservationToken {
        let token = ObservationToken()
        install(target: target, reads: reads, onChange: onChange, token: token)
        return token
    }

    private static func install<V: AnyObject>(
        target: V,
        reads: @escaping @MainActor (V) -> Void,
        onChange: @escaping @MainActor (V) -> Void,
        token: ObservationToken
    ) {
        guard token.isActive else { return }
        withObservationTracking {
            reads(target)
        } onChange: { [weak target, weak token] in
            // onChange is called synchronously from whatever thread mutated the
            // observable. Dispatching back to main gives us coalescing within a
            // runloop tick and a safe context to both call the handler and
            // reinstall the tracker.
            DispatchQueue.main.async {
                guard let target, let token, token.isActive else { return }
                onChange(target)
                install(target: target, reads: reads, onChange: onChange, token: token)
            }
        }
    }
}
