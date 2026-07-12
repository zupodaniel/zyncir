import AppKit

/// A small always-on-top HUD panel that shows the current device→Mac transfer.
/// Created lazily and reused: shown when a sizeable pull reports progress, hidden
/// when it finishes or is cancelled. Non-activating, so it never steals focus.
///
/// Layout is "percentage-forward": a large % badge on the left is the focal
/// point, with the filename and byte/rate/ETA details stacked to its right, and
/// the progress bar spanning the bottom next to Cancel.
final class TransferProgressPanel: NSObject {

    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let rateLabel = NSTextField(labelWithString: "")
    private let bar = ProgressBar()

    /// Update (and show, if not already visible) the panel. Main thread only.
    func update(_ p: FileTransfer.TransferProgress) {
        let panel = self.panel ?? {
            let np = buildPanel()
            self.panel = np
            return np
        }()
        let fraction = p.total > 0 ? min(1, Double(p.transferred) / Double(p.total)) : 0
        panel.title = p.incoming ? "Receiving from device" : "Sending to device"
        percentLabel.stringValue = "\(Int(fraction * 100))%"
        nameLabel.stringValue = p.name
        sizeLabel.stringValue = "\(Self.bytes(p.transferred)) / \(Self.bytes(p.total))"
        rateLabel.stringValue = "\(Self.rate(p.bytesPerSec)) · ETA \(Self.eta(p.eta))"
        bar.fraction = fraction
        if !panel.isVisible {
            positionTopRight(panel)
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel?.orderOut(nil) }

    // MARK: - Building

    private func buildPanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 148),
                        styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Receiving from device"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Big % badge — the focal point.
        percentLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .center
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        badge.layer?.cornerRadius = 14
        badge.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(percentLabel)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 68),
            badge.heightAnchor.constraint(equalToConstant: 68),
            percentLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        // Right column: filename + details.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [sizeLabel, rateLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        let details = NSStackView(views: [nameLabel, sizeLabel, rateLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4

        let topRow = NSStackView(views: [badge, details])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14

        // Bottom row: bar spans, Cancel hugs the right.
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        let bottomRow = NSStackView(views: [bar, cancel])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12

        let stack = NSStackView(views: [topRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = p.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            topRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return p
    }

    @objc private func cancelClicked() { onCancel?() }

    private func positionTopRight(_ panel: NSPanel) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16))
    }

    // MARK: - Formatting

    private static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private static func rate(_ bps: Double) -> String {
        bps <= 0 ? "—" : String(format: "%.0f MB/s", bps / 1_000_000)
    }

    private static func eta(_ s: TimeInterval) -> String {
        guard s.isFinite else { return "—" }
        let total = Int(s.rounded())
        let m = total / 60, sec = total % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}

/// A high-contrast progress bar: a dark inset track with an accent-colored fill,
/// so it stays legible on the HUD panel regardless of the desktop behind it
/// (the stock `NSProgressIndicator` fill is a pale gray that disappears here).
final class ProgressBar: NSView {

    var fraction: Double = 0 { didSet { needsLayout = true } }

    private let track = CALayer()
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(track)
        track.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    // Keep the accent fill correct after a light/dark appearance change.
    override func updateLayer() {
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        // No implicit animation on the track; the fill animates smoothly between
        // the ~1 Hz progress samples.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = radius
        CATransaction.commit()
        let w = max(0, min(1, CGFloat(fraction))) * bounds.width
        fill.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        fill.cornerRadius = radius
    }
}
