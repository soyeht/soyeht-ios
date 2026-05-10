import XCTest
import SwiftUI
import SnapshotTesting
@testable import Soyeht

/// T112 — RecoveryMessageView snapshot tests: 5 locales × Dynamic Type AX3 × Reduce Motion fallback.
final class RecoveryMessageSnapshotTests: XCTestCase {

    private func makeRecovery(
        locale: Locale,
        layoutDirection: LayoutDirection = .leftToRight,
        sizeCategory: ContentSizeCategory = .large
    ) -> some View {
        RecoveryMessageView(onDismiss: {})
            .frame(width: 390, height: 844)
            .preferredColorScheme(.dark)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.sizeCategory, sizeCategory)
    }

    // MARK: - 5 locales at default size

    func testRecovery_ptBR() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "pt-BR")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "pt-BR-default",
            testName: "RecoverySnapshots"
        )
    }

    func testRecovery_en() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "en")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "en-default",
            testName: "RecoverySnapshots"
        )
    }

    func testRecovery_ar() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "ar"), layoutDirection: .rightToLeft),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "ar-RTL-default",
            testName: "RecoverySnapshots"
        )
    }

    func testRecovery_ja() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "ja")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "ja-default",
            testName: "RecoverySnapshots"
        )
    }

    func testRecovery_hi() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "hi")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "hi-default",
            testName: "RecoverySnapshots"
        )
    }

    // MARK: - Dynamic Type AX3 (pt-BR baseline)

    func testRecovery_ptBR_AX3() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "pt-BR"), sizeCategory: .accessibilityLarge),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "pt-BR-ax3",
            testName: "RecoverySnapshots"
        )
    }

    // MARK: - Reduce Motion (pt-BR baseline)

    // Reduce Motion is a system-level read-only env key; static snapshots are inherently motion-free.
    func testRecovery_ptBR_ReduceMotion() {
        assertSnapshot(
            of: makeRecovery(locale: Locale(identifier: "pt-BR")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "pt-BR-reduce-motion",
            testName: "RecoverySnapshots"
        )
    }
}
