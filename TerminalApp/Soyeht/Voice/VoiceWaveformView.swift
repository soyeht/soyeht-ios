import UIKit

final class VoiceWaveformView: UIView {
    private static let barCount = 30
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3

    private var barLayers: [CALayer] = []
    private var levels: [Float] = Array(repeating: 0, count: barCount)
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBars()
    }

    // MARK: - Setup

    private func setupBars() {
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = SoyehtTheme.uiEnterGreen.cgColor
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let totalWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        var x = (bounds.width - totalWidth) / 2
        for bar in barLayers {
            bar.frame = CGRect(x: x, y: bounds.midY - 1, width: Self.barWidth, height: 2)
            x += Self.barWidth + Self.barGap
        }
    }

    // MARK: - Public

    func updateLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        updateBarHeights()
    }

    func startAnimating() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        // Animate bars to zero
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for bar in barLayers {
            bar.frame = CGRect(x: bar.frame.minX, y: bounds.midY - 1, width: Self.barWidth, height: 2)
        }
        CATransaction.commit()
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
        updateBarHeights()
    }

    // MARK: - Private

    @objc private func tick() {
        updateBarHeights()
    }

    private func updateBarHeights() {
        let maxHeight = bounds.height * 0.9
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let level = CGFloat(levels[i])
            let height = max(2, level * maxHeight)
            let y = bounds.midY - height / 2
            bar.frame = CGRect(x: bar.frame.minX, y: y, width: Self.barWidth, height: height)
            bar.opacity = Float(0.3 + level * 0.7)
        }
        CATransaction.commit()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 60)
    }
}
