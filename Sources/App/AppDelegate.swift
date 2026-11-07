import Cocoa

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var recordingCoordinator: RecordingCoordinator?
    private let quitConfirmation = QuitConfirmation()
    private lazy var quitPrompt = QuitPromptWindow()
    private var quitKeyMonitor: Any?
    /// The app was activated only so the second ⌘Q reaches it; give focus back if unused.
    private var activatedForQuitPrompt = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let statusBar = StatusBarController()
        let coordinator = RecordingCoordinator()
        coordinator.onRecordingChanged = { [weak statusBar] isRecording in
            statusBar?.setRecording(isRecording)
        }
        statusBar.delegate = coordinator
        statusBar.quitKeyHandler = { [weak self] in self?.quitKeyPressed() }
        installQuitKeyMonitor()
        recoverUnfinishedRecordings()
        statusBarController = statusBar
        recordingCoordinator = coordinator
        NSLog("%@ started successfully.", AppConfig.appName)
    }

    /// Recordings cut short by a crash, force quit or power loss are fragmented MP4s that play up to
    /// their last fragment: give them visible names and show them.
    private func recoverUnfinishedRecordings() {
        let folder = RecordingFileNamer.defaultFolder()
        DispatchQueue.global(qos: .utility).async {
            let recovered = RecordingRecovery.recoverUnfinished(in: folder)
            guard !recovered.isEmpty else { return }
            NSLog("%@ recovered %d unfinished recording(s)", AppConfig.appName, recovered.count)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(recovered)
            }
        }
    }

    /// Quitting while recording finishes the file first. The recording-mode status item has no menu,
    /// so this is reached through `osascript -e 'quit app "KapKap"'`, logout or shutdown.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = recordingCoordinator else { return .terminateNow }
        var replied = false
        let reply = {
            // Always after this method has returned .terminateLater.
            DispatchQueue.main.async {
                guard !replied else { return }
                replied = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        guard coordinator.finishForTermination(reply) else { return .terminateNow }
        // Never block quitting (or a shutdown) on a writer that does not finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationTimeout, execute: reply)
        return .terminateLater
    }

    private static let terminationTimeout: TimeInterval = 15

    // MARK: - Double ⌘Q to quit

    /// Sees ⌘Q whenever KapKap receives keys (record bar, section overlay, or after the first press
    /// activated the app). The status menu's Quit key equivalent arrives via `quitKeyHandler` instead.
    private func installQuitKeyMonitor() {
        quitConfirmation.onPromptChanged = { [weak self] armed in
            self?.quitPromptChanged(armed)
        }
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isQuitKey(event) else { return event }
            // Holding the keys down must not count as a second press.
            if !event.isARepeat {
                self?.quitKeyPressed()
            }
            return nil
        }
    }

    static func isQuitKey(_ event: NSEvent) -> Bool {
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    private func quitKeyPressed() {
        if quitConfirmation.press() {
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + quitConfirmation.window) { [weak self] in
            self?.quitConfirmation.expire()
        }
    }

    private func quitPromptChanged(_ armed: Bool) {
        if armed {
            quitPrompt.present()
            // A menu-bar app only gets keys while active; make sure the second press reaches it.
            if !NSApp.isActive {
                activatedForQuitPrompt = true
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            quitPrompt.hide()
            if activatedForQuitPrompt && NSApp.keyWindow == nil {
                NSApp.deactivate()
            }
            activatedForQuitPrompt = false
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
