import AppKit

/// NSSplitViewController hosting the workspace outline on the left and the
/// selected conversation's detail on the right.
@MainActor
final class ConversationsSidebarSplitController: NSSplitViewController {

    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore

    private let outlineVC: WorkspaceTreeOutlineController
    private let detailVC: ConversationDetailViewController

    init(workspaceStore: WorkspaceStore, conversationStore: ConversationStore) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.outlineVC = WorkspaceTreeOutlineController(
            workspaceStore: workspaceStore,
            conversationStore: conversationStore
        )
        self.detailVC = ConversationDetailViewController(conversationStore: conversationStore)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        outlineVC.onConversationSelected = { [weak self] id in
            self?.detailVC.select(conversationID: id)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: outlineVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 500
        addSplitViewItem(detailItem)
    }
}
