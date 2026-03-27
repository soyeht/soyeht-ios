import Testing
@testable import SwiftTerm

final class KeyBarConfigurationTests {

    @Test func totalItemCount() {
        #expect(KeyBarConfiguration.items.count == 16)
    }

    @Test func buttonOrderMatchesSpec() {
        let labels = KeyBarConfiguration.items.map(\.label)
        #expect(labels == [
            "S-Tab", "/", nil, "Tab", "Esc", nil,
            "↑", "↓", "←", "→", nil,
            "Ctrl", "Alt", nil,
            "Kill", "Enter"
        ])
    }

    @Test func dividersAtCorrectPositions() {
        let items = KeyBarConfiguration.items
        let dividerIndices = items.indices.filter { items[$0].kind == .divider }
        #expect(dividerIndices == [2, 5, 10, 13])
    }

    // MARK: - Byte sequences

    @Test func shiftTabSendsCorrectSequence() {
        let item = KeyBarConfiguration.items.first { $0.label == "S-Tab" }!
        #expect(item.bytes == [0x1b, 0x5b, 0x5a])
    }

    @Test func slashSendsCorrectByte() {
        let item = KeyBarConfiguration.items.first { $0.label == "/" }!
        #expect(item.bytes == [0x2f])
    }

    @Test func tabSendsCorrectByte() {
        let item = KeyBarConfiguration.items.first { $0.label == "Tab" }!
        #expect(item.bytes == [0x09])
    }

    @Test func escSendsCorrectByte() {
        let item = KeyBarConfiguration.items.first { $0.label == "Esc" }!
        #expect(item.bytes == [0x1b])
    }

    @Test func killSendsCtrlC() {
        let item = KeyBarConfiguration.items.first { $0.label == "Kill" }!
        #expect(item.bytes == [0x03])
    }

    @Test func enterSendsCarriageReturn() {
        let item = KeyBarConfiguration.items.first { $0.label == "Enter" }!
        #expect(item.bytes == [0x0d])
    }

    // MARK: - Item kinds

    @Test func arrowKeysHaveArrowKind() {
        let arrows = KeyBarConfiguration.items.filter { ["↑", "↓", "←", "→"].contains($0.label) }
        #expect(arrows.count == 4)
        for arrow in arrows {
            #expect(arrow.kind == .arrow)
        }
    }

    @Test func modifierButtonsIdentified() {
        let ctrl = KeyBarConfiguration.items.first { $0.label == "Ctrl" }!
        let alt = KeyBarConfiguration.items.first { $0.label == "Alt" }!
        #expect(ctrl.kind == .modifier(.ctrl))
        #expect(alt.kind == .modifier(.alt))
    }

    @Test func sendButtonsHaveSendKind() {
        let sendLabels = ["S-Tab", "/", "Tab", "Esc", "Kill", "Enter"]
        for label in sendLabels {
            let item = KeyBarConfiguration.items.first { $0.label == label }!
            #expect(item.kind == .send, "Expected \(label) to be .send")
        }
    }

    // MARK: - Arrow sequences

    @Test func arrowSequencesNormalMode() {
        #expect(KeyBarConfiguration.arrowSequence(for: "↑", applicationCursor: false) == [0x1b, 0x5b, 0x41])
        #expect(KeyBarConfiguration.arrowSequence(for: "↓", applicationCursor: false) == [0x1b, 0x5b, 0x42])
        #expect(KeyBarConfiguration.arrowSequence(for: "→", applicationCursor: false) == [0x1b, 0x5b, 0x43])
        #expect(KeyBarConfiguration.arrowSequence(for: "←", applicationCursor: false) == [0x1b, 0x5b, 0x44])
    }

    @Test func arrowSequencesAppCursorMode() {
        #expect(KeyBarConfiguration.arrowSequence(for: "↑", applicationCursor: true) == [0x1b, 0x4f, 0x41])
        #expect(KeyBarConfiguration.arrowSequence(for: "↓", applicationCursor: true) == [0x1b, 0x4f, 0x42])
        #expect(KeyBarConfiguration.arrowSequence(for: "→", applicationCursor: true) == [0x1b, 0x4f, 0x43])
        #expect(KeyBarConfiguration.arrowSequence(for: "←", applicationCursor: true) == [0x1b, 0x4f, 0x44])
    }

    @Test func arrowSequenceUnknownLabelReturnsEmpty() {
        #expect(KeyBarConfiguration.arrowSequence(for: "X", applicationCursor: false) == [])
    }
}
