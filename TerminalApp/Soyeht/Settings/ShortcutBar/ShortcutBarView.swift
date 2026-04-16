import SwiftUI
import SoyehtCore

struct ShortcutBarView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activeItems: [ShortcutBarItem] = []
    @State private var expandedPreset: WorkflowPreset? = nil
    @State private var showCreator = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Nav bar
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    Text("Shortcut Bar")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content — full-screen List
                List {
                    activeSection
                    shelfSection
                    presetsSection
                    createSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadItems() }
        .sheet(isPresented: $showCreator) {
            CustomShortcutCreatorView { newItem in
                var customs = TerminalPreferences.shared.shortcutBarCustomItems
                customs.append(newItem)
                TerminalPreferences.shared.shortcutBarCustomItems = customs
                activeItems.append(newItem)
                save()
            }
        }
    }

    // MARK: - Active Section

    private var activeSection: some View {
        Section {
            ForEach($activeItems, editActions: [.move, .delete]) { $item in
                activeRow(item)
            }
            .onChange(of: activeItems) { _ in save() }
            .listRowBackground(Color(hex: "#0A0A0A"))
            .listRowSeparator(.hidden)
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                Text("// active shortcut keys")
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGray)

                Text("Drag to reorder. Swipe to remove.")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)
            }
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func activeRow(_ item: ShortcutBarItem) -> some View {
        HStack(spacing: 10) {
            keyBadge(item)

            Text(item.label)
                .font(Typography.monoCardMedium)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            if let desc = item.description {
                Text(desc)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGray)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shelf Section

    private var shelfSection: some View {
        Section {
            ForEach(shelfItems) { item in
                Button {
                    activeItems.append(item)
                    save()
                } label: {
                    shelfRow(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(hex: "#0A0A0A"))
                .listRowSeparator(.hidden)
            }
        } header: {
            Text("// available shortcuts")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.historyGray)
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func shelfRow(_ item: ShortcutBarItem) -> some View {
        HStack(spacing: 10) {
            keyBadge(item)

            Text(item.label)
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textPrimary)

            if let desc = item.description {
                Text(desc)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGray)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "plus.circle.fill")
                .font(Typography.sansHeading)
                .foregroundColor(SoyehtTheme.historyGreen)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        Section {
            ForEach(WorkflowPreset.allCases) { preset in
                presetRow(preset)
                    .listRowBackground(Color(hex: "#0A0A0A"))
                    .listRowSeparator(.hidden)
            }
        } header: {
            Text("// workflow presets")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.historyGray)
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func presetRow(_ preset: WorkflowPreset) -> some View {
        let isExpanded = expandedPreset == preset

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: preset.icon)
                    .font(Typography.sansBody)
                    .foregroundColor(Color(hex: preset.iconColorHex))
                    .frame(width: 18, alignment: .center)

                Text(preset.displayName)
                    .font(Typography.monoLabelRegular)
                    .foregroundColor(SoyehtTheme.textPrimary)

                Spacer()

                Text("\(preset.keyCount) keys")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGray)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Typography.sansSmall)
                    .foregroundColor(isExpanded ? SoyehtTheme.historyGreen : SoyehtTheme.textTertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPreset = isExpanded ? nil : preset
                }
            }

            // Expanded content
            if isExpanded {
                Rectangle()
                    .fill(Color(hex: "#1A1A1A"))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    let resolvedItems = preset.resolvedItems()
                    ForEach(resolvedItems) { item in
                        HStack(spacing: 8) {
                            keyBadge(item)
                            Text(item.label)
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textPrimary)
                            if let desc = item.description {
                                Text(desc)
                                    .font(Typography.monoSmall)
                                    .foregroundColor(SoyehtTheme.historyGray)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)

                Text("Apply Preset")
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(
                        Rectangle()
                            .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { applyPreset(preset) }
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .overlay(
            Rectangle()
                .stroke(isExpanded ? SoyehtTheme.historyGreen : Color(hex: "#1A1A1A"), lineWidth: 1)
        )
    }

    // MARK: - Create Section

    private var createSection: some View {
        Section {
            Button {
                showCreator = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(Typography.sansSection)
                        .foregroundColor(SoyehtTheme.historyGreen)

                    Text("Create Custom Shortcut")
                        .font(Typography.monoCardMedium)
                        .foregroundColor(SoyehtTheme.historyGreen)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .listRowBackground(
                Color(hex: "#10B981").opacity(0.06)
            )
            .listRowSeparator(.hidden)
        } footer: {
            Text("Presets apply an optimized key set for each workflow.")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textTertiary)
                .padding(.top, 8)
        }
    }

    // MARK: - Key Badge

    private func keyBadge(_ item: ShortcutBarItem) -> some View {
        let (textColor, bgColor) = badgeColors(for: item)
        return Text(item.label)
            .font(Typography.monoSmallMedium)
            .foregroundColor(textColor)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(bgColor)
    }

    private func badgeColors(for item: ShortcutBarItem) -> (Color, Color) {
        switch item.style {
        case .danger:
            return (SoyehtTheme.accentRed, Color(hex: "#2A1A1A"))
        case .action:
            return (SoyehtTheme.historyGreen, Color(hex: "#1A2A1A"))
        case .default:
            return (SoyehtTheme.textPrimary, Color(hex: "#2A2A2A"))
        }
    }

    // MARK: - Shelf Computation

    private var shelfItems: [ShortcutBarItem] {
        let activeIDs = Set(activeItems.map(\.id))
        let customs = TerminalPreferences.shared.shortcutBarCustomItems
        let builtins = ShortcutBarCatalog.allBuiltins.filter { !activeIDs.contains($0.id) }
        let popular = ShortcutBarCatalog.popularShortcuts.filter { !activeIDs.contains($0.id) }
        let customShelf = customs.filter { !activeIDs.contains($0.id) }
        return builtins + popular + customShelf
    }

    // MARK: - Actions

    private func loadItems() {
        activeItems = TerminalPreferences.shared.resolvedActiveItems()
    }

    private func save() {
        TerminalPreferences.shared.shortcutBarActiveIDs = activeItems.map(\.id)
        NotificationCenter.default.post(name: .soyehtShortcutBarChanged, object: nil)
    }

    private func applyPreset(_ preset: WorkflowPreset) {
        activeItems = preset.resolvedItems(
            customItems: TerminalPreferences.shared.shortcutBarCustomItems
        )
        save()
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedPreset = nil
        }
    }
}
