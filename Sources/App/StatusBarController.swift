import Cocoa

public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var isRecording = false

    public weak var delegate: StatusBarControllerDelegate?
    /// ⌘Q pressed while the menu is open (the Quit item's key equivalent). Clicking Quit quits at once.
    public var quitKeyHandler: (() -> Void)?

    public override init() {
        super.init()
        setupStatusItem()
        setupMenu()
    }

    public var currentMenu: NSMenu {
        return menu
    }

    public var currentStatusItem: NSStatusItem {
        return statusItem
    }

    private var idleToolTip: String {
        return "\(AppConfig.appName) — Running"
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = idleToolTip
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    /// Shows the record icon when idle and the stop icon while recording. Both are template images,
    /// so macOS tints them for the menu bar: dark in light mode, light in dark mode, and inverted
    /// while the item is highlighted.
    public func updateIcon() {
        statusItem.button?.image = Self.statusIcon(recording: isRecording)
    }

    /// Switches the status item between idle and recording mode. Idle: a left click starts Record
    /// Screen and a right (or Control-) click opens the menu. Recording: any click asks to stop.
    public func setRecording(_ on: Bool) {
        isRecording = on
        statusItem.button?.toolTip = on ? "Recording — click to stop" : idleToolTip
        updateIcon()
    }

    public enum ClickResult: Equatable {
        case recordScreen
        case showMenu
        case stop
    }

    /// What a click on the status item does. Pure, for tests.
    public static func clickResult(recording: Bool, eventType: NSEvent.EventType?,
                                   modifiers: NSEvent.ModifierFlags) -> ClickResult {
        if recording { return .stop }
        if eventType == .rightMouseUp || eventType == .rightMouseDown || modifiers.contains(.control) {
            return .showMenu
        }
        return .recordScreen
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        switch Self.clickResult(recording: isRecording, eventType: event?.type,
                                modifiers: event?.modifierFlags ?? []) {
        case .stop:
            delegate?.stopRequested()
        case .recordScreen:
            delegate?.recordScreenRequested()
        case .showMenu:
            // Attach the menu just for this click so a left click keeps its own action.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    /// Resources/record-template.svg (idle) and Resources/stop-template.svg (recording), redrawn in
    /// their 240-unit viewBox because NSImage cannot load SVG on macOS 12. Keep the two in sync.
    public static func statusIcon(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 240
            ctx.scaleBy(x: scale, y: scale)

            // Outer ring: r 108, 16 wide, 50% opacity.
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(16)
            ctx.strokeEllipse(in: CGRect(x: 12, y: 12, width: 216, height: 216))

            // Core disc: r 72; the stop icon cuts a rounded square out of it (even-odd).
            ctx.addEllipse(in: CGRect(x: 48, y: 48, width: 144, height: 144))
            if recording {
                ctx.addPath(CGPath(roundedRect: CGRect(x: 90, y: 90, width: 60, height: 60),
                                   cornerWidth: 8, cornerHeight: 8, transform: nil))
            }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Recording — click to stop" : "Record screen"
        return image
    }

    private func setupMenu() {
        menu = NSMenu()

        let appItem = NSMenuItem(
            title: "\(AppConfig.appName) v\(AppConfig.version)",
            action: nil,
            keyEquivalent: ""
        )
        appItem.isEnabled = false
        menu.addItem(appItem)

        menu.addItem(NSMenuItem.separator())

        let recordItem = NSMenuItem(
            title: "Record Screen",
            action: #selector(recordScreenAction),
            keyEquivalent: "r"
        )
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(AppConfig.appName)",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func recordScreenAction() {
        delegate?.recordScreenRequested()
    }

    @objc private func quitAction() {
        if NSApp.currentEvent?.type == .keyDown, let quitKeyHandler = quitKeyHandler {
            quitKeyHandler()
        } else {
            NSApp.terminate(nil)
        }
    }
}
