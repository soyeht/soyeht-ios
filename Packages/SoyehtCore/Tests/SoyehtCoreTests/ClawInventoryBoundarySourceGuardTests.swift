import XCTest

final class ClawInventoryBoundarySourceGuardTests: XCTestCase {
    private let inventoryServicePath = "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawInventoryService.swift"
    private let detailViewModelPath = "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDetailViewModel.swift"

    func test_inventoryFetchCallsStayBehindServiceWithExplicitDetailException() throws {
        let files = try productionClawStoreFiles()
        let rules: [(pattern: String, allowedPaths: Set<String>, reason: String)] = [
            (
                "getInstances(",
                [inventoryServicePath],
                "ClawInventoryService owns instance fetches and the deployed-online filter."
            ),
            (
                "getClaws(",
                [inventoryServicePath, detailViewModelPath],
                "ClawInventoryService owns catalog fetches; ClawDetailViewModel is a temporary exception for catalog lagging."
            ),
            (
                "getClawAvailability(",
                [detailViewModelPath],
                "ClawDetailViewModel is the only temporary owner of the dedicated /availability poll."
            ),
        ]

        var violations: [String] = []
        for file in files {
            for rule in rules where !rule.allowedPaths.contains(file.relativePath) {
                for match in file.matches(rule.pattern) {
                    violations.append("\(match) - \(rule.reason)")
                }
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))

        let detail = try sourceFile(relativePath: detailViewModelPath)
        XCTAssertTrue(
            detail.code.contains("getClawAvailability(name:"),
            "The temporary detail exception should stay explicit until the service can preserve dedicated availability polling."
        )
        XCTAssertTrue(
            detail.code.contains("getClaws(target:"),
            "The detail exception may refetch catalog data to merge terminal availability when catalog lags."
        )
        XCTAssertTrue(
            detail.code.contains("preserving availability"),
            "Keep the catalog-lagging reason documented at the temporary exception."
        )
    }

    func test_inventoryConsumersContinueUsingClawInventoryService() throws {
        let storeVM = try sourceFile(
            relativePath: "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawStoreViewModel.swift"
        ).code
        XCTAssertTrue(
            storeVM.contains("private let makeService: @MainActor (ClawMachineTarget) -> ClawInventoryService")
        )
        XCTAssertTrue(storeVM.contains("ClawInventoryService("))
        XCTAssertTrue(storeVM.contains("snapshotCancellable = svc.$snapshot"))
        XCTAssertTrue(storeVM.contains(".sink { [weak self] snapshot in"))

        let provider = try sourceFile(
            relativePath: "TerminalApp/SoyehtMac/ClawStore/InstalledClawsProvider.swift"
        ).code
        XCTAssertTrue(provider.contains("ClawInventoryService(target: target, apiClient: apiClient, autoPoll: false)"))
        XCTAssertTrue(provider.contains("snapshot.deployedOnlineClaws"))

        let drawer = try sourceFile(
            relativePath: "TerminalApp/SoyehtMac/ClawStore/ClawDrawerViewModel.swift"
        ).code
        XCTAssertTrue(drawer.contains("private let makeService: (ClawMachineTarget) -> ClawInventoryService"))
        XCTAssertTrue(drawer.contains("ClawInventoryService("))
        XCTAssertTrue(drawer.contains("makeService(.server(context))"))
        XCTAssertTrue(drawer.contains("snapshotCancellable = svc.$snapshot"))
        XCTAssertTrue(drawer.contains(".sink { [weak self] snapshot in"))
    }

