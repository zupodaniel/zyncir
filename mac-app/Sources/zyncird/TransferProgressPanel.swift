import AppKit
import UniformTypeIdentifiers

/// The file-transfer progress window: a 480px light-glass panel with a large
/// percentage tile as the hero element, file metadata, a gradient progress bar,
/// and a destructive Cancel. Created lazily and reused; shown while a sizeable
/// transfer reports progress, and dismissed shortly after it finishes or is
/// cancelled. Non-activating and pinned top-right, so it never steals focus.
///
/// Recreated from the design handoff, adapted to native AppKit: system vibrancy
/// material and semantic colors so it reads in both light and dark mode, and the
/// window's own traffic-light close button drives Cancel.
final class TransferProgressPanel: NSObject, NSWindowDelegate {

    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let statusLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let rateLabel = NSTextField(labelWithString: "")
    private let bar = ProgressBar()
    private var currentIncoming = true

    // MARK: - Public API (main thread)

    /// Update (and show, if not already visible) the panel with live progress.
    func update(_ p: FileTransfer.TransferProgress) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = self.panel ?? {
            let np = buildPanel()
            self.panel = np
            return np
        }()
        currentIncoming = p.incoming
        let fraction = p.total > 0 ? min(1, Double(p.transferred) / Double(p.total)) : 0

        titleLabel.stringValue = p.incoming ? "Receiving from Device" : "Sending to Device"
        percentLabel.stringValue = "\(Int((fraction * 100).rounded()))%"
        statusLabel.stringValue = p.incoming ? "RECEIVING" : "SENDING"
        setFileName(p.name)
        sizeLabel.stringValue = "\(Self.bytes(p.transferred)) of \(Self.bytes(p.total))"
        rateLabel.stringValue = "\(Self.rate(p.bytesPerSec)) · \(Self.eta(p.eta)) remaining"
        bar.fraction = fraction

        if !panel.isVisible {
            positionTopRight(panel)
            panel.orderFrontRegardless()
        }
    }

    /// Show a brief terminal state, then auto-dismiss. `success == false` covers
    /// both a failed transfer and a user cancel.
    func finish(success: Bool) {
        guard let panel = panel, panel.isVisible else { return }
        if success {
            percentLabel.stringValue = "100%"
            statusLabel.stringValue = "DONE"
            rateLabel.stringValue = "Completed"
            bar.fraction = 1
        } else {
            statusLabel.stringValue = "CANCELLED"
            rateLabel.stringValue = "Cancelled"
        }
        scheduleDismiss(after: 0.9)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - Building

    private func buildPanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        // Chromeless: hide all window buttons; the window stays draggable by its
        // background (isMovableByWindowBackground) and Cancel is the sole control.
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.delegate = self

        // Light-glass material that adapts to light/dark.
        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        p.contentView = effect

        // Centered custom title in the 44px top strip (native title is hidden).
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(titleLabel)

        // Hairline under the 44px title bar, so the title reads as its own region
        // rather than floating over an undivided gap.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(divider)

        let hero = buildHeroTile()
        let meta = buildMetaBlock()
        let topRow = NSStackView(views: [hero, meta])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 20

        let progressRow = buildProgressRow()

        let body = NSStackView(views: [topRow, progressRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 18
        body.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(body)
        NSLayoutConstraint.activate([
            // Center the title within the 44px title bar (a tall label frame would
            // top-align the text), with the hairline fixed at the bar's bottom.
            titleLabel.centerYAnchor.constraint(equalTo: effect.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            divider.topAnchor.constraint(equalTo: effect.topAnchor, constant: 44),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            body.topAnchor.constraint(equalTo: effect.topAnchor, constant: 44 + 22),
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),
            body.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -20),
            topRow.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            progressRow.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            progressRow.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        return p
    }

    private func buildHeroTile() -> NSView {
        let tile = HeroTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .bold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .center

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center

        let col = NSStackView(views: [percentLabel, statusLabel])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(col)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 116),
            tile.heightAnchor.constraint(equalToConstant: 116),
            col.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func buildMetaBlock() -> NSView {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [iconView, nameLabel])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 8

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rateLabel.textColor = .tertiaryLabelColor

        let col = NSStackView(views: [nameRow, sizeLabel, rateLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 5
        col.setCustomSpacing(8, after: nameRow)
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return col
    }

    private func buildProgressRow() -> NSView {
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancel.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [.foregroundColor: NSColor.systemRed,
                         .font: NSFont.systemFont(ofSize: 13, weight: .medium)])

        let row = NSStackView(views: [bar, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    // MARK: - Actions

    @objc private func cancelClicked() { onCancel?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel?()   // the red close button cancels the transfer
        return false  // keep the window object; the finish/hide path dismisses it
    }

    // MARK: - Helpers

    private func setFileName(_ name: String) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        let ext = (name as NSString).pathExtension
        if let type = UTType(filenameExtension: ext) {
            iconView.image = NSWorkspace.shared.icon(for: type)
        } else {
            iconView.image = NSWorkspace.shared.icon(for: .data)
        }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

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

/// The hero percentage tile's surface: a rounded, subtly raised panel whose fill
/// adapts to light/dark so it reads clearly on either theme (a near-opaque white
/// card in light mode, a soft translucent elevation in dark mode).
final class HeroTileView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer.cornerRadius = 20
        layer.borderWidth = 0.5
        layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.10)
                                       : NSColor.white.withAlphaComponent(0.80)).cgColor
        layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.12)
                                   : NSColor.black.withAlphaComponent(0.08)).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.40 : 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -3)
    }
}

/// The determinate progress bar from the design: a subtle rounded track with a
/// blue gradient fill and an animated diagonal stripe overlay.
final class ProgressBar: NSView {

    var fraction: Double = 0 { didSet { needsLayout = true } }

    private let track = CALayer()
    private let fill = CAGradientLayer()
    private let stripe = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        track.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        track.masksToBounds = true

        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.colors = [NSColor(srgbRed: 0x0a/255, green: 0x84/255, blue: 1, alpha: 1).cgColor,
                       NSColor(srgbRed: 0x40/255, green: 0x9c/255, blue: 1, alpha: 1).cgColor]
        fill.masksToBounds = true

        // Diagonal moving stripe — optional polish over the gradient.
        stripe.backgroundColor = stripePattern()
        fill.addSublayer(stripe)

        layer?.addSublayer(track)
        track.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = radius
        CATransaction.commit()

        let w = max(0, min(1, CGFloat(fraction))) * bounds.width
        // The fill width animates smoothly between the ~1 Hz progress samples.
        fill.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        fill.cornerRadius = radius

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripe.frame = CGRect(x: -40, y: 0, width: w + 80, height: bounds.height)
        CATransaction.commit()
        ensureStripeAnimation()
    }

    private func ensureStripeAnimation() {
        guard stripe.animation(forKey: "slide") == nil else { return }
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.byValue = 40
        anim.duration = 0.8
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        stripe.add(anim, forKey: "slide")
    }

    /// A 40pt-wide repeating -45° translucent-white stripe, as a CGImage pattern.
    private func stripePattern() -> CGColor {
        let size = CGSize(width: 40, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.22).setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 10, y: 0))
            path.line(to: NSPoint(x: 30, y: 20))
            path.line(to: NSPoint(x: 20, y: 20))
            path.close()
            path.fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
    }
}
