import UIKit

// The floating scrollback panel container.
//
// Opaque background matching the terminal theme so the panel's top edge
// meets the tabs row / nav chrome without a translucent seam. Square corners —
// this app intentionally avoids rounded chrome.
final class ScrollbackPanelView: UIView {

    let handleView = ScrollbackDragHandleView()
    let collectionView: UICollectionView

    private let background = UIView()

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setupViews()
        applyAppearance()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeOrAccessibilityChanged),
            name: .soyehtColorThemeChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("ScrollbackPanelView does not support coder init") }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = true

        background.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        handleView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(collectionView)
        addSubview(handleView)

        collectionView.register(ScrollbackLineCell.self, forCellWithReuseIdentifier: ScrollbackLineCell.reuseID)
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = true
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: handleView.topAnchor),

            handleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            handleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            handleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            handleView.heightAnchor.constraint(equalToConstant: ScrollbackDragHandleView.height)
        ])

        isAccessibilityElement = false
        accessibilityElementsHidden = false
        collectionView.accessibilityLabel = "Scrollback history"
    }

    // MARK: - Appearance

    @objc private func themeOrAccessibilityChanged() {
        applyAppearance()
    }

    private func applyAppearance() {
        background.backgroundColor = UIColor(hex: ColorTheme.active.backgroundHex) ?? .black
    }

    // MARK: - Hit testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === background { return nil }
        return hit
    }
}
