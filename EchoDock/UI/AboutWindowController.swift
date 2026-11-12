import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private static let fallbackVersion = "1.1.0"
    private static let fallbackBuild = "2026110607"

    init(bundle: Bundle = .main) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("statusItem.about")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = contentView

        super.init(window: window)

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: "SameDock")
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.alignment = .center

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Self.fallbackVersion
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? Self.fallbackBuild

        let versionLabel = metadataLabel(
            text: L10n.format("about.versionFormat", version)
        )
        let buildLabel = metadataLabel(
            text: L10n.format("about.buildFormat", build)
        )

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: L10n.text("statusItem.aboutDescription")
        )
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 4

        let creditsButton = NSButton(title: L10n.text("about.credits"), target: self, action: #selector(showCredits))
        creditsButton.bezelStyle = .inline
        let stack = NSStackView(views: [
            iconView,
            nameLabel,
            versionLabel,
            buildLabel,
            descriptionLabel,
            creditsButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: iconView)
        stack.setCustomSpacing(7, after: nameLabel)
        stack.setCustomSpacing(14, after: buildLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 5),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showCredits() {
        let alert = NSAlert()
        alert.messageText = L10n.text("about.credits")
        alert.informativeText = L10n.text("about.attribution")
        alert.addButton(withTitle: L10n.text("about.viewLicense"))
        alert.addButton(withTitle: L10n.text("fileUndo.error.dismiss"))
        if alert.runModal() == .alertFirstButtonReturn,
           let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
            NSWorkspace.shared.open(license)
        }
    }

    private func metadataLabel(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .center
        return label
    }
}
