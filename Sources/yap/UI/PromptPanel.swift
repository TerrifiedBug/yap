import AppKit

/// Ask the user something with a floating banner. `onAccept` runs if they click
/// `button`, `onDismiss` if they actively turn it down, `onSecondary` if they
/// click the optional third button. Ignoring the prompt, or having it retired,
/// runs none of them: only a click is an answer. Any prompt already on screen
/// is replaced.
@MainActor
func askUser(
    title: String,
    body: String,
    button: String,
    secondaryButton: String? = nil,
    onSecondary: (@MainActor () -> Void)? = nil,
    onDismiss: @escaping @MainActor () -> Void = {},
    onAccept: @escaping @MainActor () -> Void
) {
    PromptPanel.present(
        title: title, body: body, button: button,
        secondaryButton: secondaryButton, onSecondary: onSecondary,
        onDismiss: onDismiss, onAccept: onAccept
    )
}

/// Retire the prompt on screen, if any, without accepting it. For when the
/// thing it asked about stopped being true.
@MainActor
func retirePrompt() {
    PromptPanel.retireCurrent()
}

/// One-way announcement in the same pill as the meeting prompt: icon, text,
/// a single action button, gone by itself in a few seconds. If a prompt is
/// on screen it falls back to a notification rather than covering it.
@MainActor
func showToast(
    title: String,
    body: String,
    button: String,
    secondaryButton: String? = nil,
    onSecondary: (@MainActor () -> Void)? = nil,
    destructiveButton: String? = nil,
    onDestructive: (@MainActor () -> Void)? = nil,
    onAccept: @escaping @MainActor () -> Void
) {
    PromptPanel.presentToast(
        title: title, body: body, button: button,
        secondaryButton: secondaryButton, onSecondary: onSecondary,
        destructiveButton: destructiveButton, onDestructive: onDestructive,
        onAccept: onAccept
    )
}

/// One-line text question in the same pill. Only Save or Return answers it.
@MainActor
func askForName(
    title: String,
    prefill: String,
    onSubmit: @escaping @MainActor (String) -> Void
) {
    PromptPanel.presentNameField(title: title, prefill: prefill, onSubmit: onSubmit)
}

