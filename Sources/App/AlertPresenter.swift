import Cocoa

/// The single way the app shows a modal alert. KapKap is an accessory app, so it activates first;
/// the alert sits above the record bar and region overlay, which live at screen-saver level.
public enum AlertPresenter {
    public static let alertLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    /// "System Settings" on macOS 13+, "System Preferences" before.
    public static var settingsAppName: String {
        if #available(macOS 13, *) {
            return "System Settings"
        }
        return "System Preferences"
    }

    /// Where the privacy switches live: "System Settings › Privacy & Security" on macOS 13+,
    /// "System Preferences › Security & Privacy" before.
    public static var privacySettingsPath: String {
        if #available(macOS 13, *) {
            return "System Settings › Privacy & Security"
        }
        return "System Preferences › Security & Privacy"
    }

    /// Runs a warning alert and returns which button was pressed (`.alertFirstButtonReturn` first).
    @discardableResult
    public static func run(message: String, informativeText: String, buttons: [String] = ["OK"])
        -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        alert.window.level = alertLevel
        return alert.runModal()
    }
}
