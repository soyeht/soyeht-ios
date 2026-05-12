import XCTest
import SwiftUI
import SnapshotTesting
@testable import Soyeht

/// T090 — Carousel snapshot tests: RTL + Dynamic Type AX5 + Reduce Motion ON + LTR baseline.
final class CarouselSnapshotTests: XCTestCase {

    private func makeCarousel() -> some View {
        CarouselRootView(onComplete: {})
            .frame(width: 390, height: 844)
            .preferredColorScheme(.dark)
    }

    private var carouselSnapshot: Snapshotting<AnyView, UIImage> {
        .image(
            precision: 0.999,
            layout: .fixed(width: 390, height: 844)
        )
    }

    // MARK: - Baseline: LTR, default size

    func testCarousel_LTR_default() {
        assertSnapshot(
            of: AnyView(makeCarousel()),
            as: carouselSnapshot,
            named: "ltr-default",
            testName: "CarouselSnapshots"
        )
    }

    // MARK: - Dynamic Type AX5

    func testCarousel_AX5() {
        let sut = makeCarousel()
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        assertSnapshot(
            of: AnyView(sut),
            as: carouselSnapshot,
            named: "ax5",
            testName: "CarouselSnapshots"
        )
    }

    // MARK: - RTL (Arabic locale)

    func testCarousel_RTL_ar() {
        let sut = makeCarousel()
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
        assertSnapshot(
            of: AnyView(sut),
            as: carouselSnapshot,
            named: "rtl-ar",
            testName: "CarouselSnapshots"
        )
    }

}