/// A borderless capsule panel centred under the menu bar, clear of whatever
/// notch widget lives up there.
///
/// An AppleScript `display dialog` would be four lines instead of this file,
/// but it activates the app and lands centre-screen on the *active* Space: the
/// app you just joined a call in loses focus, and a full-screen meeting window
/// hides the prompt outright. A `.nonactivatingPanel` that joins all spaces and
/// floats over full-screen windows has neither problem — which is the whole
/// job, since everyone we prompt is by definition mid-meeting.
@MainActor
final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    private static var current: PromptPanel?
    /// Announcements live in the same top-centre spot, but in their own slot:
    /// a toast must not be mistaken for a prompt by `retireCurrent()`.
    private static var currentToast: PromptPanel?
    /// Long enough to catch someone settling into a call, short enough that a
    /// missed prompt doesn't linger for the rest of the meeting.
    private static let autoDismissAfter: TimeInterval = 120
    /// A toast says something already true and needs no answer, so it only has
    /// to survive long enough to be read.
    private static let toastDismissAfter: TimeInterval = 6
    /// Clearance below the menu bar. Enough to clear a notch widget hanging
    /// off the menu bar without looking detached from it.
    private static let topGap: CGFloat = 12
    /// Keep the pill clear of the screen edges on narrow displays.
    private static let sideMargin: CGFloat = 20

    private let onAccept: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void
    private let onSecondary: (@MainActor () -> Void)?
    private let onDestructive: (@MainActor () -> Void)?
    private let onNameSubmit: (@MainActor (String) -> Void)?
    private var nameField: NSTextField?
    private var autoDismiss: Timer?
    private let dismissAfter: TimeInterval
    /// Whether a button has already been clicked. See `claimAnswer`.
    private var answered = false

    static func present(
        title: String,
        body: String,
        button: String,
        secondaryButton: String?,
        onSecondary: (@MainActor () -> Void)?,
        onDismiss: @escaping @MainActor () -> Void,
        onAccept: @escaping @MainActor () -> Void
    ) {
        // Both live top-centre, so a question evicts an announcement.
        currentToast?.close()
        current?.close()
        let panel = PromptPanel(
            heading: title, body: body, button: button,
            secondaryButton: secondaryButton, onSecondary: onSecondary,
            destructiveButton: nil, onDestructive: nil,
            namePrefill: nil, onNameSubmit: nil,
            onDismiss: onDismiss, onAccept: onAccept, toast: false
        )
        current = panel
        panel.appear()
    }

    static func presentNameField(
        title: String,
        prefill: String,
        onSubmit: @escaping @MainActor (String) -> Void
    ) {
        currentToast?.close()
        current?.close()
        let panel = PromptPanel(
            heading: title, body: nil, button: "Save",
            secondaryButton: nil, onSecondary: nil,
            destructiveButton: nil, onDestructive: nil,
            namePrefill: prefill, onNameSubmit: onSubmit,
            onDismiss: {}, onAccept: {}, toast: false
        )
        current = panel
        panel.appear()
        panel.makeKey()
        if let field = panel.nameField { panel.makeFirstResponder(field) }
    }

    static func retireCurrent() {
        current?.fadeOut()
    }

    static func presentToast(
        title: String,
        body: String,
        button: String,
        secondaryButton: String?,
        onSecondary: (@MainActor () -> Void)?,
        destructiveButton: String?,
        onDestructive: (@MainActor () -> Void)?,
        onAccept: @escaping @MainActor () -> Void
    ) {
        // A live prompt is a question; never cover it with an announcement.
        // The announcement still reaches the user, just as a notification.
        guard current == nil else {
            notifyUser(title: title, body: body)
            return
        }
        currentToast?.close()
        let panel = PromptPanel(
            heading: title, body: body, button: button,
            secondaryButton: secondaryButton, onSecondary: onSecondary,
            destructiveButton: destructiveButton, onDestructive: onDestructive,
            namePrefill: nil, onNameSubmit: nil,
            onDismiss: {}, onAccept: onAccept, toast: true
        )
        currentToast = panel
        panel.appear()
        NSSound(named: "Glass")?.play()
    }

    private init(
        heading: String,
        body: String?,
        button: String,
        secondaryButton: String?,
        onSecondary: (@MainActor () -> Void)?,
        destructiveButton: String?,
        onDestructive: (@MainActor () -> Void)?,
        namePrefill: String?,
        onNameSubmit: (@MainActor (String) -> Void)?,
        onDismiss: @escaping @MainActor () -> Void,
        onAccept: @escaping @MainActor () -> Void,
        toast: Bool
    ) {
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onSecondary = onSecondary
        self.onDestructive = onDestructive
        self.onNameSubmit = onNameSubmit
        self.dismissAfter = toast ? Self.toastDismissAfter : Self.autoDismissAfter
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // .statusBar, not .floating: this has to clear a full-screen app.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // NSWindow defaults to release-on-close, which over-releases under ARC.
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        if let namePrefill {
            let field = NSTextField(string: namePrefill)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: 12)
            field.placeholderString = "Meeting name"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            // Losing first-responder status is not consent to save. In
            // particular, a non-activating panel can briefly end editing while
            // it negotiates key status. Return still sends the field's action.
            field.cell?.sendsActionOnEndEditing = false
            field.target = self
            field.action = #selector(saveClicked(_:))
            nameField = field
        }
        let content = contentStack(
            heading: heading, body: body, button: button,
            secondaryButton: secondaryButton, destructiveButton: destructiveButton,
            toast: toast
        )
        let background = PillView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            // A long app name must truncate rather than run off a small screen.
            content.widthAnchor.constraint(
                lessThanOrEqualToConstant: (Self.targetScreen()?.visibleFrame.width ?? 1440)
                    - 2 * Self.sideMargin
            ),
        ])
        contentView = background
        setContentSize(background.fittingSize)
    }

    // MARK: - Layout

    private func contentStack(
        heading: String,
        body: String?,
        button: String,
        secondaryButton: String?,
        destructiveButton: String?,
        toast: Bool
    ) -> NSStackView {
        var textViews: [NSView] = [
            Self.label(heading, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        ]
        if let nameField {
            textViews.append(nameField)
        } else if let body {
            textViews.append(
                Self.label(body, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }
        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let accept = CapsuleButton(
            title: button,
            fill: .controlAccentColor,
            textColor: .white,
            target: self,
            action: nameField == nil ? #selector(acceptClicked) : #selector(saveClicked(_:))
        )

        // An announcement has nothing to decline: it is already true, and it
        // leaves on its own. Only a question gets a Dismiss.
        var views: [NSView] = [Self.icon(diameter: 34), text]
        if !toast {
            views.append(
                CapsuleButton(
                    title: "Dismiss",
                    fill: NSColor.labelColor.withAlphaComponent(0.10),
                    textColor: .labelColor,
                    target: self,
                    action: #selector(dismissClicked)
                ))
        }
        // Left of the other two, and the only red thing in the pill: it is
        // the one button here that cannot be undone by clicking again.
        if let destructiveButton {
            views.append(
                CapsuleButton(
                    title: destructiveButton,
                    fill: NSColor.labelColor.withAlphaComponent(0.10),
                    textColor: .systemRed,
                    target: self,
                    action: #selector(destructiveClicked)
                ))
        }
        if let secondaryButton {
            views.append(
                CapsuleButton(
                    title: secondaryButton,
                    fill: NSColor.labelColor.withAlphaComponent(0.10),
                    textColor: .labelColor,
                    target: self,
                    action: #selector(secondaryClicked)
                ))
        }
        views.append(accept)

        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(22, after: text)
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
        // When the width clamp bites, the text gives and the controls don't.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in stack.arrangedSubviews where view !== text {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return stack
    }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// The app mark in a tinted circle. NSImageView already centres an image
    /// smaller than its bounds, so the circle is just a rounded background on
    /// the image view itself.
    private static func icon(diameter: CGFloat) -> NSImageView {
        let view = NSImageView(image: StatusIcon.image(size: diameter * 0.55) ?? NSImage())
        view.imageScaling = .scaleNone
        view.contentTintColor = .controlAccentColor
        view.wantsLayer = true
        view.layer?.cornerRadius = diameter / 2
        view.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.15).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: diameter),
            view.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return view
    }

    // MARK: - Lifecycle

    /// Drop out from under the menu bar and fade in — the same gesture as a
    /// system notification, so it reads as "the machine noticed something"
    /// rather than "an app is interrupting you".
    ///
    /// Top-centre on every Mac, measured off `visibleFrame`, so a notched
    /// laptop, a 27" external and an auto-hidden menu bar all land the same
    /// way — and on a notched Mac it clears whatever notch widget (Island,
    /// Alcove, NotchNook) is parked up there, instead of colliding with the
    /// menu-bar items a top-right banner would sit under.
    private func appear() {
        guard let screen = Self.targetScreen() else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let resting = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.maxY - size.height - Self.topGap,
            width: size.width,
            height: size.height
        )

        setFrameOrigin(NSPoint(x: resting.minX, y: resting.minY + 18))
        alphaValue = 0
        orderFrontRegardless()
        invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // setFrame(_:display:), not setFrameOrigin(_:): only the former
            // animates through NSWindow's proxy. The latter silently does
            // nothing, parking the panel at its pre-animation offset.
            animator().setFrame(resting, display: true)
            animator().alphaValue = 1
        }

        autoDismiss = Timer.scheduledTimer(
            withTimeInterval: dismissAfter,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func fadeOut(completion: (@MainActor () -> Void)? = nil) {
        autoDismiss?.invalidate()
        autoDismiss = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.close()
                completion?()
            }
        }
    }

    override func close() {
        autoDismiss?.invalidate()
        autoDismiss = nil
        if Self.current === self { Self.current = nil }
        if Self.currentToast === self { Self.currentToast = nil }
        super.close()
    }

    /// A panel answers once.
    ///
    /// The fade takes 160 ms and every button stays live and clickable for
    /// all of it, so a double-click ran the action twice: two "Deleted"
    /// toasts, and a second `trashItem` failing on a folder that was already
    /// in the Trash — reported to the user as an error they did not cause.
    /// Claimed synchronously, in the click, because that is the only point
    /// before the fade where the two clicks are still distinguishable.
    private func claimAnswer() -> Bool {
        guard !answered else { return false }
        answered = true
        return true
    }

    @objc private func dismissClicked() {
        guard claimAnswer() else { return }
        let dismiss = onDismiss
        fadeOut()
        dismiss()
    }

    @objc private func acceptClicked() {
        guard claimAnswer() else { return }
        let accept = onAccept
        fadeOut()
        accept()
    }

    @objc private func destructiveClicked() {
        guard let destructive = onDestructive, claimAnswer() else { return }
        fadeOut {
            destructive()
        }
    }

    @objc private func secondaryClicked() {
        guard let secondary = onSecondary, claimAnswer() else { return }
        // Wait until the toast has closed before replacing it with the field.
        // This also keeps the originating mouse-up away from the Save button.
        fadeOut {
            secondary()
        }
    }

    @objc private func saveClicked(_ sender: Any?) {
        guard let field = nameField, let submit = onNameSubmit, claimAnswer() else { return }
        let value = field.stringValue
        // `showToast` only presents while no question occupies the prompt slot.
        fadeOut {
            submit(value)
        }
    }

    /// NSScreen.main is the screen holding the active window — the one the
    /// user is looking at — but it's nil for an accessory app when nothing is
    /// focused, so fall back to the first attached display.
    private static func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: -

/// Capsule background for the banner: `NSVisualEffectView` doesn't round
/// itself, and a CGColor border doesn't follow light/dark on its own.
private final class PillView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyBorderColor()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Pill-shaped button. AppKit has no capsule bezel style, and because the panel
/// is non-activating the buttons also have to accept the very first click
/// rather than spending it on focusing the window.
private final class CapsuleButton: NSButton {
    private let fill: NSColor
    private var hovered = false

    init(title: String, fill: NSColor, textColor: NSColor, target: AnyObject, action: Selector) {
        self.fill = fill
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: textColor,
            ]
        )
        applyFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 24, height: 28)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        let color = hovered ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
