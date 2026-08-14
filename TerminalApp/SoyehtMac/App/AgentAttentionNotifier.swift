import AppKit
import Foundation
import UserNotifications
import os

/// Posts local macOS notifications when an agent pane needs the user's
/// attention (blocked on a decision reported by harness hooks, or an explicit
/// `request_attention` MCP call). Clicking the notification focuses the pane.
final class AgentAttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentAttentionNotifier()

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "agent-attention")
    /// Minimum interval between notifications for the same pane.
    private static let minIntervalPerPane: TimeInterval = 10
    /// A report older than this never suppresses a lower-authority report.
    static let higherAuthorityWindow: TimeInterval = 60

    private var authorized = false
    private var lastNotificationAt: [UUID: Date] = [:]

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Self.logger.error("attention_auth_failed error=\(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    @MainActor
    func notifyAgentAttention(
        conversationID: Conversation.ID,
        handle: String,
        title: String,
        message: String?
    ) {
        guard authorized else {
            Self.logger.info("attention_skipped_not_authorized pane=\(handle, privacy: .public)")
            return
        }
        if let last = lastNotificationAt[conversationID],
           Date().timeIntervalSince(last) < Self.minIntervalPerPane {
            return
        }
        if isPaneVisible(conversationID) {
            return
        }
        lastNotificationAt[conversationID] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = (message?.isEmpty == false) ? message! : "O agente precisa de uma ação sua."
        content.sound = .default
        content.userInfo = ["conversationID": conversationID.uuidString]
        let request = UNNotificationRequest(
            identifier: "soyeht-attention-\(conversationID.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("attention_post_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        Self.logger.info("attention_notified pane=\(handle, privacy: .public) title=\(title, privacy: .public)")
    }

    @MainActor
    private func isPaneVisible(_ conversationID: Conversation.ID) -> Bool {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? SoyehtMainWindowController,
              let conversation = AppEnvironment.conversationStore?.conversation(conversationID),
              controller.activeWorkspaceID == conversation.workspaceID else {
            return false
        }
        return controller.store.workspace(conversation.workspaceID)?.activePaneID == conversationID
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let rawID = response.notification.request.content.userInfo["conversationID"] as? String ?? ""
        guard let conversationID = UUID(uuidString: rawID) else { return }
        await MainActor.run {
            Self.focusPaneEverywhere(conversationID: conversationID)
        }
    }

    @MainActor
    private static func focusPaneEverywhere(conversationID: Conversation.ID) {
        guard let conversation = AppEnvironment.conversationStore?.conversation(conversationID),
              let workspaceStore = AppEnvironment.workspaceStore else {
            return
        }
        let workspaceID = conversation.workspaceID
        for window in NSApp.windows {
            guard let controller = window.windowController as? SoyehtMainWindowController,
                  workspaceStore.workspace(workspaceID, isInWindow: controller.windowID) else {
                continue
            }
            window.makeKeyAndOrderFront(nil)
            controller.store.setActivePane(workspaceID: workspaceID, paneID: conversationID)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
    }
}
