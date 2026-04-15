import Foundation

/// Compile-time safe accessibility identifiers for Appium/XCUITest automation.
/// Convention: `soyeht.<screen>.<element>[.<qualifier>]`
enum AccessibilityID {

    // MARK: - Instance List

    enum InstanceList {
        static func instanceCard(_ id: String) -> String { "soyeht.instanceList.instanceCard.\(id)" }
        static let list = "soyeht.instanceList.list"
        static let addInstanceButton = "soyeht.instanceList.addInstanceButton"
        static let logoutButton = "soyeht.instanceList.logoutButton"
        static let clawStoreButton = "soyeht.instanceList.clawStoreButton"
        static let serversButton = "soyeht.instanceList.serversButton"
        static let loadingState = "soyeht.instanceList.loadingState"
        static let errorState = "soyeht.instanceList.errorState"
        static let emptyState = "soyeht.instanceList.emptyState"
        static let connectButton = "soyeht.instanceList.connectButton"
        static let sessionSheet = "soyeht.instanceList.sessionSheet"
        static let deployBanner = "soyeht.instanceList.deployBanner"
        static func deployBannerRow(_ id: String) -> String { "soyeht.instanceList.deployBanner.\(id)" }
    }

    // MARK: - Terminal

    enum Terminal {
        static let terminalView = "soyeht.terminal.terminalView"
        static let ctrlButton = "soyeht.terminal.ctrlButton"
        static let altButton = "soyeht.terminal.altButton"
        static let attachmentButton = "soyeht.terminal.attachmentButton"
        static let historyButton = "soyeht.terminal.historyButton"
        static let fileBrowserButton = "soyeht.terminal.fileBrowserButton"
        static let shortcutBar = "soyeht.terminal.shortcutBar"
        static let voiceBar = "soyeht.terminal.voiceBar"
        static let voiceRecordingPanel = "soyeht.terminal.voiceRecordingPanel"
        static let voiceSendButton = "soyeht.terminal.voiceSendButton"
        static let voiceCancelButton = "soyeht.terminal.voiceCancelButton"
        static func shortcut(_ label: String) -> String { "soyeht.terminal.shortcut.\(label)" }
        static func arrow(_ direction: String) -> String { "soyeht.terminal.arrow.\(direction)" }
    }

    // MARK: - WebSocket / Connection

    enum WebSocket {
        static let mirrorModeIndicator = "soyeht.websocket.mirrorModeIndicator"
        static let takeCommandButton = "soyeht.websocket.takeCommandButton"
        static let reconnectingState = "soyeht.websocket.reconnectingState"
        static let connectionStatus = "soyeht.websocket.connectionStatus"
    }

    // MARK: - Tmux Tab Bar

    enum TmuxTabBar {
        static let container = "soyeht.tmuxTabBar.container"
        static let settingsButton = "soyeht.tmuxTabBar.settingsButton"
        static func tab(_ index: Int) -> String { "soyeht.tmuxTabBar.tab.\(index)" }
    }

    // MARK: - Session Sheet

    enum SessionSheet {
        static let sessionsList = "soyeht.sessionSheet.sessionsList"
        static let createWorkspaceButton = "soyeht.sessionSheet.createWorkspaceButton"
        static func windowCard(_ index: Int) -> String { "soyeht.sessionSheet.windowCard.\(index)" }
        static func paneTab(_ paneId: Int) -> String { "soyeht.sessionSheet.paneTab.\(paneId)" }
    }

    // MARK: - Server List

    enum ServerList {
        static let list = "soyeht.serverList.list"
        static let addServerButton = "soyeht.serverList.addServerButton"
        static func serverRow(_ id: String) -> String { "soyeht.serverList.serverRow.\(id)" }
        static func activeBadge(_ id: String) -> String { "soyeht.serverList.activeBadge.\(id)" }
    }

    // MARK: - QR Scanner

    enum QRScanner {
        static let cameraPreview = "soyeht.qrScanner.cameraPreview"
        static let pasteManualButton = "soyeht.qrScanner.pasteManualButton"
        static let tokenTextField = "soyeht.qrScanner.tokenTextField"
        static let connectButton = "soyeht.qrScanner.connectButton"
        static let errorMessage = "soyeht.qrScanner.errorMessage"
    }

    // MARK: - Claw Store