    func test_clawStoreSurfacesBuildViewModelsFromMachineTargetNotLossyApiTarget() throws {
        let files = try appClawStoreSurfaceFiles()
        var violations: [String] = []
        for file in files {
            violations.append(contentsOf: file.lossyViewModelConstructionMatches(
                constructor: "ClawStoreViewModel("
            ))
            violations.append(contentsOf: file.lossyViewModelConstructionMatches(
                constructor: "ClawDetailViewModel("
            ))
        }

        XCTAssertEqual(
            violations,
            [],
            "Claw Store surfaces should pass ClawMachineTarget to view models, not lossy ClawAPITarget:\n"
                + violations.joined(separator: "\n")
        )

        XCTAssertTrue(
            try sourceFile(relativePath: "TerminalApp/Soyeht/ClawStore/ClawStoreView.swift")
                .code
                .contains("ClawStoreViewModel(machineTarget: resolution)")
        )
        XCTAssertTrue(
            try sourceFile(relativePath: "TerminalApp/Soyeht/ClawStore/ClawDetailView.swift")
                .code
                .contains("ClawDetailViewModel(claw: claw, machineTarget: resolution)")
        )
        XCTAssertTrue(
            try sourceFile(relativePath: "TerminalApp/SoyehtMac/ClawStore/MacClawStoreRootView.swift")
                .code
                .contains("ClawStoreViewModel(machineTarget: target)")
        )
        XCTAssertTrue(
            try sourceFile(relativePath: "TerminalApp/SoyehtMac/ClawStore/MacClawDetailView.swift")
                .code
                .contains("ClawDetailViewModel(claw: claw, machineTarget: target)")
        )
    }

    // MARK: - Helpers

    private struct SourceFile {
        let relativePath: String
        let lines: [String]

        var code: String { lines.joined(separator: "\n") }

        func matches(_ pattern: String) -> [String] {
            lines.enumerated().compactMap { offset, line in
                line.contains(pattern) ? "\(relativePath):\(offset + 1): \(pattern)" : nil
            }
        }

        func lossyViewModelConstructionMatches(constructor: String) -> [String] {
            lines.enumerated().compactMap { offset, line in
                guard line.contains(constructor) else { return nil }
                let end = min(offset + 6, lines.count)
                let window = lines[offset..<end].joined(separator: " ")
                return window.contains("target:") ? "\(relativePath):\(offset + 1): \(constructor) target:" : nil
            }
        }
    }

    private func productionClawStoreFiles() throws -> [SourceFile] {
        try swiftFiles(in: [
            "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore",
            "TerminalApp/Soyeht/ClawStore",
            "TerminalApp/SoyehtMac/ClawStore",
        ])
    }

    private func appClawStoreSurfaceFiles() throws -> [SourceFile] {
        try swiftFiles(in: [
            "TerminalApp/Soyeht/ClawStore",
            "TerminalApp/SoyehtMac/ClawStore",
        ])
    }

    private func swiftFiles(in relativeRoots: [String]) throws -> [SourceFile] {
        let root = try workspaceRoot()
        var files: [SourceFile] = []
        for relativeRoot in relativeRoots {
            let rootURL = root.appendingPathComponent(relativeRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Could not enumerate \(relativeRoot)")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = try relativePath(for: url, root: root)
                files.append(SourceFile(relativePath: relativePath, lines: try codeLines(at: url)))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func sourceFile(relativePath: String) throws -> SourceFile {
        let root = try workspaceRoot()
        let url = root.appendingPathComponent(relativePath)
        return SourceFile(relativePath: relativePath, lines: try codeLines(at: url))
    }

    private func codeLines(at url: URL) throws -> [String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        var lines: [String] = []
        var inBlockComment = false

        for line in source.components(separatedBy: .newlines) {
            var code = ""
            var index = line.startIndex
            while index < line.endIndex {
                let rest = line[index...]
                if inBlockComment {
                    if let end = rest.range(of: "*/") {
                        index = end.upperBound
                        inBlockComment = false
                    } else {
                        index = line.endIndex
                    }
                    continue
                }
                if rest.hasPrefix("//") {
                    break
                }
                if rest.hasPrefix("/*") {
                    inBlockComment = true
                    index = line.index(index, offsetBy: 2)
                    continue
                }
                code.append(line[index])
                index = line.index(after: index)
            }
            lines.append(code)
        }
        return lines
    }

    private func relativePath(for url: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw NSError(
                domain: "ClawInventoryBoundarySourceGuardTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(path) is not under \(rootPath)"]
            )
        }
        return String(path.dropFirst(rootPath.count))
    }

    private func workspaceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
