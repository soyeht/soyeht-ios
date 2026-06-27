#if os(iOS) && canImport(AuthenticationServices)
import SoyehtCore
import SwiftUI

/// Thin approval-v2 review card. The integration adapter owns all queue,
/// local-anchor, and approval side effects; this View renders only phase.
struct OwnerApprovalV2ReviewScreen: View {
    @ObservedObject var adapter: OwnerApprovalV2ReviewAdapter
    let householdName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            actionRow
        }
        .padding(18)
        .frame(maxWidth: 420, alignment: .leading)
        .background(SoyehtTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
        .task {
            await adapter.prepare()
        }
        .onDisappear {
            adapter.tearDown()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(Typography.monoBodyLargeBold)
                .foregroundColor(SoyehtTheme.accentGreen)
                .frame(width: 34, height: 34)
                .background(SoyehtTheme.accentGreenDim)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "household.approvalV2.review.title",
                    defaultValue: "review mac approval",
                    comment: "Title for the owner approval-v2 review card."
                ))
                .font(Typography.monoSection)
                .foregroundColor(SoyehtTheme.textPrimary)

                Text(LocalizedStringResource(
                    "household.approvalV2.review.subtitle",
                    defaultValue: "approve this request for your household.",
                    comment: "Subtitle for the owner approval-v2 review card."
                ))
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textComment)
            }

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch adapter.phase {
        case .idle, .preparing:
            progressRow(LocalizedStringResource(
                "household.approvalV2.review.preparing",
                defaultValue: "loading request...",
                comment: "Progress text while loading the approval-v2 context."
            ))
        case .prepared(let context):
            contextSection(context)
        case .confirming:
            progressRow(LocalizedStringResource(
                "household.approvalV2.review.confirming",
                defaultValue: "waiting for approval...",
                comment: "Progress text while the passkey approval is in progress."
            ))
        case .completed:
            statusRow(
                icon: "checkmark.circle.fill",
                text: LocalizedStringResource(
                    "household.approvalV2.review.completed",
                    defaultValue: "approved.",
                    comment: "Success text after approval-v2 completes."
                )
            )
        case .cancelled:
            statusRow(
                icon: "xmark.circle.fill",
                text: LocalizedStringResource(
                    "household.approvalV2.review.cancelled",
                    defaultValue: "cancelled.",
                    comment: "Text shown after the owner cancels approval-v2 review."
                )
            )
        case .failed:
            statusRow(
                icon: "exclamationmark.triangle.fill",
                text: LocalizedStringResource(
                    "household.approvalV2.review.failure",
                    defaultValue: "couldn't approve. try again.",
                    comment: "Generic approval-v2 failure text; intentionally hides which step failed."
                )
            )
        }
    }

    private func contextSection(_ context: OwnerApprovalContextV2) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow(
                label: LocalizedStringResource(
                    "household.approvalV2.review.householdLabel",
                    defaultValue: "household",
                    comment: "Label for the household being approved."
                ),
                value: householdName
            )
            infoRow(
                label: LocalizedStringResource(
                    "household.approvalV2.review.operationLabel",
                    defaultValue: "operation",
                    comment: "Label for the approval-v2 operation."
                ),
                value: context.op.rawValue
            )
            infoRow(
                label: LocalizedStringResource(
                    "household.approvalV2.review.machineLabel",
                    defaultValue: "machine",
                    comment: "Label for the machine identifier in an approval-v2 context."
                ),
                value: context.machineID ?? "-"
            )
            infoRow(
                label: LocalizedStringResource(
                    "household.approvalV2.review.addressLabel",
                    defaultValue: "address",
                    comment: "Label for the network address in an approval-v2 context."
                ),
                value: context.addr ?? "-"
            )
            infoRow(
                label: LocalizedStringResource(
                    "household.approvalV2.review.transportLabel",
                    defaultValue: "transport",
                    comment: "Label for the transport in an approval-v2 context."
                ),
                value: context.transport ?? "-"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoyehtTheme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await adapter.cancel() }
            } label: {
                Label {
                    Text(LocalizedStringResource(
                        "household.approvalV2.review.cancelButton",
                        defaultValue: "cancel",
                        comment: "Cancel button for approval-v2 review."
                    ))
                } icon: {
                    Image(systemName: "xmark")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(OwnerApprovalV2SecondaryButtonStyle())
            .disabled(isWorking)

            if shouldShowRetry {
                Button {
                    Task { await adapter.prepare() }
                } label: {
                    Label {
                        Text(LocalizedStringResource(
                            "household.approvalV2.review.retryButton",
                            defaultValue: "try again",
                            comment: "Retry button for approval-v2 review prepare failures."
                        ))
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(OwnerApprovalV2PrimaryButtonStyle(enabled: true))
            } else {
                Button {
                    Task { await adapter.confirm() }
                } label: {
                    confirmButtonLabel
                }
                .buttonStyle(OwnerApprovalV2PrimaryButtonStyle(enabled: canApprove))
                .disabled(!canApprove)
            }
        }
    }

    @ViewBuilder
    private var confirmButtonLabel: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(SoyehtTheme.buttonTextOnAccent)
                Text(LocalizedStringResource(
                    "household.approvalV2.review.approveButton",
                    defaultValue: "approve",
                    comment: "Approve button for approval-v2 review."
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        } else {
            Label {
                Text(LocalizedStringResource(
                    "household.approvalV2.review.approveButton",
                    defaultValue: "approve",
                    comment: "Approve button for approval-v2 review."
                ))
            } icon: {
                Image(systemName: "checkmark")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
        }
    }

    private func infoRow(label: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(label)
                .font(Typography.monoSmallBold)
                .foregroundColor(SoyehtTheme.textComment)
                .frame(width: 84, alignment: .leading)
            Text(verbatim: value)
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressRow(_ text: LocalizedStringResource) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(SoyehtTheme.accentGreen)
            Text(text)
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
    }

    private func statusRow(icon: String, text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Typography.monoSmallBold)
                .foregroundColor(SoyehtTheme.accentAmberStrong)
            Text(text)
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(SoyehtTheme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var canApprove: Bool {
        if case .prepared = adapter.phase { return true }
        return false
    }

    private var isWorking: Bool {
        switch adapter.phase {
        case .preparing, .confirming:
            return true
        case .idle, .prepared, .completed, .cancelled, .failed:
            return false
        }
    }

    private var shouldShowRetry: Bool {
        if case .failed(let canRetry) = adapter.phase { return canRetry }
        return false
    }
}

private struct OwnerApprovalV2PrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.monoBodySemi)
            .foregroundColor(enabled ? SoyehtTheme.buttonTextOnAccent : SoyehtTheme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(enabled ? SoyehtTheme.accentGreen : SoyehtTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct OwnerApprovalV2SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.monoBodySemi)
            .foregroundColor(SoyehtTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(SoyehtTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
#endif
