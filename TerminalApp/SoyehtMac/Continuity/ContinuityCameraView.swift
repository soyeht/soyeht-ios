import SwiftUI
import AVFoundation
import SoyehtCore

/// Mac-side QR scan view for case B fallback (T072a, FR-130).
///
/// Three sequential visual states per FR-130:
/// - `searching`: four pulsing corner brackets with 0.3s staggered offset.
/// - `acquiring`: corners firm + green scan-line sweeping top-to-bottom + subtle green tint.
/// - `confirmed`: freeze + spring checkmark overlay. Cross-fades to SafariOpener within 0.6s.
struct ContinuityCameraView: View {
    let onScanned: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var scanner = ContinuityCameraQRScanner()
    @State private var scanState: ContinuityCameraQRScanner.ScanState = .searching
    @State private var scanLineOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                ZStack {
                    cameraPreviewPlaceholder

                    cornerBrackets

                    if scanState == .acquiring {
                        scanLine
                    }

                    if case .confirmed = scanState {
                        confirmedOverlay
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                Spacer()

                stateLabel
                    .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.state) { _, newState in
            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.3)) {
                scanState = newState
            }
            if case .confirmed(let payload) = newState {
                Task {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 500))
                    onScanned(payload)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                Text(LocalizedStringResource(
                    "continuityCamera.cancel",
                    defaultValue: "Cancel",
                    comment: "Cancel button on Continuity Camera QR scan view."
                ))
                .font(.system(size: 14))
                .foregroundColor(BrandColors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Camera preview (placeholder; real layer via NSViewRepresentable would be needed)

    private var cameraPreviewPlaceholder: some View {
        Rectangle()
            .fill(Color.black.opacity(0.85))
            .overlay(
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.15))
                    .opacity(scanState == .searching ? 1 : 0)
            )
    }

    // MARK: - Corner brackets

    private var cornerBrackets: some View {
        ZStack {
            ForEach(Corner.allCases, id: \.self) { corner in
                CornerBracket(corner: corner, active: scanState != .searching)
                    .opacity(bracketOpacity(for: corner))
                    .animation(bracketAnimation(for: corner), value: scanState)
            }
        }
        .padding(20)
    }

    private func bracketOpacity(for corner: Corner) -> Double {
        switch scanState {
        case .searching: return Double.random(in: 0.4...1.0)
        case .acquiring, .confirmed: return 1.0
        }
    }

    private func bracketAnimation(for corner: Corner) -> Animation? {
        guard scanState == .searching, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.8).delay(corner.delay).repeatForever(autoreverses: true)
    }

    // MARK: - Scan line

    private var scanLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, BrandColors.accentGreen.opacity(0.7), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .offset(y: scanLineOffset)
                .onAppear {
                    guard !reduceMotion else { scanLineOffset = geo.size.height / 2; return }
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: true)) {
                        scanLineOffset = geo.size.height
                    }
                }
        }
    }

    // MARK: - Confirmed overlay

    private var confirmedOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(BrandColors.accentGreen)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    // MARK: - State label

    @ViewBuilder private var stateLabel: some View {
        switch scanState {
        case .searching:
            Text(LocalizedStringResource(
                "continuityCamera.state.searching",
                defaultValue: "Point the camera at the iPhone QR code",
                comment: "ContinuityCameraView searching state label."
            ))
            .font(.system(size: 15))
            .foregroundColor(BrandColors.textMuted)
        case .acquiring:
            Text(LocalizedStringResource(
                "continuityCamera.state.acquiring",
                defaultValue: "Reading code...",
                comment: "ContinuityCameraView acquiring state label."
            ))
            .font(.system(size: 15))
            .foregroundColor(BrandColors.accentGreen)
        case .confirmed:
            Text(LocalizedStringResource(
                "continuityCamera.state.confirmed",
                defaultValue: "Code read!",
                comment: "ContinuityCameraView confirmed state label."
            ))
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(BrandColors.accentGreen)
        }
    }
}

// MARK: - Corner helpers

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var delay: Double {
        switch self {
        case .topLeft: return 0.0
        case .topRight: return 0.1
        case .bottomLeft: return 0.2
        case .bottomRight: return 0.3
        }
    }
}

private struct CornerBracket: View {
    let corner: Corner
    let active: Bool
    private let length: CGFloat = 22
    private let lineWidth: CGFloat = 3

    var body: some View {
        Canvas { ctx, size in
            let color = active ? BrandColors.accentGreen : BrandColors.textMuted
            var path = Path()

            let x: CGFloat = corner == .topLeft || corner == .bottomLeft ? 0 : size.width - length
            let y: CGFloat = corner == .topLeft || corner == .topRight ? 0 : size.height - length
            let dx: CGFloat = corner == .topLeft || corner == .bottomLeft ? length : -length
            let dy: CGFloat = corner == .topLeft || corner == .topRight ? length : -length

            path.move(to: CGPoint(x: x + dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy))

            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
