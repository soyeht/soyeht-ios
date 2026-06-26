// GENERATED - do not edit; run scripts/gen-claw-store-contract-constants.py
//
// Derived from the vendored Claw Store contract:
//   Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json
// Route IDs, auth kinds, household operations, and path templates. The drift
// guard ClawStoreContractConstantsGuardTests fails if this file goes stale.

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

    /// Path templates per route id, in raw contract form with the
    /// {name} / {id} / {container} placeholders preserved. Not consumed by
    /// tests; the drift guard pins `byRouteID` == the vendored contract so a
    /// synced path-template change forces a regen.
    enum PathTemplate {
        static let adminClawAvailability = "/api/v1/claws/{name}/availability"
        static let adminCreateInstance = "/api/v1/instances"
        static let adminCreateWorkspace = "/api/v1/terminals/{container}/workspaces"
        static let adminDeleteInstance = "/api/v1/instances/{id}"
        static let adminDeleteWorkspace = "/api/v1/terminals/{container}/workspaces/{id}"
        static let adminGetClaw = "/api/v1/claws/{name}"
        static let adminInstallClaw = "/api/v1/claws/{name}/install"
        static let adminInstanceStatus = "/api/v1/instances/{id}/status"
        static let adminListClaws = "/api/v1/claws"
        static let adminListWorkspaces = "/api/v1/terminals/{container}/workspaces"
        static let adminRebuildInstance = "/api/v1/instances/{id}/rebuild"
        static let adminRenameWorkspace = "/api/v1/terminals/{container}/workspaces/{id}"
        static let adminResourceOptions = "/api/v1/resource-options"
        static let adminRestartInstance = "/api/v1/instances/{id}/restart"
        static let adminStopInstance = "/api/v1/instances/{id}/stop"
        static let adminTerminalPty = "/api/v1/terminals/{container}/pty"
        static let adminUninstallClaw = "/api/v1/claws/{name}/uninstall"
        static let adminUsers = "/api/v1/users"
        static let householdAttachToken = "/api/v1/household/terminals/{container}/attach-token"
        static let householdClawAvailability = "/api/v1/household/claws/{name}/availability"
        static let householdCreateInstance = "/api/v1/household/instances"
        static let householdCreateWorkspace = "/api/v1/household/terminals/{container}/workspaces"
        static let householdDeleteInstance = "/api/v1/household/instances/{id}"
        static let householdDeleteWorkspace = "/api/v1/household/terminals/{container}/workspaces/{id}"
        static let householdInstallClaw = "/api/v1/household/claws/{name}/install"
        static let householdInstanceStatus = "/api/v1/household/instances/{id}/status"
        static let householdListClaws = "/api/v1/household/claws"
        static let householdListInstances = "/api/v1/household/instances"
        static let householdListWorkspaces = "/api/v1/household/terminals/{container}/workspaces"
        static let householdRebuildInstance = "/api/v1/household/instances/{id}/rebuild"
        static let householdRenameWorkspace = "/api/v1/household/terminals/{container}/workspaces/{id}"
        static let householdRestartInstance = "/api/v1/household/instances/{id}/restart"
        static let householdStopInstance = "/api/v1/household/instances/{id}/stop"
        static let householdTerminalPty = "/api/v1/household/terminals/{container}/pty"
        static let householdUninstallClaw = "/api/v1/household/claws/{name}/uninstall"
        static let mobileClawAvailability = "/api/v1/mobile/claws/{name}/availability"
        static let mobileCreateInstance = "/api/v1/mobile/instances"
        static let mobileInstallClaw = "/api/v1/mobile/claws/{name}/install"
        static let mobileInstanceStatus = "/api/v1/mobile/instances/{id}/status"
        static let mobileListClaws = "/api/v1/mobile/claws"
        static let mobileUninstallClaw = "/api/v1/mobile/claws/{name}/uninstall"
        static let byRouteID: [String: String] = [
            "admin_claw_availability": Self.adminClawAvailability,
            "admin_create_instance": Self.adminCreateInstance,
            "admin_create_workspace": Self.adminCreateWorkspace,
            "admin_delete_instance": Self.adminDeleteInstance,
            "admin_delete_workspace": Self.adminDeleteWorkspace,
            "admin_get_claw": Self.adminGetClaw,
            "admin_install_claw": Self.adminInstallClaw,
            "admin_instance_status": Self.adminInstanceStatus,
            "admin_list_claws": Self.adminListClaws,
            "admin_list_workspaces": Self.adminListWorkspaces,
            "admin_rebuild_instance": Self.adminRebuildInstance,
            "admin_rename_workspace": Self.adminRenameWorkspace,
            "admin_resource_options": Self.adminResourceOptions,
            "admin_restart_instance": Self.adminRestartInstance,
            "admin_stop_instance": Self.adminStopInstance,
            "admin_terminal_pty": Self.adminTerminalPty,
            "admin_uninstall_claw": Self.adminUninstallClaw,
            "admin_users": Self.adminUsers,
            "household_attach_token": Self.householdAttachToken,
            "household_claw_availability": Self.householdClawAvailability,
            "household_create_instance": Self.householdCreateInstance,
            "household_create_workspace": Self.householdCreateWorkspace,
            "household_delete_instance": Self.householdDeleteInstance,
            "household_delete_workspace": Self.householdDeleteWorkspace,
            "household_install_claw": Self.householdInstallClaw,
            "household_instance_status": Self.householdInstanceStatus,
            "household_list_claws": Self.householdListClaws,
            "household_list_instances": Self.householdListInstances,
            "household_list_workspaces": Self.householdListWorkspaces,
            "household_rebuild_instance": Self.householdRebuildInstance,
            "household_rename_workspace": Self.householdRenameWorkspace,
            "household_restart_instance": Self.householdRestartInstance,
            "household_stop_instance": Self.householdStopInstance,
            "household_terminal_pty": Self.householdTerminalPty,
            "household_uninstall_claw": Self.householdUninstallClaw,
            "mobile_claw_availability": Self.mobileClawAvailability,
            "mobile_create_instance": Self.mobileCreateInstance,
            "mobile_install_claw": Self.mobileInstallClaw,
            "mobile_instance_status": Self.mobileInstanceStatus,
            "mobile_list_claws": Self.mobileListClaws,
            "mobile_uninstall_claw": Self.mobileUninstallClaw,
        ]
    }
}
