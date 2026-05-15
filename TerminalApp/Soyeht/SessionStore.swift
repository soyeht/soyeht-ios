import Foundation
import SoyehtCore

// MARK: - Core Session Store Aliases
//
// Keep the unqualified iOS names while binding every normal app flow to the
// same runtime objects used by SoyehtCore.SoyehtAPIClient.shared.store.

typealias PairedServer = SoyehtCore.PairedServer
typealias ServerContext = SoyehtCore.ServerContext
typealias QRScanResult = SoyehtCore.QRScanResult
typealias SessionStore = SoyehtCore.SessionStore
