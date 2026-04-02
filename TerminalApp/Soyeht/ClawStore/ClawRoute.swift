import Foundation

// MARK: - Claw Navigation Route

enum ClawRoute: Hashable {
    case store
    case detail(Claw)
    case setup(Claw)
}
