import AppKit

/// Builds the shared chromeless light-glass window used by transfer-related
/// panels (the progress window and the large-file decision window), so they look
/// identical: 480px wide, system vibrancy material, a centered title in a 44px
/// bar with a hairline beneath, draggable by its background, top-right, floating
/// and non-activating (never steals focus).
enum GlassPanel {
    static let width: CGFloat = 480
    static let titleBarHeight: CGFloat = 44
    static let bodyInsetTop: CGFloat = 22
    static let bodyInsetSide: CGFloat = 24
    static let bodyInsetBottom: CGFloat = 20

    /// Create the panel and install `body` beneath the title bar with the standard
    /// insets. Returns the panel and its title label (so the caller sets the text).
    /// The caller is responsible for pinning `body`'s own subviews to full width.
    static func make(delegate: NSWindowDelegate?, body: NSView) -> (panel: NSPanel, title: NSTextField) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 210),
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
        // Chromeless: hide the window buttons; the window stays draggable by its
        // background and each panel provides its own actions.
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.delegate = delegate

        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        p.contentView = effect

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(title)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(divider)

        body.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(body)

        NSLayoutConstraint.activate([
            // Center the title within the title bar (a tall label frame would
            // top-align the text), with the hairline fixed at the bar's bottom.
            title.centerYAnchor.constraint(equalTo: effect.topAnchor, constant: titleBarHeight / 2),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            divider.topAnchor.constraint(equalTo: effect.topAnchor, constant: titleBarHeight),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            body.topAnchor.constraint(equalTo: effect.topAnchor, constant: titleBarHeight + bodyInsetTop),
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: bodyInsetSide),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -bodyInsetSide),
            body.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -bodyInsetBottom),
        ])
        return (p, title)
    }

    static func positionTopRight(_ panel: NSPanel) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16))
    }
}
