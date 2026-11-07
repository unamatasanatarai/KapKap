import Cocoa

/// A small HUD under the menu bar: "Press ⌘Q again to quit KapKap". Never takes focus or clicks.
public final class QuitPromptWindow: NSPanel {
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "Press ⌘Q again to quit \(AppConfig.appName)")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        contentView = background
        let width = ceil(label.intrinsicContentSize.width) + 32
        setContentSize(NSSize(width: width, height: 36))
    }

    public override var canBecomeKey: Bool {
        return false
    }

    /// Shows the prompt centred near the top of the screen under the mouse.
    public func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 12))
        }
        orderFrontRegardless()
    }

    public func hide() {
        orderOut(nil)
    }
}
