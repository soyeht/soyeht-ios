import UIKit

final class HapticEngine {
    static let shared = HapticEngine()

    // Pre-allocated generators for zero-latency response
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionGen = UISelectionFeedbackGenerator()
    private let notificationGen = UINotificationFeedbackGenerator()

    private var zoneTypes: [HapticZone: HapticType] = [:]
    private var enabled = true

    private init() {
        reloadConfiguration()
        NotificationCenter.default.addObserver(
            forName: .soyehtHapticSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadConfiguration()
        }
    }

    func reloadConfiguration() {
        let prefs = TerminalPreferences.shared
        enabled = prefs.hapticEnabled
        for zone in HapticZone.allCases {
            zoneTypes[zone] = prefs.hapticType(for: zone)
        }
    }

    func play(for key: String) {
        guard enabled, let zone = HapticZone.zone(for: key) else { return }
        let type = zoneTypes[zone] ?? zone.defaultType
        fire(type)
    }

    func play(zone: HapticZone) {
        guard enabled else { return }
        let type = zoneTypes[zone] ?? zone.defaultType
        fire(type)
    }

    private func fire(_ type: HapticType) {
        switch type {
        case .light:
            impactLight.impactOccurred()
        case .medium:
            impactMedium.impactOccurred()
        case .heavy:
            impactHeavy.impactOccurred()
        case .soft:
            impactSoft.impactOccurred()
        case .rigid:
            impactRigid.impactOccurred()
        case .selectionChanged:
            selectionGen.selectionChanged()
        case .success:
            notificationGen.notificationOccurred(.success)
        case .warning:
            notificationGen.notificationOccurred(.warning)
        case .error:
            notificationGen.notificationOccurred(.error)
        case .disabled:
            break
        }
    }
}