    enum ClawStore {
        static let scrollContent = "soyeht.clawStore.scrollContent"
        static let loadingState = "soyeht.clawStore.loadingState"
        static let errorState = "soyeht.clawStore.errorState"
        static func clawCard(_ name: String) -> String { "soyeht.clawStore.clawCard.\(name)" }
        static func clawCardProgressBar(_ name: String) -> String { "soyeht.clawStore.clawCard.\(name).progressBar" }
        static func clawCardProgressPercent(_ name: String) -> String { "soyeht.clawStore.clawCard.\(name).progressPercent" }
    }

    // MARK: - Claw Detail

    enum ClawDetail {
        static let installButton = "soyeht.clawDetail.installButton"
        static let uninstallButton = "soyeht.clawDetail.uninstallButton"
        static let deployButton = "soyeht.clawDetail.deployButton"
        static let statusLabel = "soyeht.clawDetail.statusLabel"
        static let installingState = "soyeht.clawDetail.installingState"
        static let progressBar = "soyeht.clawDetail.progressBar"
        static let progressPercent = "soyeht.clawDetail.progressPercent"
        static let reasonsBlock = "soyeht.clawDetail.reasonsBlock"
        static func reasonRow(_ index: Int) -> String { "soyeht.clawDetail.reasonRow.\(index)" }
    }

    // MARK: - Settings

    enum Settings {
        static let colorThemeButton = "soyeht.settings.colorThemeButton"
        static let fontSizeButton = "soyeht.settings.fontSizeButton"
        static let cursorStyleButton = "soyeht.settings.cursorStyleButton"
        static let shortcutBarButton = "soyeht.settings.shortcutBarButton"
        static let fontSizeSlider = "soyeht.settings.fontSizeSlider"
        static func themeCard(_ name: String) -> String { "soyeht.settings.themeCard.\(name)" }
        static func cursorStyle(_ id: String) -> String { "soyeht.settings.cursorStyle.\(id)" }
    }

    // MARK: - File Browser

    enum FileBrowser {
        static let container = "soyeht.fileBrowser.container"
        static let collection = "soyeht.fileBrowser.collection"
        static let refreshControl = "soyeht.fileBrowser.refreshControl"
        static let breadcrumbBar = "soyeht.fileBrowser.breadcrumbBar"
        static let historySheet = "soyeht.fileBrowser.historySheet"
        static let sourceChipStrip = "soyeht.fileBrowser.sourceChipStrip"
        static let downloadQueue = "soyeht.fileBrowser.downloadQueue"
        static func sourceChip(_ name: String) -> String { "soyeht.fileBrowser.sourceChip.\(name)" }
        static func row(_ path: String) -> String { "soyeht.fileBrowser.row.\(path)" }
        static func rowProgress(_ path: String) -> String { "soyeht.fileBrowser.rowProgress.\(path)" }
        static func rowAction(_ path: String) -> String { "soyeht.fileBrowser.rowAction.\(path)" }
        static func rowError(_ path: String) -> String { "soyeht.fileBrowser.rowError.\(path)" }
        static func breadcrumbSegment(_ index: Int) -> String { "soyeht.fileBrowser.breadcrumb.\(index)" }
        static func historyRow(_ path: String) -> String { "soyeht.fileBrowser.history.\(path)" }
    }

    // MARK: - File Preview

    enum FilePreview {
        static let textView = "soyeht.filePreview.textView"
        static let saveButton = "soyeht.filePreview.saveButton"
        static let shareButton = "soyeht.filePreview.shareButton"
        static let downloadButton = "soyeht.filePreview.downloadButton"
        static let progressView = "soyeht.filePreview.progressView"
        static let toast = "soyeht.filePreview.toast"
    }

    // MARK: - Live Watch

    enum LiveWatch {
        static let gitBadgeButton = "soyeht.liveWatch.gitBadgeButton"
        static let popover = "soyeht.liveWatch.popover"
        static let emptyState = "soyeht.liveWatch.emptyState"
        static let list = "soyeht.liveWatch.list"
        static let openFullScreenButton = "soyeht.liveWatch.openFullScreenButton"
        static func changeRow(_ path: String) -> String { "soyeht.liveWatch.change.\(path)" }
    }

    // MARK: - Diff Viewer

    enum DiffViewer {
        static let peekCard = "soyeht.diff.peekCard"
        static let fullScreen = "soyeht.diff.fullScreen"
        static let textView = "soyeht.diff.textView"
        static let insertButton = "soyeht.diff.insertButton"
        static let copyButton = "soyeht.diff.copyButton"
        static let shareButton = "soyeht.diff.shareButton"
        static let nextButton = "soyeht.diff.nextButton"
        static let previousButton = "soyeht.diff.previousButton"
    }
}
