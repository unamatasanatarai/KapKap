import Cocoa

/// The floating record bar, icons only: ✕ | Fullscreen ▭ / Section ⬚ | microphone, system audio | record.
/// Toggles are bright and highlighted when on, grey when off; the record button follows the app icon
/// (blue gradient disc inside a pulse ring). A borderless, non-activating HUD panel at the bottom
/// center of the display under the mouse, one level above the region selection overlay.
public final class RecordControlPanel: NSPanel, RecordControlPresenting {
    public weak var controlDelegate: RecordControlPanelDelegate?

    public static let systemAudioUnavailableToolTip = "Requires macOS 13 or later"

    private static let escapeKeyCode: UInt16 = 53
    private static let cornerRadius: CGFloat = 12
    private static let recordRed = NSColor(srgbRed: 1.0, green: 59.0 / 255.0, blue: 48.0 / 255.0, alpha: 1.0)

    private var options = RecordingOptions()
    private let closeButton = NSButton()
    private let fullscreenButton = NSButton()
    private let sectionButton = NSButton()
    private let microphoneButton = NSButton()
    private let systemAudioButton = NSButton()
    private let recordButton = NSButton()

    private var isSystemAudioAvailable: Bool {
        if #available(macOS 13, *) {
            return true
        }
        return false
    }

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = RecordControlPanel.activeLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        setupContent()
    }

    public override var canBecomeKey: Bool {
        return true
    }

    public override var canBecomeMain: Bool {
        return false
    }

    // MARK: - RecordControlPresenting

    public func show(options: RecordingOptions) {
        apply(options)
        positionOnScreenUnderMouse()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        orderOut(nil)
    }

    public func setArea(_ area: RecordingOptions.Area) {
        options.area = area
        setIcon(fullscreenButton, symbol: "rectangle", on: area == .fullscreen)
        setIcon(sectionButton, symbol: "rectangle.dashed", on: area == .section)
    }

    public func setRecordEnabled(_ enabled: Bool) {
        recordButton.isEnabled = enabled
        recordButton.alphaValue = enabled ? 1.0 : 0.35
        recordButton.toolTip = enabled ? "Start recording (Return)" : "Drag to select an area first"
    }

    /// One level above the region selection overlay.
    private static let activeLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    public func setSuspended(_ suspended: Bool) {
        level = suspended ? .floating : RecordControlPanel.activeLevel
    }

    public func setMicrophone(_ on: Bool) {
        options.microphone = on
        updateAudioIcons()
    }

    // MARK: - Keyboard and cursor

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            controlDelegate?.recordControlDidPressEscape()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        controlDelegate?.recordControlDidPressEscape()
    }

    // The region overlay sets a crosshair; the bar itself keeps the arrow.
    public override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    public override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: - Layout

    private func setupContent() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let stack = NSStackView(views: [
            makeCloseButton(),
            makeSeparator(),
            makeIconButton(fullscreenButton, label: "Fullscreen", action: #selector(fullscreenClicked)),
            makeIconButton(sectionButton, label: "Section", action: #selector(sectionClicked)),
            makeSeparator(),
            makeIconButton(microphoneButton, label: "Microphone", action: #selector(microphoneClicked)),
            makeSystemAudioButton(),
            makeSeparator(),
            makeRecordButton()
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = background

        let size = stack.fittingSize
        setContentSize(size)
        background.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func makeCloseButton() -> NSView {
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        closeButton.image = Self.symbol("xmark", label: "Cancel", pointSize: 12)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Cancel (Esc)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        return closeButton
    }

    private func makeSeparator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22)
        ])
        return line
    }

    /// A square, borderless icon button; `setIcon` gives it its symbol and on/off look.
    private func makeIconButton(_ button: NSButton, label: String, action: Selector) -> NSButton {
        button.isBordered = false
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    private func makeSystemAudioButton() -> NSView {
        let button = makeIconButton(systemAudioButton, label: "System audio", action: #selector(systemAudioClicked))
        if !isSystemAudioAvailable {
            button.isEnabled = false
            button.toolTip = Self.systemAudioUnavailableToolTip
        }
        return button
    }

    /// The icon look shared by every toggle: bright on a soft highlight when on, grey when off,
    /// dimmer still when unavailable.
    static func iconColors(on: Bool, enabled: Bool) -> (tint: NSColor, background: NSColor) {
        guard enabled else { return (NSColor.white.withAlphaComponent(0.2), .clear) }
        return on
            ? (NSColor.white, NSColor.white.withAlphaComponent(0.2))
            : (NSColor.white.withAlphaComponent(0.45), .clear)
    }

    private func setIcon(_ button: NSButton, symbol: String, on: Bool) {
        button.image = Self.symbol(symbol, label: button.accessibilityLabel() ?? "", pointSize: 15)
        let colors = Self.iconColors(on: on, enabled: button.isEnabled)
        button.contentTintColor = colors.tint
        button.layer?.backgroundColor = colors.background.cgColor
        button.setAccessibilityValue(on ? "on" : "off")
    }

    private static func symbol(_ name: String, label: String, pointSize: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }

    private func makeRecordButton() -> NSView {
        recordButton.isBordered = false
        recordButton.focusRingType = .none
        recordButton.refusesFirstResponder = true
        recordButton.imagePosition = .imageOnly
        recordButton.image = Self.recordButtonImage(diameter: 30)
        recordButton.keyEquivalent = "\r"
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.setAccessibilityLabel("Record")
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recordButton.widthAnchor.constraint(equalToConstant: 34),
            recordButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        setRecordEnabled(true)
        return recordButton
    }

    /// The app icon's look in miniature: a pale blue pulse ring around a blue gradient disc.
    static func recordButtonImage(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            NSColor(srgbRed: 0xa6 / 255.0, green: 0xc3 / 255.0, blue: 0xfc / 255.0, alpha: 1).setStroke()
            ring.stroke()
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: diameter * 0.17, dy: diameter * 0.17))
            let gradient = NSGradient(
                starting: NSColor(srgbRed: 0xdc / 255.0, green: 0xe8 / 255.0, blue: 0xff / 255.0, alpha: 1),
                ending: NSColor(srgbRed: 0x8e / 255.0, green: 0xb0 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
            )
            // Light at the top, as in the icon (AppKit's y grows upwards, so -90° runs top to bottom).
            gradient?.draw(in: disc, angle: -90)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - State

    private func apply(_ newOptions: RecordingOptions) {
        options = newOptions
        if !isSystemAudioAvailable {
            options.systemAudio = false
        }
        setArea(options.area)
        updateAudioIcons()
    }

    private func updateAudioIcons() {
        setIcon(microphoneButton, symbol: options.microphone ? "mic.fill" : "mic.slash.fill", on: options.microphone)
        setIcon(systemAudioButton, symbol: options.systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                on: options.systemAudio)
    }

    /// Bottom center of the display under the mouse, 10% above its bottom edge.
    private func positionOnScreenUnderMouse() {
        let screens = ScreenInfo.current()
        guard let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation, in: screens)
                ?? screens.first else {
            return
        }
        let screenFrame = screen.frame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: (screenFrame.minY + screenFrame.height * 0.10).rounded()
        ))
    }

    // MARK: - Actions

    @objc private func closeClicked() {
        controlDelegate?.recordControlDidCancel()
    }

    @objc private func fullscreenClicked() {
        chooseArea(.fullscreen)
    }

    @objc private func sectionClicked() {
        chooseArea(.section)
    }

    private func chooseArea(_ area: RecordingOptions.Area) {
        guard options.area != area else { return }
        setArea(area)
        controlDelegate?.recordControl(didChangeOptions: options)
    }

    @objc private func microphoneClicked() {
        options.microphone.toggle()
        updateAudioIcons()
        controlDelegate?.recordControl(didChangeOptions: options)
    }

    @objc private func systemAudioClicked() {
        guard isSystemAudioAvailable else { return }
        options.systemAudio.toggle()
        updateAudioIcons()
        controlDelegate?.recordControl(didChangeOptions: options)
    }

    @objc private func recordClicked() {
        controlDelegate?.recordControlDidRequestRecord()
    }
}
