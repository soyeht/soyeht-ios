import AppKit
import SwiftUI
import SoyehtCore

/// macOS UI typography tokens.
///
/// Keep terminal content separate: terminal glyph size is user-controlled through
/// `TerminalPreferences.fontSize` and applied by `TerminalView+Typography`.
enum MacTypography {
    private static func appUISize(_ size: CGFloat) -> CGFloat {
        max(Typography.minimumUISize, size)
    }

    private static func nsMonoFont(_ size: CGFloat, weight: Typography.Weight = .regular, italic: Bool = false) -> NSFont {
        Typography.monoNSFont(size: appUISize(size), weight: weight, italic: italic)
    }

    private static func nsSansFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Typography.sansNSFont(size: appUISize(size), weight: weight)
    }

    private static func monoFont(_ size: CGFloat, weight: Typography.Weight = .regular) -> Font {
        Typography.mono(size: appUISize(size), weight: weight)
    }

    private static func sansFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Typography.sans(size: appUISize(size), weight: weight)
    }

    enum NSFonts {
        enum Display {
            static var screenTitle: NSFont { MacTypography.nsSansFont(16, weight: .semibold) }
            static var sheetTitle: NSFont { MacTypography.nsMonoFont(21, weight: .semibold) }
            static var statValue: NSFont { MacTypography.nsMonoFont(21, weight: .semibold) }
            static var calloutTitle: NSFont { MacTypography.nsSansFont(14, weight: .semibold) }
        }

        enum Navigation {
            static var tabTitle: NSFont { MacTypography.nsMonoFont(15, weight: .regular) }
            static var tabTitleActive: NSFont { MacTypography.nsMonoFont(15, weight: .medium) }
            static var tabBadge: NSFont { MacTypography.nsMonoFont(13, weight: .regular) }
            static var tabClose: NSFont { MacTypography.nsMonoFont(13, weight: .regular) }
            static var tabAdd: NSFont { MacTypography.nsMonoFont(17, weight: .regular) }
            static var paneHeader: NSFont { MacTypography.nsMonoFont(13, weight: .regular) }
            static var sidebarHeader: NSFont { MacTypography.nsMonoFont(13, weight: .medium) }
            static var sidebarPrimary: NSFont { MacTypography.nsMonoFont(14, weight: .semibold) }
            static var sidebarSecondary: NSFont { MacTypography.nsMonoFont(13, weight: .regular) }
        }

        enum Text {
            static var body: NSFont { MacTypography.nsSansFont(13) }
            static var bodySmall: NSFont { MacTypography.nsSansFont(12) }
            static var monoBody: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
            static var monoBodyMedium: NSFont { MacTypography.nsMonoFont(12, weight: .medium) }
            static var monoBodySemi: NSFont { MacTypography.nsMonoFont(12, weight: .semibold) }
            static var monoCaptionItalic: NSFont { MacTypography.nsMonoFont(12, weight: .regular, italic: true) }
            static var monoRow: NSFont { MacTypography.nsMonoFont(13, weight: .medium) }
            static var sectionLabel: NSFont { MacTypography.nsMonoFont(12, weight: .medium) }
            static var value: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
        }

        enum Controls {
            static var searchInput: NSFont { MacTypography.nsMonoFont(15, weight: .regular) }
            static var input: NSFont { MacTypography.nsMonoFont(15, weight: .regular) }
            static var dialogInput: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
            static var button: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
            static var primaryButton: NSFont { MacTypography.nsMonoFont(12, weight: .semibold) }
            static var calloutButton: NSFont { MacTypography.nsMonoFont(13, weight: .semibold) }
        }

        enum Status {
            static var banner: NSFont { MacTypography.nsMonoFont(12, weight: .medium) }
            static var badge: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
            static var statLabel: NSFont { MacTypography.nsMonoFont(12, weight: .medium) }
            static var connected: NSFont { MacTypography.nsSansFont(15, weight: .semibold) }
            static var pickerStatus: NSFont { MacTypography.nsSansFont(12) }
        }

        enum CommandPalette {
            static var primary: NSFont { MacTypography.nsMonoFont(13, weight: .medium) }
            static var secondary: NSFont { MacTypography.nsMonoFont(12, weight: .regular) }
        }

        static var authTitle: NSFont { Display.screenTitle }
        static var authBody: NSFont { Text.bodySmall }

        static var commandPaletteSearch: NSFont { Controls.searchInput }
        static var commandPalettePrimary: NSFont { CommandPalette.primary }
        static var commandPaletteSecondary: NSFont { CommandPalette.secondary }

        static var workspaceTabTitle: NSFont { Navigation.tabTitle }
        static var workspaceTabTitleActive: NSFont { Navigation.tabTitleActive }
        static var workspaceTabBadge: NSFont { Navigation.tabBadge }
        static var workspaceTabClose: NSFont { Navigation.tabClose }
        static var workspaceTabAdd: NSFont { Navigation.tabAdd }

        static var paneHeaderHandle: NSFont { Navigation.paneHeader }
        static var paneDisconnectBanner: NSFont { Status.banner }
        static var paneTransientStatus: NSFont { Status.badge }
        static var paneFloatingControl: NSFont { Controls.button }

        static var sidebarHeader: NSFont { Navigation.sidebarHeader }
        static var sidebarWorkspaceName: NSFont { Navigation.sidebarPrimary }
        static var sidebarWorkspaceCount: NSFont { Navigation.sidebarSecondary }
        static var sidebarConversationHandle: NSFont { Navigation.sidebarSecondary }
        static var sidebarBadge: NSFont { Status.badge }
        static var sidebarStatLabel: NSFont { Status.statLabel }
        static var sidebarStatValue: NSFont { Display.statValue }

        static var emptyPaneHeader: NSFont { Text.monoCaptionItalic }
        static var emptyPaneCaption: NSFont { Text.monoBodyMedium }
        static var emptyPaneRow: NSFont { Text.monoRow }

        static var sessionHeaderAgent: NSFont { Text.monoRow }
        static var sessionHeaderSeparator: NSFont { Text.monoBody }
        static var sessionHeaderSubtitle: NSFont { Text.monoBody }
        static var sessionSectionLabel: NSFont { Text.sectionLabel }
        static var sessionPathValue: NSFont { Text.value }
        static var sessionInlineLink: NSFont { Text.value }
        static var sessionWorktreeDescription: NSFont { Text.value }
        static var sessionButton: NSFont { Controls.button }
        static var sessionPrimaryButton: NSFont { Controls.primaryButton }

        static var sheetTitle: NSFont { Display.sheetTitle }
        static var sheetInput: NSFont { Controls.input }
        static var sheetStatus: NSFont { Text.monoBody }
        static var sheetFieldLabel: NSFont { Text.sectionLabel }
        static var dialogInput: NSFont { Controls.dialogInput }

        static var qrTitle: NSFont { Display.calloutTitle }
        static var qrBody: NSFont { Text.body }
        static var qrCaption: NSFont { Text.bodySmall }
        static var qrLinkHeader: NSFont { Text.monoBodySemi }
        static var qrLink: NSFont { Text.value }
        static var qrButton: NSFont { Controls.calloutButton }
        static var qrConnected: NSFont { Status.connected }

        static var instancePickerStatus: NSFont { Status.pickerStatus }
    }

    enum Fonts {
        enum Display {
            static var landingTitle: Font { MacTypography.sansFont(26, weight: .semibold) }
            static var cardTitleLarge: Font { MacTypography.sansFont(18, weight: .semibold) }
            static var panelTitle: Font { MacTypography.sansFont(17, weight: .semibold) }
            static var heroTitle: Font { MacTypography.sansFont(27, weight: .semibold) }
            static var heroSubtitle: Font { MacTypography.sansFont(15) }
            static var heroIcon: Font { MacTypography.sansFont(34, weight: .regular) }
            static var emptyIcon: Font { MacTypography.sansFont(25) }
            static var emptyIconLarge: Font { MacTypography.sansFont(34) }
            static var emptyTitle: Font { MacTypography.sansFont(15, weight: .medium) }
        }

        enum Text {
            static var subtitle: Font { MacTypography.sansFont(14) }
            static var body: Font { MacTypography.sansFont(13) }
            static var bodyLarge: Font { MacTypography.sansFont(14) }
            static var caption: Font { MacTypography.sansFont(12) }
            static var captionMedium: Font { MacTypography.sansFont(12, weight: .medium) }
            static var sectionLabel: Font { MacTypography.sansFont(13, weight: .semibold) }
            static var sectionLabelSmall: Font { MacTypography.sansFont(12, weight: .semibold) }
            static var monoBody: Font { MacTypography.monoFont(13) }
            static var monoCaption: Font { MacTypography.monoFont(12) }
            static var monoHeader: Font { MacTypography.monoFont(15, weight: .semibold) }
            static var monoValue: Font { MacTypography.monoFont(13, weight: .medium) }
        }

        enum Controls {
            static var toolbarIcon: Font { MacTypography.sansFont(13, weight: .semibold) }
            static var searchIcon: Font { MacTypography.sansFont(12, weight: .medium) }
            static var searchText: Font { MacTypography.sansFont(13) }
            static var cta: Font { MacTypography.sansFont(14, weight: .semibold) }
            static var ctaIcon: Font { MacTypography.sansFont(12, weight: .semibold) }
            static var linkIcon: Font { MacTypography.sansFont(12) }
            static var linkText: Font { MacTypography.sansFont(12) }
            static var button: Font { MacTypography.sansFont(13, weight: .semibold) }
            static var actionButton: Font { MacTypography.sansFont(13, weight: .semibold) }
        }

        enum Cards {
            static var badge: Font { MacTypography.sansFont(12, weight: .semibold) }
            static var title: Font { MacTypography.sansFont(15, weight: .semibold) }
            static var subtitle: Font { MacTypography.sansFont(13) }
            static var body: Font { MacTypography.sansFont(12) }
            static var meta: Font { MacTypography.sansFont(12) }
            static var language: Font { MacTypography.sansFont(12, weight: .bold) }
            static var rowTitle: Font { MacTypography.sansFont(14, weight: .semibold) }
            static var rowSubtitle: Font { MacTypography.sansFont(12) }
            static var rowBadge: Font { MacTypography.monoFont(12) }
            static var state: Font { MacTypography.sansFont(12) }
            static var stateStrong: Font { MacTypography.sansFont(12, weight: .semibold) }
        }

        enum Status {
            static var warning: Font { MacTypography.sansFont(12) }
            static var error: Font { MacTypography.sansFont(12) }
            static var loading: Font { MacTypography.monoFont(12) }
            static var footer: Font { MacTypography.sansFont(12) }
            static var storeStatus: Font { MacTypography.sansFont(12, weight: .medium) }
            static var storeInstall: Font { MacTypography.sansFont(12, weight: .semibold) }
            static var polling: Font { MacTypography.sansFont(12) }
            static var banner: Font { MacTypography.sansFont(13, weight: .medium) }
        }

        enum Onboarding {
            static func flowTitle(compact: Bool) -> Font {
                MacTypography.sansFont(compact ? 17 : 21, weight: .semibold)
            }

            static func flowBody(compact: Bool) -> Font {
                MacTypography.sansFont(compact ? 12 : 13)
            }

            static var progressTitle: Font { MacTypography.sansFont(14, weight: .medium) }
            static var progressBody: Font { MacTypography.sansFont(12) }
            static var timer: Font { MacTypography.monoFont(12) }
            static var log: Font { MacTypography.monoFont(12) }
            static var modeTitle: Font { MacTypography.sansFont(15, weight: .semibold) }
            static var modeBody: Font { MacTypography.sansFont(12) }
            static var modeBadge: Font { MacTypography.sansFont(12, weight: .medium) }
        }

        static var welcomeLandingTitle: Font { Display.landingTitle }
        static var welcomeLandingSubtitle: Font { Text.subtitle }
        static var welcomeCardBadge: Font { Cards.badge }
        static var welcomeCardTitle: Font { Display.cardTitleLarge }
        static var welcomeCardSubtitle: Font { Cards.subtitle }
        static var welcomeSectionLabel: Font { Text.sectionLabel }
        static var welcomeWarning: Font { Status.warning }
        static var welcomeProgressTitle: Font { Onboarding.progressTitle }
        static var welcomeProgressBody: Font { Onboarding.progressBody }
        static var welcomeTimer: Font { Onboarding.timer }
        static var welcomeLog: Font { Onboarding.log }
        static var welcomeModeTitle: Font { Onboarding.modeTitle }
        static var welcomeModeBody: Font { Onboarding.modeBody }
        static var welcomeModeBadge: Font { Onboarding.modeBadge }
        static var welcomeBodyMono: Font { Text.monoBody }
        static var welcomeHintMono: Font { Text.monoCaption }

        static func welcomeFlowTitle(compact: Bool) -> Font { Onboarding.flowTitle(compact: compact) }
        static func welcomeFlowBody(compact: Bool) -> Font { Onboarding.flowBody(compact: compact) }

        static var drawerHeader: Font { Text.monoHeader }
        static var drawerToolbarIcon: Font { Controls.toolbarIcon }
        static var drawerSearchIcon: Font { Controls.searchIcon }
        static var drawerSearchText: Font { Controls.searchText }
        static var drawerError: Font { Status.error }
        static var drawerCTA: Font { Controls.cta }
        static var drawerCTAIcon: Font { Controls.ctaIcon }
        static var drawerLinkIcon: Font { Controls.linkIcon }
        static var drawerLinkText: Font { Controls.linkText }
        static var drawerHeroIcon: Font { Display.heroIcon }
        static var drawerTitle: Font { Display.panelTitle }
        static var drawerBody: Font { Text.body }
        static var drawerEmptyIcon: Font { Display.emptyIcon }
        static var drawerEmptyTitle: Font { Text.captionMedium }
        static var drawerLoading: Font { Status.loading }
        static var drawerButton: Font { Controls.button }
        static var drawerRowTitle: Font { Cards.rowTitle }
        static var drawerRowSubtitle: Font { Cards.rowSubtitle }
        static var drawerRowBadge: Font { Cards.rowBadge }
        static var drawerStoreLanguage: Font { Cards.rowBadge }
        static var drawerStoreStatus: Font { Status.storeStatus }
        static var drawerStoreInstall: Font { Status.storeInstall }

        static var clawStoreStatus: Font { Text.body }
        static var clawStoreEmptyIcon: Font { Display.emptyIconLarge }
        static var clawStoreEmptyTitle: Font { Display.emptyTitle }
        static var clawStoreFooter: Font { Status.footer }
        static var clawCardTitle: Font { Cards.title }
        static var clawCardLanguage: Font { Cards.language }
        static var clawCardBody: Font { Cards.body }
        static var clawCardMeta: Font { Cards.meta }
        static var clawCardState: Font { Cards.state }
        static var clawCardStateStrong: Font { Cards.stateStrong }
        static var clawActionButton: Font { Controls.actionButton }

        static var clawDetailPolling: Font { Status.polling }
        static var clawDetailError: Font { Status.error }
        static var clawDetailHeroTitle: Font { Display.heroTitle }
        static var clawDetailVersion: Font { Display.heroSubtitle }
        static var clawDetailBody: Font { Text.bodyLarge }
        static var clawDetailMeta: Font { Cards.meta }
        static var clawDetailLog: Font { Text.monoCaption }
        static var clawDetailSection: Font { Text.sectionLabel }
        static var clawDetailBanner: Font { Status.banner }

        static var clawSetupTitle: Font { Display.panelTitle }
        static var clawSetupBody: Font { Text.caption }
        static var clawSetupCaption: Font { Text.caption }
        static var clawSetupSection: Font { Text.sectionLabelSmall }
        static var clawSetupValue: Font { Text.monoValue }
    }
}
