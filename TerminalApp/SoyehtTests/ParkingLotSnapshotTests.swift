import XCTest
import SwiftUI
import SnapshotTesting
import SoyehtCore
@testable import Soyeht

/// T104 — Parking-lot view snapshot tests in 4 locales: pt-BR, en, ar (RTL), ja (CJK).
final class ParkingLotSnapshotTests: XCTestCase {

    /// The references were recorded on the app's classic palette. A fresh
    /// install now wakes up in Neo Milk (`OnboardingDesignStyleSeeder`), and
    /// the test host is a fresh install on every run — so the theme is pinned
    /// here rather than letting whatever the app seeded decide what these
    /// four locale snapshots are measuring.
    private var restoreThemeID: String?

    override func setUp() {
        super.setUp()
        restoreThemeID = TerminalPreferences.shared.colorTheme
        TerminalThemeStore.shared.setActiveTheme(id: ColorTheme.soyehtDark.rawValue)
    }

    override func tearDown() {
        if let restoreThemeID {
            TerminalThemeStore.shared.setActiveTheme(id: restoreThemeID)
        }
        super.tearDown()
    }

    private func makeParkingLot(locale: Locale, layoutDirection: LayoutDirection = .leftToRight) -> some View {
        LaterParkingLotView(onDismiss: {}, onBack: {})
            .frame(width: 390, height: 844)
            .preferredColorScheme(.dark)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
    }

    private func assertParkingLotSnapshot<V: View>(
        of view: V,
        named name: String,
        line: UInt = #line
    ) {
        assertSnapshot(
            of: view,
            as: .image(
                precision: 0.98,
                perceptualPrecision: 0.98,
                layout: .fixed(width: 390, height: 844)
            ),
            named: name,
            testName: "ParkingLotSnapshots",
            line: line
        )
    }

    func testParkingLot_ptBR() {
        assertParkingLotSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "pt-BR")),
            named: "pt-BR"
        )
    }

    func testParkingLot_en() {
        assertParkingLotSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "en")),
            named: "en"
        )
    }

    func testParkingLot_en_AX5() {
        assertParkingLotSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "en"))
                .dynamicTypeSize(.accessibility5),
            named: "en-AX5"
        )
    }

    func testParkingLot_ar_RTL() {
        assertParkingLotSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "ar"), layoutDirection: .rightToLeft),
            named: "ar-RTL"
        )
    }

    func testParkingLot_ja() {
        assertParkingLotSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "ja")),
            named: "ja"
        )
    }
}
