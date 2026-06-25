import SwiftUI
import SoyehtCore

/// The person-first **SHARED APPS** screen (mockup `fz6bO`): the owner's shared
/// claws grouped by who they're shared with ("live · you + Dani"). Observes
/// `SharedAppsViewModel`; the data source is swappable behind `OwnerGroupsReading`
/// (`StubOwnerGroupsReader` for previews → `GETOwnerGroupsReader` live), so this
/// view never changes when the live GET reader is wired in.
struct SharedAppsView: View {
    @StateObject private var model: SharedAppsViewModel

    init(model: SharedAppsViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading shared apps…").foregroundColor(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            case .loaded:
                if model.snapshot.groups.isEmpty {
                    Section {
                        Text("No shared apps yet")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section(header: Text("SHARED APPS")) {
                        ForEach(model.snapshot.groups, id: \.groupID) { group in
                            ForEach(group.grantedClaws, id: \.self) { claw in
                                SharedAppRow(clawName: claw, group: group)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Shared")
        .task { await model.load() }
    }
}

/// One shared-claw row: the app, a "live · you + <people>" presence line, and
/// the members' initial avatars — the fz6bO row anatomy.
private struct SharedAppRow: View {
    let clawName: String
    let group: OwnerGroup

    private var peopleLine: String {
        (["you"] + group.members.map(\.label)).joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(clawName).font(.body)
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("live · \(peopleLine)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: -6) {
                ForEach(group.members.prefix(3), id: \.memberID) { member in
                    Text(member.label.prefix(1).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
struct SharedAppsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SharedAppsView(model: SharedAppsViewModel(reader: StubOwnerGroupsReader()))
        }
    }
}
#endif
