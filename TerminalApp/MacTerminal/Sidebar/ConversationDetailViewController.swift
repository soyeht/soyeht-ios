import AppKit
import SoyehtCore

/// Detail pane of the Conversations Sidebar. Header (handle + agent + path),
/// 4 stat cards, transcript placeholder, and a broker-inject input field
/// anchored at the bottom.
@MainActor
final class ConversationDetailViewController: NSViewController {

    let conversationStore: ConversationStore

    private var selectedConversationID: Conversation.ID?

    private let handleLabel = NSTextField(labelWithString: "No conversation selected")
    private let agentLabel = NSTextField(labelWithString: "")
    private let commanderCard = StatCardView(title: "Commander")
    private let seqCard       = StatCardView(title: "Seq")
    private let tokensCard    = StatCardView(title: "Tokens")
    private let openCard      = StatCardView(title: "Open")
    private let transcriptView = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let injectField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    init(conversationStore: ConversationStore) {
        self.conversationStore = conversationStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        self.view = NSView()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: ConversationStore.changedNotification, object: conversationStore
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func select(conversationID: Conversation.ID?) {
        selectedConversationID = conversationID
        refresh()
    }

    @objc private func storeChanged() { refresh() }

    private func refresh() {
        guard let id = selectedConversationID,
              let conv = conversationStore.conversation(id) else {
            handleLabel.stringValue = "No conversation selected"
            agentLabel.stringValue = ""
            commanderCard.setValue("—")
            seqCard.setValue("—")
            tokensCard.setValue("—")
            openCard.setValue("—")
            transcriptView.string = ""
            sendButton.isEnabled = false
            return
        }
        handleLabel.stringValue = conv.handle
        agentLabel.stringValue = conv.agent.displayName
        commanderCard.setValue(conv.stats.commander)
        seqCard.setValue("\(conv.stats.seq)")
        tokensCard.setValue("\(conv.stats.tokens)")
        openCard.setValue("\(conv.stats.open)")
        sendButton.isEnabled = true
    }

    // MARK: - Actions

    @objc private func sendTapped(_ sender: Any?) {
        guard let id = selectedConversationID else { return }
        let text = injectField.stringValue
        guard !text.isEmpty else { return }
        _ = BrokerInjector.inject(text: text, into: id)
        injectField.stringValue = ""
    }

    // MARK: - Layout

    private func buildUI() {
        handleLabel.font = Typography.monoNSFont(size: 18, weight: .semibold)
        agentLabel.font = Typography.monoNSFont(size: 12, weight: .regular)
        agentLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [handleLabel, agentLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2

        let cardsStack = NSStackView(views: [commanderCard, seqCard, tokensCard, openCard])
        cardsStack.orientation = .horizontal
        cardsStack.distribution = .fillEqually
        cardsStack.spacing = 12

        transcriptView.isEditable = false
        transcriptView.font = Typography.monoNSFont(size: 12, weight: .regular)
        transcriptView.string = "Transcript capture ships in Phase 15.\n"
        transcriptScroll.documentView = transcriptView
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .lineBorder

        injectField.placeholderString = "Inject text into the pane (Enter to send)"
        injectField.font = Typography.monoNSFont(size: 13, weight: .regular)
        injectField.target = self
        injectField.action = #selector(sendTapped(_:))
        sendButton.target = self
        sendButton.action = #selector(sendTapped(_:))
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = false

        let inputRow = NSStackView(views: [injectField, sendButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        injectField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [headerStack, cardsStack, transcriptScroll, inputRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cardsStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            transcriptScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            inputRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])
    }
}
