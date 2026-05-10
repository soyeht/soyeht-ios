import XCTest
import SwiftUI
import SnapshotTesting
@testable import Soyeht

/// T104 — Parking-lot view snapshot tests in 4 locales: pt-BR, en, ar (RTL), ja (CJK).
final class ParkingLotSnapshotTests: XCTestCase {

    private func makeParkingLot(locale: Locale, layoutDirection: LayoutDirection = .leftToRight) -> some View {
        LaterParkingLotView(onDismiss: {})
            .frame(width: 390, height: 844)
            .preferredColorScheme(.dark)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
    }

    func testParkingLot_ptBR() {
        assertSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "pt-BR")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "pt-BR",
            testName: "ParkingLotSnapshots"
        )
    }

    func testParkingLot_en() {
        assertSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "en")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "en",
            testName: "ParkingLotSnapshots"
        )
    }

    func testParkingLot_ar_RTL() {
        assertSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "ar"), layoutDirection: .rightToLeft),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "ar-RTL",
            testName: "ParkingLotSnapshots"
        )
    }

    func testParkingLot_ja() {
        assertSnapshot(
            of: makeParkingLot(locale: Locale(identifier: "ja")),
            as: .image(layout: .fixed(width: 390, height: 844)),
            named: "ja",
            testName: "ParkingLotSnapshots"
        )
    }
}
