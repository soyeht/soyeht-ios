// GENERATED - do not edit; run scripts/gen-claw-store-contract-constants.py
//
// Derived from the vendored Claw Store contract:
//   Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json
// Route IDs, auth kinds, and household operations only. Path templates are
// intentionally NOT generated (kept small). The drift guard
// ClawStoreContractConstantsGuardTests fails if this file goes stale.

enum ClawStoreContractConstants {
    /// Claw Store route identifiers (one per contract route).
    enum RouteID {
        static let adminClawAvailability = "admin_claw_availability"
        static let adminCreateInstance = "admin_create_instance"
        static let adminCreateWorkspace = "admin_create_workspace"
        static let adminDeleteInstance = "admin_delete_instance"
        static let adminDeleteWorkspace = "admin_delete_workspace"
        static let adminGetClaw = "admin_get_claw"
        static let adminInstallClaw = "admin_install_claw"
        static let adminInstanceStatus = "admin_instance_status"
        static let adminListClaws = "admin_list_claws"
        static let adminListWorkspaces = "admin_list_workspaces"
        static let adminRebuildInstance = "admin_rebuild_instance"
        static let adminRenameWorkspace = "admin_rename_workspace"
        static let adminResourceOptions = "admin_resource_options"
        static let adminRestartInstance = "admin_restart_instance"
        static let adminStopInstance = "admin_stop_instance"
        static let adminTerminalPty = "admin_terminal_pty"
        static let adminUninstallClaw = "admin_uninstall_claw"
        static let adminUsers = "admin_users"
        static let householdAttachToken = "household_attach_token"
        static let householdClawAvailability = "household_claw_availability"
        static let householdCreateInstance = "household_create_instance"
        static let householdCreateWorkspace = "household_create_workspace"
        static let householdDeleteInstance = "household_delete_instance"
        static let householdDeleteWorkspace = "household_delete_workspace"
        static let householdInstallClaw = "household_install_claw"
        static let householdInstanceStatus = "household_instance_status"
        static let householdListClaws = "household_list_claws"
        static let householdListInstances = "household_list_instances"
        static let householdListWorkspaces = "household_list_workspaces"
        static let householdRebuildInstance = "household_rebuild_instance"
        static let householdRenameWorkspace = "household_rename_workspace"
        static let householdRestartInstance = "household_restart_instance"
        static let householdStopInstance = "household_stop_instance"
        static let householdTerminalPty = "household_terminal_pty"
        static let householdUninstallClaw = "household_uninstall_claw"
        static let mobileClawAvailability = "mobile_claw_availability"
        static let mobileCreateInstance = "mobile_create_instance"
        static let mobileInstallClaw = "mobile_install_claw"
        static let mobileInstanceStatus = "mobile_instance_status"
        static let mobileListClaws = "mobile_list_claws"
        static let mobileUninstallClaw = "mobile_uninstall_claw"
        static let all: [String] = [Self.adminClawAvailability, Self.adminCreateInstance, Self.adminCreateWorkspace, Self.adminDeleteInstance, Self.adminDeleteWorkspace, Self.adminGetClaw, Self.adminInstallClaw, Self.adminInstanceStatus, Self.adminListClaws, Self.adminListWorkspaces, Self.adminRebuildInstance, Self.adminRenameWorkspace, Self.adminResourceOptions, Self.adminRestartInstance, Self.adminStopInstance, Self.adminTerminalPty, Self.adminUninstallClaw, Self.adminUsers, Self.householdAttachToken, Self.householdClawAvailability, Self.householdCreateInstance, Self.householdCreateWorkspace, Self.householdDeleteInstance, Self.householdDeleteWorkspace, Self.householdInstallClaw, Self.householdInstanceStatus, Self.householdListClaws, Self.householdListInstances, Self.householdListWorkspaces, Self.householdRebuildInstance, Self.householdRenameWorkspace, Self.householdRestartInstance, Self.householdStopInstance, Self.householdTerminalPty, Self.householdUninstallClaw, Self.mobileClawAvailability, Self.mobileCreateInstance, Self.mobileInstallClaw, Self.mobileInstanceStatus, Self.mobileListClaws, Self.mobileUninstallClaw]
    }

    /// Distinct auth kinds across the contract routes.
    enum AuthKind {
        static let adminSession = "admin_session"
        static let adminStreamAuth = "admin_stream_auth"
        static let householdAttachToken = "household_attach_token"
        static let householdPop = "household_pop"
        static let mobileBearer = "mobile_bearer"
        static let mobileBearerAdmin = "mobile_bearer_admin"
        static let all: [String] = [Self.adminSession, Self.adminStreamAuth, Self.householdAttachToken, Self.householdPop, Self.mobileBearer, Self.mobileBearerAdmin]
    }

    /// Distinct household PoP operations.
    enum HouseholdOperation {
        static let clawsCreate = "claws.create"
        static let clawsDelete = "claws.delete"
        static let clawsList = "claws.list"
        static let clawsUse = "claws.use"
        static let all: [String] = [Self.clawsCreate, Self.clawsDelete, Self.clawsList, Self.clawsUse]
    }
}
