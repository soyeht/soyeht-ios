import Foundation
import Testing
@testable import SoyehtCore

struct EngineBinaryStagingTests {
    @Test func bundledReceiptIsASealedResourceOutsideNestedCode() {
        let bundle = URL(fileURLWithPath: "/fixture/Sample.app")
        let receipt = EmbeddedEngineHelpers.artifactReceiptURL(inBundle: bundle)
        #expect(receipt.path.hasPrefix(bundle.appendingPathComponent("Contents/Resources").path + "/"))
        #expect(receipt.lastPathComponent == EmbeddedEngineHelpers.artifactReceiptName)
    }

    @Test func firstInstallationAndReplacementPreserveTheOpenedImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("helper")
        try Data("first image".utf8).write(to: source)
        try EngineBinaryStaging.stage(source: source, destination: destination)
        let old = try FileHandle(forReadingFrom: destination)
        defer { try? old.close() }
        try Data("second image".utf8).write(to: source)
        try EngineBinaryStaging.stage(source: source, destination: destination)
        #expect(try old.readToEnd() == Data("first image".utf8))
        #expect(try Data(contentsOf: destination) == Data("second image".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["helper", "source"])
    }

    @Test func failedPublicationPreservesTheDestinationAndRemovesStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("occupied")
        try Data("candidate".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let retained = destination.appendingPathComponent("keep")
        try Data("existing".utf8).write(to: retained)
        #expect(throws: (any Error).self) { try EngineBinaryStaging.stage(source: source, destination: destination) }
        #expect(try Data(contentsOf: retained) == Data("existing".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["occupied", "source"])
    }
}
