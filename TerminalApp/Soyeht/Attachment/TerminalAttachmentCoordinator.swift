import UIKit
import SwiftTerm

final class TerminalAttachmentCoordinator: NSObject {
    weak var hostController: TerminalHostViewController? {
        didSet { sourceRouter.hostController = hostController }
    }

    weak var terminalView: TerminalView?

    var container: String? {
        didSet { sourceRouter.container = container }
    }

    var sessionName: String? {
        didSet { sourceRouter.sessionName = sessionName }
    }

    private let sourceRouter = AttachmentSourceRouter()
    private var attachmentPanel: AttachmentPickerView?

    override init() {
        super.init()
        sourceRouter.onUploadError = { error in
            print("[attachment] upload flow failed: \(error.localizedDescription)")
        }
    }

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

    private func handleOption(_ option: AttachmentOption) {
        dismissPicker()
        sourceRouter.route(option)
    }
}

enum AttachmentKind: String {
    case media
    case document
    case file
    case location
}
