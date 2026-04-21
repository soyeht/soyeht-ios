import Foundation

/// Navigation route inside the Claw Store (iOS NavigationStack / macOS
/// NavigationSplitView). Cases carry the model so the current stack entry
/// can be reconstructed after a deep link or state restoration.
public enum ClawRoute: Hashable {
    case store
    case detail(Claw)
    case setup(Claw)
}
