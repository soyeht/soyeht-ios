import QuickLook
import SoyehtCore
import UIKit
import WebKit

enum FilePreviewContent {
    case markdown(RemoteFilePreview)
    case text(RemoteFilePreview)
    case quickLook(localURL: URL, mimeType: String)
}

final class FilePreviewViewController: UIViewController {
    private let containerId: String
    private let remotePath: String
    private let content: FilePreviewContent
    private let entry: RemoteDirectoryEntry

    private let contentContainer = UIView()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let saveAsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private let textView: UITextView = {
        if #available(iOS 15.0, *) {
            let view = UITextView(usingTextLayoutManager: true)
            view.isEditable = false
            view.backgroundColor = SoyehtTheme.uiBgPrimary
            view.textColor = SoyehtTheme.uiTextPrimary
            view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
            return view
        } else {
            let view = UITextView()
            view.isEditable = false
            view.backgroundColor = SoyehtTheme.uiBgPrimary
            view.textColor = SoyehtTheme.uiTextPrimary
            view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
            return view
        }
    }()

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.isOpaque = false
        view.scrollView.backgroundColor = SoyehtTheme.uiBgPrimary
        view.accessibilityIdentifier = AccessibilityID.FilePreview.textView
        return view
    }()

    private var quickLookController: QuickLookChildController?

    init(container: String, remotePath: String, content: FilePreviewContent, entry: RemoteDirectoryEntry) {
        self.containerId = container
        self.remotePath = remotePath
        self.content = content
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        title = (remotePath as NSString).lastPathComponent

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.accessibilityIdentifier = AccessibilityID.FilePreview.textView
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Typography.monoUILabelRegular
        statusLabel.textColor = SoyehtTheme.uiTextSecondary
        statusLabel.numberOfLines = 0
        statusLabel.text = summaryText()

        let actions = UIStackView(arrangedSubviews: [saveButton, saveAsButton, shareButton])
        actions.axis = .vertical
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(saveButton, title: "Salvar no iPhone", icon: "square.and.arrow.down")
        configureActionButton(saveAsButton, title: "Salvar em…", icon: "square.and.arrow.down.on.square")
        configureActionButton(shareButton, title: "Compartilhar", icon: "square.and.arrow.up")

        saveButton.accessibilityIdentifier = AccessibilityID.FilePreview.saveButton
        saveAsButton.accessibilityIdentifier = AccessibilityID.FilePreview.downloadButton
        shareButton.accessibilityIdentifier = AccessibilityID.FilePreview.shareButton

        saveButton.addTarget(self, action: #selector(saveToIPhoneTapped), for: .touchUpInside)
        saveAsButton.addTarget(self, action: #selector(saveAsTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        view.addSubview(contentContainer)
        view.addSubview(statusLabel)
        view.addSubview(actions)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),

            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        renderContent()
    }

    private func configureActionButton(_ button: UIButton, title: String, icon: String) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = SoyehtTheme.uiBgKeybar
        configuration.baseForegroundColor = SoyehtTheme.uiTextPrimary
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        button.configuration = configuration
        button.layer.cornerRadius = 0
    }

    private func renderContent() {
        switch content {
        case .markdown(let preview):
            webView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            webView.loadHTMLString(MarkdownHTMLRenderer.render(preview.content), baseURL: nil)
        case .text(let preview):
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.font = Typography.monoUICardRegular
            textView.text = preview.content
            contentContainer.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                textView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        case .quickLook(let localURL, _):
            let controller = QuickLookChildController(localURL: localURL)
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            controller.didMove(toParent: self)
            quickLookController = controller
        }
    }

    private func summaryText() -> String {
        var parts: [String] = []
        switch content {
        case .markdown(let preview), .text(let preview):
            parts.append(preview.mimeType)
            if preview.isTruncated {
                parts.append("preview capped at 512 KB")
            }
        case .quickLook(_, let mimeType):
            parts.append(mimeType)
        }
        if let sizeBytes = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if let modifiedAt = entry.modifiedAt, !modifiedAt.isEmpty {
            parts.append(modifiedAt)
        }
        return parts.joined(separator: " · ")
    }

    @objc private func saveToIPhoneTapped() {
        do {
            _ = try persistentFileURL()
            showToast(message: "Saved")
        } catch {
            showSimpleAlert(title: "Unable to Save", message: error.localizedDescription)
        }
    }

    @objc private func saveAsTapped() {
        do {
            let fileURL = try exportableFileURL()
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            present(picker, animated: true)
        } catch {
            showSimpleAlert(title: "Unable to Save", message: error.localizedDescription)
        }
    }

    @objc private func shareTapped() {
        do {
            let fileURL = try exportableFileURL()
            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = shareButton
            controller.popoverPresentationController?.sourceRect = shareButton.bounds
            present(controller, animated: true)
        } catch {
            showSimpleAlert(title: "Unable to Share", message: error.localizedDescription)
        }
    }

    private func exportableFileURL() throws -> URL {
        switch content {
        case .quickLook(let localURL, _):
            return localURL
        case .markdown(let preview), .text(let preview):
            let tempURL = try DownloadsManager.shared.temporaryPreviewURL(container: containerId, remotePath: remotePath)
            guard let data = preview.content.data(using: .utf8) else {
                throw SoyehtAPIClient.APIError.invalidURL
            }
            // `.atomic` writes to a sibling temp + rename, so a concurrent
            // reader sees either the prior payload or the new one — never a
            // truncated file. Replaces the previous fileExists+removeItem+
            // write dance, which had the same TOCTOU window the rest of
            // this PR closes elsewhere.
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        }
    }

    private func persistentFileURL() throws -> URL {
        switch content {
        case .quickLook(let localURL, _):
            return try DownloadsManager.shared.copyRemoteDownload(
                from: localURL,
                container: containerId,
                remotePath: remotePath
            )
        case .markdown(let preview), .text(let preview):
            guard let data = preview.content.data(using: .utf8) else {
                throw SoyehtAPIClient.APIError.invalidURL
            }
            return try DownloadsManager.shared.writeRemotePreviewData(
                data,
                container: containerId,
                remotePath: remotePath
            )
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class QuickLookChildController: QLPreviewController, QLPreviewControllerDataSource {
    private let previewItem: QuickLookPreviewItem

    init(localURL: URL) {
        self.previewItem = QuickLookPreviewItem(url: localURL)
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewItem
    }
}

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        self.previewItemURL = url
        super.init()
    }
}

