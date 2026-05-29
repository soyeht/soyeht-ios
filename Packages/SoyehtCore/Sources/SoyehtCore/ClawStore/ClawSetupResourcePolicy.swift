import Foundation

public enum ClawPerformanceProfile: String, CaseIterable, Codable, Equatable, Sendable {
    case efficient
    case standard
    case high
    case custom
}

public struct ClawResourceSelection: Equatable, Sendable {
    public let cpuCores: Int
    public let ramMB: Int
    public let diskGB: Int
    public let isDiskManagedByServer: Bool

    public init(cpuCores: Int, ramMB: Int, diskGB: Int, isDiskManagedByServer: Bool) {
        self.cpuCores = cpuCores
        self.ramMB = ramMB
        self.diskGB = diskGB
        self.isDiskManagedByServer = isDiskManagedByServer
    }
}

public enum ClawSetupResourcePolicy {
    public static func selection(
        for profile: ClawPerformanceProfile,
        options: ResourceOptions?,
        serverType: String
    ) -> ClawResourceSelection {
        guard let options else {
            return fallbackSelection(for: profile, serverType: serverType)
        }

        let diskManaged = isDiskManaged(options: options, serverType: serverType)
        let raw: ClawResourceSelection
        switch profile {
        case .efficient:
            raw = ClawResourceSelection(
                cpuCores: min(options.cpuCores.default, max(options.cpuCores.min, options.cpuCores.default / 2)),
                ramMB: min(options.ramMb.default, max(options.ramMb.min, roundedDown(options.ramMb.default / 2, step: 1024))),
                diskGB: min(options.diskGb.default, max(options.diskGb.min, roundedDown(options.diskGb.default / 2, step: 5))),
                isDiskManagedByServer: diskManaged
            )
        case .standard, .custom:
            raw = ClawResourceSelection(
                cpuCores: options.cpuCores.default,
                ramMB: options.ramMb.default,
                diskGB: options.diskGb.default,
                isDiskManagedByServer: diskManaged
            )
        case .high:
            raw = ClawResourceSelection(
                cpuCores: options.cpuCores.default * 2,
                ramMB: options.ramMb.default * 2,
                diskGB: options.diskGb.default * 2,
                isDiskManagedByServer: diskManaged
            )
        }

        return clamped(raw, options: options, serverType: serverType)
    }

    public static func fallbackSelection(
        for profile: ClawPerformanceProfile,
        serverType: String
    ) -> ClawResourceSelection {
        let diskManaged = isDiskManaged(options: nil, serverType: serverType)
        switch profile {
        case .efficient:
            return ClawResourceSelection(cpuCores: 1, ramMB: 1024, diskGB: 10, isDiskManagedByServer: diskManaged)
        case .standard, .custom:
            return ClawResourceSelection(cpuCores: 2, ramMB: 2048, diskGB: 10, isDiskManagedByServer: diskManaged)
        case .high:
            return ClawResourceSelection(cpuCores: 4, ramMB: 4096, diskGB: 20, isDiskManagedByServer: diskManaged)
        }
    }

    public static func clamped(
        _ selection: ClawResourceSelection,
        options: ResourceOptions?,
        serverType: String
    ) -> ClawResourceSelection {
        guard let options else {
            return ClawResourceSelection(
                cpuCores: max(1, selection.cpuCores),
                ramMB: max(512, selection.ramMB),
                diskGB: max(1, selection.diskGB),
                isDiskManagedByServer: isDiskManaged(options: nil, serverType: serverType)
            )
        }

        return ClawResourceSelection(
            cpuCores: clamp(selection.cpuCores, min: options.cpuCores.min, max: options.cpuCores.max),
            ramMB: clamp(selection.ramMB, min: options.ramMb.min, max: options.ramMb.max),
            diskGB: clamp(selection.diskGB, min: options.diskGb.min, max: options.diskGb.max),
            isDiskManagedByServer: isDiskManaged(options: options, serverType: serverType)
        )
    }

    public static func isDiskManaged(options: ResourceOptions?, serverType: String) -> Bool {
        if options?.diskGb.disabled == true {
            return true
        }
        return serverType.lowercased() == "macos"
    }

    public static func requestDiskGB(for selection: ClawResourceSelection) -> Int? {
        selection.isDiskManagedByServer ? nil : selection.diskGB
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(value, max))
    }

    private static func roundedDown(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return Swift.max(step, (value / step) * step)
    }
}
