import WidgetKit
import SwiftUI
import SoyehtCore

@main
struct SoyehtLiveActivityBundle: WidgetBundle {
    init() {
        Typography.bootstrap()
    }

    var body: some Widget {
        ClawDeployLiveActivity()
    }
}
