import AppKit
import UniformTypeIdentifiers

/// A persistent floating panel — styled like the transfer window — that asks
/// whether to download an incoming file that exceeded the auto-download cap.
/// Replaces the easily-missed system notification. Pending files are queued and
/// decided one at a time.
final class LargeFileDecisionPanel: NSObject, NSWindowDelegate {

    /// Called with the file name when the user chooses to download it.
    var onDownload: ((String) -> Void)?

    private var panel: NSPanel?
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")

    private var queue: [(name: String, size: Int64)] = []
    private var current: String?

    // MARK: - Public API (main thread)

    /// Queue a large file for a download decision. De-duplicates by name.
    func enqueue(name: String, sizeBytes: Int64) {
        if current == name { return }
        if let i = queue.firstIndex(where: { $0.name == name }) {
            queue[i].size = sizeBytes
            return
        }
        queue.append((name, sizeBytes))
        if current == nil { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else {
            current = nil
            panel?.orderOut(nil)
            return
        }
        let next = queue.removeFirst()
        current = next.name
        let panel = self.panel ?? {
            let np = buildPanel()
            self.panel = np
            return np
        }()
        setFile(next.name, size: next.size)
        if !panel.isVisible {
            GlassPanel.positionTopRight(panel)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Actions

    @objc private func downloadClicked() {
        if let name = current { onDownload?(name) }
        current = nil
        showNext()
    }

    @objc private func dismissClicked() {
        current = nil
        showNext()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissClicked()
        return false
    }

    // MARK: - Building

    private func setFile(_ name: String, size: Int64) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        let ext = (name as NSString).pathExtension
        iconView.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        sizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        noteLabel.stringValue = "Larger than the auto-download limit."
    }

    private func buildPanel() -> NSPanel {
        // Hero tile: a large file-type icon in the same raised card as the
        // transfer window's percentage tile.
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let tile = HeroTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(iconView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 116),
            tile.heightAnchor.constraint(equalToConstant: 116),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        sizeLabel.textColor = .labelColor
        noteLabel.font = .systemFont(ofSize: 12, weight: .regular)
        noteLabel.textColor = .tertiaryLabelColor

        let metaCol = NSStackView(views: [nameLabel, sizeLabel, noteLabel])
        metaCol.orientation = .vertical
        metaCol.alignment = .leading
        metaCol.spacing = 4
        metaCol.setCustomSpacing(8, after: nameLabel)
        metaCol.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [tile, metaCol])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 20

        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissClicked))
        dismiss.bezelStyle = .rounded
        dismiss.setContentHuggingPriority(.required, for: .horizontal)

        // Primary action. A stock default button only turns blue when its window
        // is key, and this panel is non-activating — so draw the accent fill
        // ourselves to keep it reading as primary in any window state.
        let download = PillButton(title: "Download", target: self, action: #selector(downloadClicked))
        download.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        let actions = NSStackView(views: [spacer, dismiss, download])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12

        let body = NSStackView(views: [topRow, actions])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 18

        let (p, title) = GlassPanel.make(delegate: self, body: body)
        title.stringValue = "Large file from device"
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        return p
    }
}

/// A borderless button with a self-drawn accent fill and white title, so it reads
/// as the primary action regardless of the (non-activating) window's key state,
/// where a stock default button would render gray.
final class PillButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 8
        alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 26
        size.height = 28
        return size
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }
}
