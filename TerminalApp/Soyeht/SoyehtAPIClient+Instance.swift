import Foundation
import SoyehtCore

// MARK: - Instance Actions (iOS)
//
// The Claw-store extension now lives in SoyehtCore on
// `SoyehtCore.SoyehtAPIClient`. `instanceAction` is the one method still
// called from non-Claw iOS code (`InstanceListView`), so it is kept here as
// a thin extension on the iOS `SoyehtAPIClient` until InstanceListView
// migrates to SoyehtCore's client in a later phase.

extension SoyehtAPIClient {
    func instanceAction(id: String, action: InstanceAction, context: ServerContext) async throws {
        let method = action == .delete ? "DELETE" : "POST"
        let path = action == .delete
            ? "/api/v1/instances/\(id)"
            : "/api/v1/instances/\(id)/\(action.rawValue)"
        let (data, response) = try await authenticatedRequest(path: path, method: method, context: context)
        try checkResponse(response, data: data)
    }
}
