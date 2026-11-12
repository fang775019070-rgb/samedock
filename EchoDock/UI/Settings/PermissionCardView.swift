import AppKit

/// Shared by the first-launch introduction and the permissions pane.
@MainActor
final class PermissionCardView: NSView {
    var onContinue: (() -> Void)?
    private let actionButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityMark = NSImageView()
    private let captureMark = NSImageView()
    private static let paper = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1)
    }
    private static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.15, blue: 0.12, alpha: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let brand = label("SameDock", size: 20, english: true)
        let title = label(L10n.text("setup.title"), size: 29)
        let subtitle = label(L10n.text("setup.subtitle"), size: 15)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [brand, title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 13
        header.setCustomSpacing(28, after: brand)
        let permissions = NSStackView(views: [
            rule(),
            permissionRow(title: "setup.accessibility.title", detail: "setup.accessibility.detail", mark: accessibilityMark),
            rule(),
            permissionRow(title: "setup.capture.title", detail: "setup.capture.detail", mark: captureMark),
            rule()
        ])
        permissions.orientation = .vertical
        permissions.alignment = .leading
        permissions.spacing = 20
        for row in permissions.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: permissions.widthAnchor).isActive = true
        }
        statusLabel.font = Self.serifFont(size: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        actionButton.title = L10n.text("setup.begin")
        actionButton.font = Self.serifFont(size: 16)
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(continuePressed)
        let reassurance = label(L10n.text("setup.nativeUnaffected"), size: 12)
        reassurance.textColor = .secondaryLabelColor
        reassurance.alignment = .center
        let footer = NSStackView(views: [statusLabel, actionButton, reassurance])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 17
        footer.setCustomSpacing(11, after: actionButton)
        for item in footer.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        let stack = NSStackView(views: [header, permissions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 29
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for section in stack.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 424),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 38),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -38),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -30),
            actionButton.heightAnchor.constraint(equalToConstant: 42)
        ])
        let width = stack.widthAnchor.constraint(equalToConstant: 424)
        width.priority = .defaultHigh
        width.isActive = true
        update(accessibilityGranted: false, captureGranted: false,
               status: L10n.text("setup.note"), action: L10n.text("setup.begin"))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Self.paper.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(accessibilityGranted: Bool, captureGranted: Bool, status: String, action: String, actionEnabled: Bool = true) {
        setMark(accessibilityMark, granted: accessibilityGranted)
        setMark(captureMark, granted: captureGranted)
        statusLabel.stringValue = status
        actionButton.title = action
        actionButton.isEnabled = actionEnabled
    }

    private func setMark(_ mark: NSImageView, granted: Bool) {
        mark.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "circle",
                            accessibilityDescription: L10n.text(granted ? "setup.granted" : "setup.notGranted"))
        mark.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
    }

    private func permissionRow(title: String, detail: String, mark: NSImageView) -> NSView {
        let copy = NSStackView(views: [label(L10n.text(title), size: 18), label(L10n.text(detail), size: 15)])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 7
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 19), mark.heightAnchor.constraint(equalToConstant: 19)])
        let row = NSStackView(views: [copy, NSView(), mark])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func rule() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func label(_ text: String, size: CGFloat, english: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = Self.serifFont(size: size, english: english)
        field.textColor = Self.ink
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    static func serifFont(size: CGFloat, english: Bool = false) -> NSFont {
        let chinese = !english && L10n.text("setup.language") == "zh"
        return NSFont(name: chinese ? "SongtiSC-Regular" : "TimesNewRomanPSMT", size: size)
            ?? NSFont(name: chinese ? "STSongti-SC-Regular" : "Georgia", size: size)
            ?? .systemFont(ofSize: size)
    }

    @objc private func continuePressed() { onContinue?() }
}
