import SoyehtCore
import UIKit

extension FileBrowserViewController {
    func setupLayout() {
        updatedLabel.font = Typography.monoUILabelMedium
        updatedLabel.textColor = SoyehtTheme.uiTextSecondary
        updatedLabel.textAlignment = .center
        updatedLabel.isHidden = true

        let rootStack = UIStackView(arrangedSubviews: [
            breadcrumbBar,
            sourceChipStrip,
            collectionView,
            updatedLabel,
        ])
        rootStack.axis = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            breadcrumbBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            sourceChipStrip.heightAnchor.constraint(equalToConstant: 42),
            updatedLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        loadingContainer.addSubview(loadingView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor),
        ])

        emptyLabel.text = "No files in this directory"
        emptyLabel.textColor = SoyehtTheme.uiTextSecondary
        emptyLabel.font = Typography.monoUICardMedium
        emptyLabel.textAlignment = .center

        collectionView.backgroundView = loadingContainer
    }

    func configureCallbacks() {
        attachmentRouter.hostController = self
        attachmentRouter.onUploadSuccess = { [weak self] remotePath in
            self?.showToast(message: "Uploaded to \(remotePath)")
        }
        attachmentRouter.onUploadError = { [weak self] error in
            self?.showErrorAlert(title: "Upload Failed", error: error)
        }

        sourceChipStrip.onOptionSelected = { [weak self] option in
            self?.attachmentRouter.route(option)
        }

        breadcrumbBar.onSegmentTapped = { [weak self] segmentPath in
            self?.loadDirectory(path: segmentPath, recordHistory: true)
        }
        breadcrumbBar.onSegmentLongPressed = { [weak self] in
            self?.presentHistorySheet()
        }

        remoteDownloadManager.onProgress = { [weak self] remotePath, progress, speedText in
            guard let self else { return }
            self.downloadStates[remotePath] = FileRowDownloadState(
                phase: .downloading(progress: progress, speedText: speedText),
                opensPreviewOnCompletion: self.downloadStates[remotePath]?.opensPreviewOnCompletion ?? true,
                startedAt: self.downloadStates[remotePath]?.startedAt ?? Date().timeIntervalSinceReferenceDate
            )
            self.updateCollectionAccessibilitySummary()
            self.reloadEntry(path: remotePath)
        }
        remoteDownloadManager.onCompletion = { [weak self] remotePath, localURL in
            guard let self else { return }
            self.handleCompletedDownload(remotePath: remotePath, localURL: localURL)
        }
        remoteDownloadManager.onFailure = { [weak self] remotePath, error in
            guard let self else { return }
            self.deferredPreviewWorkItems.removeValue(forKey: remotePath)?.cancel()
            self.inlineQuickLookDelayPaths.remove(remotePath)
            self.downloadStates[remotePath] = FileRowDownloadState(
                phase: .failed(message: "Download failed"),
                opensPreviewOnCompletion: true,
                startedAt: Date().timeIntervalSinceReferenceDate
            )
            self.updateCollectionAccessibilitySummary()
            self.reloadEntry(path: remotePath)
            self.showToast(message: error.localizedDescription)
        }
    }

    func makeCollectionView() -> UICollectionView {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = SoyehtTheme.uiBgPrimary
        config.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.backgroundColor = SoyehtTheme.uiBgPrimary
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = AccessibilityID.FileBrowser.collection
        collectionView.refreshControl = refreshControl
        return collectionView
    }

    func makeRefreshControl() -> UIRefreshControl {
        let control = UIRefreshControl()
        control.tintColor = SoyehtTheme.uiAccentGreen
        control.accessibilityIdentifier = AccessibilityID.FileBrowser.refreshControl
        control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        return control
    }
}
