import AppKit
import SoyehtCore

/// Bottom status bar (design `UxQvb`).
///
/// Layout: [`// servers` label] [server pills …] — [N online right-aligned].
/// Colors: fill `#0A0A0A`, 1pt top stroke `#1A1A1A`, muted text `#6B7280`,
/// green accent `#10B981`, padding `[6, 14]`, 11pt font throughout.
@MainActor
final class StatusBarView: NSView {

    static let height: CGFloat = 28

    private let stack = NSStackView()
    private let onlineLabel = NSTextField(labelWithString: "0 online")
    private var pills: [NSView] = []

    struct Server {
        let name: String
        let tags: [String]
        let online: Bool
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(localHex: "#0A0A0A").cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let topStroke = NSView()
        topStroke.wantsLayer = true
        topStroke.layer?.backgroundColor = NSColor(localHex: "#1A1A1A").cgColor
        topStroke.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topStroke)

        let leadLabel = NSTextField(labelWithString: "// servers")
        leadLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        leadLabel.textColor = NSColor(localHex: "#6B7280")
        leadLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(leadLabel)

        onlineLabel.font = Typography.monoNSFont(size: 11, weight: .medium)
        onlineLabel.textColor = NSColor(localHex: "#10B981")
        onlineLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(onlineLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            topStroke.leadingAnchor.constraint(equalTo: leadingAnchor),
            topStroke.trailingAnchor.constraint(equalTo: trailingAnchor),
            topStroke.topAnchor.constraint(equalTo: topAnchor),
            topStroke.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: onlineLabel.leadingAnchor, constant: -12),

            onlineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            onlineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setServers(_ servers: [Server]) {
        for p in pills { stack.removeArrangedSubview(p); p.removeFromSuperview() }
        pills.removeAll()
        for s in servers {
            let pill = Self.makePill(server: s)
            stack.addArrangedSubview(pill)
            pills.append(pill)
        }
        let onlineCount = servers.filter { $0.online }.count
        onlineLabel.stringValue = "\(onlineCount) online"
    }

    /// A single server pill: `● <name> · <tags>` (5pt dot + name + `·` + comma-joined tags).
    private static func makePill(server: Server) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = (server.online
            ? NSColor(localHex: "#10B981")
            : NSColor(localHex: "#6B7280")).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
        ])
        row.addArrangedSubview(dot)

        let name = NSTextField(labelWithString: server.name)
        name.font = Typography.monoNSFont(size: 11, weight: .regular)
        name.textColor = NSColor(localHex: "#FAFAFA")
        row.addArrangedSubview(name)

        if !server.tags.isEmpty {
            let sep = NSTextField(labelWithString: "·")
            sep.font = Typography.monoNSFont(size: 11, weight: .regular)
            sep.textColor = NSColor(localHex: "#3A3A3A")
            row.addArrangedSubview(sep)

            let tag = NSTextField(labelWithString: server.tags.joined(separator: ", "))
            tag.font = Typography.monoNSFont(size: 11, weight: .regular)
            tag.textColor = NSColor(localHex: "#6B7280")
            row.addArrangedSubview(tag)
        }
        return row
    }
}

private extension NSColor {
    convenience init(localHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            calibratedRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
