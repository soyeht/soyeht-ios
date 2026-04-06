import UIKit
import PhotosUI
import CoreLocation
import UniformTypeIdentifiers
import SwiftTerm

final class TerminalAttachmentCoordinator: NSObject {
    weak var hostController: TerminalHostViewController?
    weak var terminalView: TerminalView?

    var container: String?
    var sessionName: String?

    private var attachmentPanel: AttachmentPickerView?
    private var locationManager: CLLocationManager?
    private var uploadTask: Task<Void, Never>?
    private var lastDocumentOption: AttachmentOption = .document

    // MARK: - Toggle Picker

    func togglePicker() {
        if attachmentPanel != nil {
            dismissPicker()
        } else {
            showPicker()
        }
    }

    func dismissPicker() {
        attachmentPanel = nil
        terminalView?.inputView = nil
        terminalView?.reloadInputViews()
    }

    private func showPicker() {
        let panel = AttachmentPickerView()
        panel.onOptionSelected = { [weak self] option in
            self?.handleOption(option)
        }
        attachmentPanel = panel
        terminalView?.inputView = panel
        terminalView?.reloadInputViews()
    }

    // MARK: - Option Routing

    private func handleOption(_ option: AttachmentOption) {
        dismissPicker()

        switch option {
        case .photos:    handlePhotos()
        case .camera:    handleCamera()
        case .location:  handleLocation()
        case .document:  handleDocument()
        case .files:     handleFiles()
        }
    }

    // MARK: - Photos (PHPicker)

    private func handlePhotos() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 10
        config.filter = .any(of: [.images, .videos])

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        hostController?.present(picker, animated: true)
    }

    // MARK: - Camera

    private func handleCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let alert = UIAlertController(
                title: "Camera Unavailable",
                message: "Camera is not available on this device.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            hostController?.present(alert, animated: true)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        hostController?.present(picker, animated: true)
    }

    // MARK: - Location

    private func handleLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        self.locationManager = manager

        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            showLocationDeniedAlert()
            locationManager = nil
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        @unknown default:
            locationManager = nil
        }
    }

    private func showLocationDeniedAlert() {
        let alert = UIAlertController(
            title: "Location Access Denied",
            message: "Enable location access in Settings to share your position.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        hostController?.present(alert, animated: true)
    }

    // MARK: - Document

    private func handleDocument() {
        lastDocumentOption = .document
        let types: [UTType] = [.pdf, .plainText, .rtf, .spreadsheet]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        hostController?.present(picker, animated: true)
    }

    // MARK: - Files (any)

    private func handleFiles() {
        lastDocumentOption = .files
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        hostController?.present(picker, animated: true)
    }

    // MARK: - Upload

    private func uploadFile(_ localURL: URL, kind: AttachmentKind, filename: String) {
        print("[attachment] uploadFile called: container=\(container ?? "nil") session=\(sessionName ?? "nil") file=\(filename)")
        guard let container, let sessionName else {
            print("[attachment] upload skipped: missing container or session")
            return
        }
        uploadTask = Task {
            do {
                let result = try await SoyehtAPIClient.shared.uploadAttachment(
                    container: container,
                    session: sessionName,
                    kind: kind,
                    localFileURL: localURL,
                    filename: filename
                )
                await MainActor.run {
                    showUploadSuccess(result.remotePath)
                }
            } catch {
                await MainActor.run {
                    showUploadError(error)
                }
            }
        }
    }

    private func showUploadSuccess(_ remotePath: String) {
        let alert = UIAlertController(
            title: "Upload Complete",
            message: remotePath,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        hostController?.present(alert, animated: true)
    }

    private func showUploadError(_ error: Error) {
        let alert = UIAlertController(
            title: "Upload Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        hostController?.present(alert, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension TerminalAttachmentCoordinator: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        for result in results {
            let provider = result.itemProvider

            // Try loading as file representation to get the temp file
            let uti: String
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                uti = UTType.movie.identifier
            } else {
                uti = UTType.image.identifier
            }

            provider.loadFileRepresentation(forTypeIdentifier: uti) { [weak self] url, error in
                guard let url else {
                    print("[attachment] loadFileRepresentation failed: \(error?.localizedDescription ?? "nil url")")
                    return
                }
                // Copy INSIDE the completion handler — the temp URL is invalidated on return
                do {
                    let saved = try DownloadsManager.shared.copyIntoDownloads(
                        from: url, preferredFilename: url.lastPathComponent, option: .photos
                    )
                    print("[attachment] saved locally: \(saved.lastPathComponent)")
                    DispatchQueue.main.async {
                        self?.uploadFile(saved, kind: .media, filename: saved.lastPathComponent)
                    }
                } catch {
                    print("[attachment] copy failed: \(error)")
                }
            }
        }
    }
}

// MARK: - UIImagePickerControllerDelegate

extension TerminalAttachmentCoordinator: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)

        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else { return }

        let filename = DownloadsManager.shared.uniqueFilename(base: "photo", ext: "jpg")
        do {
            let saved = try DownloadsManager.shared.saveData(data, filename: filename, option: .camera)
            uploadFile(saved, kind: .media, filename: saved.lastPathComponent)
        } catch {
            // Save failed — silently skip for MVP
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

// MARK: - UIDocumentPickerDelegate

extension TerminalAttachmentCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // Determine kind based on UTType
        let kind: AttachmentKind
        if let type = UTType(filenameExtension: url.pathExtension) {
            if [UTType.pdf, .plainText, .rtf, .spreadsheet].contains(where: { type.conforms(to: $0) }) {
                kind = .document
            } else {
                kind = .file
            }
        } else {
            kind = .file
        }

        do {
            let saved = try DownloadsManager.shared.copyIntoDownloads(
                from: url, preferredFilename: url.lastPathComponent, option: lastDocumentOption
            )
            uploadFile(saved, kind: kind, filename: saved.lastPathComponent)
        } catch {
            // Copy failed — silently skip for MVP
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension TerminalAttachmentCoordinator: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            showLocationDeniedAlert()
            locationManager = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationManager = nil

        do {
            let saved = try DownloadsManager.shared.save(location: location)
            uploadFile(saved, kind: .location, filename: saved.lastPathComponent)
        } catch {
            // Save failed
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationManager = nil
    }
}

// MARK: - AttachmentKind

enum AttachmentKind: String {
    case media
    case document
    case file
    case location
}