private enum MarkdownHTMLRenderer {
    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var htmlLines: [String] = []
        var inUL = false
        var inOL = false

        func closeListsIfNeeded() {
            if inUL {
                htmlLines.append("</ul>")
                inUL = false
            }
            if inOL {
                htmlLines.append("</ol>")
                inOL = false
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeListsIfNeeded()
                continue
            }

            if line.hasPrefix("### ") {
                closeListsIfNeeded()
                htmlLines.append("<h3>\(inlineHTML(String(line.dropFirst(4))))</h3>")
                continue
            }
            if line.hasPrefix("## ") {
                closeListsIfNeeded()
                htmlLines.append("<h2>\(inlineHTML(String(line.dropFirst(3))))</h2>")
                continue
            }
            if line.hasPrefix("# ") {
                closeListsIfNeeded()
                htmlLines.append("<h1>\(inlineHTML(String(line.dropFirst(2))))</h1>")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if inOL {
                    htmlLines.append("</ol>")
                    inOL = false
                }
                if !inUL {
                    htmlLines.append("<ul>")
                    inUL = true
                }
                htmlLines.append("<li>\(inlineHTML(String(line.dropFirst(2))))</li>")
                continue
            }
            if let orderedMatch = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                if inUL {
                    htmlLines.append("</ul>")
                    inUL = false
                }
                if !inOL {
                    htmlLines.append("<ol>")
                    inOL = true
                }
                htmlLines.append("<li>\(inlineHTML(String(line[orderedMatch.upperBound...])))</li>")
                continue
            }

            closeListsIfNeeded()
            htmlLines.append("<p>\(inlineHTML(line))</p>")
        }

        closeListsIfNeeded()

        let bodyFontSize = Int(Typography.uiSize(14).rounded())
        let appPalette = TerminalColorTheme.active.appPalette
        let colorScheme = appPalette.isDark ? "dark" : "light"
        let styles = """
        <style>
        \(Typography.webFontFaceCSS)
        :root { color-scheme: \(colorScheme); }
        body {
          margin: 0;
          padding: 16px;
          background: \(appPalette.backgroundHex);
          color: \(appPalette.textPrimaryHex);
          font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
          font-size: \(bodyFontSize)px;
          line-height: 1.5;
        }
        a { color: \(appPalette.linkHex); }
        h1, h2, h3 { color: \(appPalette.textPrimaryHex); margin: 0 0 12px 0; }
        p, ul, ol { margin: 0 0 12px 0; }
        code {
          background: \(appPalette.cardHex);
          padding: 1px 4px;
        }
        </style>
        """

        return """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            \(styles)
          </head>
          <body>\(htmlLines.joined())</body>
        </html>
        """
    }

    private static func inlineHTML(_ raw: String) -> String {
        var html = escape(raw)

        let replacements: [(String, String)] = [
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"`(.+?)`"#, "<code>$1</code>"),
        ]
        for (pattern, template) in replacements {
            html = html.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }

        html = html.replacingOccurrences(
            of: #"\[(.+?)\]\((https?://[^\s]+)\)"#,
            with: #"<a href="$2">$1</a>"#,
            options: .regularExpression
        )
        return html
    }

    private static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension UIViewController {
    func showToast(message: String) {
        let toast = UILabel()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.text = message
        toast.accessibilityIdentifier = AccessibilityID.FilePreview.toast
        toast.isAccessibilityElement = true
        toast.accessibilityLabel = message
        toast.textColor = SoyehtTheme.uiTextPrimary
        toast.backgroundColor = SoyehtTheme.uiBgPrimary
        toast.textAlignment = .center
        toast.font = Typography.monoUILabelSemi
        toast.numberOfLines = 0
        toast.alpha = 0
        view.addSubview(toast)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        UIView.animate(withDuration: 0.18, animations: {
            toast.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.18, delay: 1.0, options: []) {
                toast.alpha = 0
            } completion: { _ in
                toast.removeFromSuperview()
            }
        })
    }
}
