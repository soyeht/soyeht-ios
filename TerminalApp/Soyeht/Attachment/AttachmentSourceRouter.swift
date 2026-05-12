import UIKit
import PhotosUI
import CoreLocation
import UniformTypeIdentifiers
import SoyehtCore

final class AttachmentSourceRouter: NSObject {
    weak var hostController: UIViewController?

    var container: String?
    var sessionName: String?
    var context: ServerContext?

    var onUploadSuccess: ((String) -> Void)?
    var onUploadError: ((Error) -> Void)?

    private var locationManager: CLLocationManager?
    private var uploadTask: Task<Void, Never>?
    private var lastDocumentOption: AttachmentOption = .document

    func route(_ option: AttachmentOption) {
        switch option {
        case .photos:
            handlePhotos()
        case .camera:
            handleCamera()
        case .location:
            handleLocation()
        case .document:
            handleDocument()
        case .files:
            handleFiles()
        }
    }

    private func handlePhotos() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 10
        config.filter = .any(of: [.images, .videos])

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        hostController?.present(picker, animated: true)
    }

    private func handleCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let alert = UIAlertController(
                title: String(localized: "attachment.alert.cameraUnavailable.title"),
                message: String(localized: "attachment.alert.cameraUnavailable.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.button.ok"), style: .default))
            hostController?.present(alert, animated: true)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        hostController?.present(picker, animated: true)
    }

    private func handleLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager = manager

        switch manager.authorizationStatus {
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
            title: String(localized: "attachment.alert.locationDenied.title"),
            message: String(localized: "attachment.alert.locationDenied.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.button.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.button.settings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        hostController?.present(alert, animated: true)
    }

    private func handleDocument() {
        lastDocumentOption = .document
        let types: [UTType] = [.pdf, .plainText, .rtf, .spreadsheet]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        hostController?.present(picker, animated: true)
    }

    private func handleFiles() {
        lastDocumentOption = .files
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        hostController?.present(picker, animated: true)
    }

    private func uploadFile(_ localURL: URL, kind: AttachmentKind, filename: String) {
        guard let container, let sessionName, let context else { return }
        uploadTask?.cancel()
        uploadTask = Task {
            do {
                let result = try await SoyehtAPIClient.shared.uploadAttachment(
                    container: container,
                    session: sessionName,
                    kind: kind,
                    localFileURL: localURL,
                    filename: filename,
                    context: context
                )
                await MainActor.run {
                    self.onUploadSuccess?(result.remotePath)
                    self.showUploadSuccess(result.remotePath)
                }
            } catch {
                await MainActor.run {
                    self.onUploadError?(error)
                    self.showUploadError(error)
                }
            }
        }
    }

    private func showUploadSuccess(_ remotePath: String) {
        let alert = UIAlertController(
            title: String(localized: "attachment.alert.uploadComplete.title"),
            message: remotePath,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.button.ok"), style: .default))
        hostController?.present(alert, animated: true)
    }

    private func showUploadError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "attachment.alert.uploadFailed.title"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.button.ok"), style: .default))
        hostController?.present(alert, animated: true)
    }
}

extension AttachmentSourceRouter: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        for result in results {
            let provider = result.itemProvider
            let uti: String
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                uti = UTType.movie.identifier
            } else {
                uti = UTType.image.identifier
            }

            provider.loadFileRepresentation(forTypeIdentifier: uti) { [weak self] url, _ in
                guard let self, let url else { return }
                do {
                    let saved = try DownloadsManager.shared.copyIntoDownloads(
                        from: url,
                        preferredFilename: url.lastPathComponent,
                        option: .photos
                    )
                    DispatchQueue.main.async {
                        self.uploadFile(saved, kind: .media, filename: saved.lastPathComponent)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.onUploadError?(error)
                    }
                }
            }
        }
    }
}

extension AttachmentSourceRouter: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)

        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else { return }

        let filename = DownloadsManager.shared.uniqueFilename(base: "photo", ext: "jpg")
        do {
            let saved = try DownloadsManager.shared.saveData(data, filename: filename, option: .camera)
            uploadFile(saved, kind: .media, filename: saved.lastPathComponent)
        } catch {
            onUploadError?(error)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension AttachmentSourceRouter: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

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
                from: url,
                preferredFilename: url.lastPathComponent,
                option: lastDocumentOption
            )
            uploadFile(saved, kind: kind, filename: saved.lastPathComponent)
        } catch {
            onUploadError?(error)
        }
    }
}

extension AttachmentSourceRouter: CLLocationManagerDelegate {
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
            onUploadError?(error)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationManager = nil
        onUploadError?(error)
    }
}
