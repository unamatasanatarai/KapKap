import Cocoa

/// Owns the recording state machine, the record control panel, the region overlay and the recorder,
/// and drives the status item's recording mode. All methods run on the main queue; `ScreenRecording`
/// completions are delivered there too.
public final class RecordingCoordinator: StatusBarControllerDelegate, RecordControlPanelDelegate,
    RegionSelectionOverlayDelegate {
    /// What to capture: a display, an optional region of it, and the even-pixel output size.
    private struct CaptureTarget {
        let displayID: CGDirectDisplayID
        let sourceRect: CGRect?
        let pixelSize: CGSize
        /// The captured area in AppKit global points, outlined while a section records.
        let outlineRect: CGRect?
    }

    public private(set) var state: RecordingState = .idle
    public private(set) var options = RecordingOptions()
    /// Called with true when recording starts and false when it has finished.
    public var onRecordingChanged: ((Bool) -> Void)?

    private let recorder: ScreenRecording
    private let controlPanel: RecordControlPresenting
    private let regionOverlay: RegionSelecting
    private let outline: RecordingOutlinePresenting
    private let defaults: UserDefaults
    private let deferStart: (@escaping () -> Void) -> Void
    private let outputFolder: URL
    private let ensureScreenAccess: () -> Bool
    private let requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void
    private let presentMicrophoneDenied: () -> Void
    private let screens: () -> [ScreenInfo]
    private let mouseLocation: () -> CGPoint
    private let now: () -> Date
    private let reveal: (URL) -> Void
    private let presentError: (String, Error) -> Void
    private let presentScreenAccessDenied: () -> Void
    private let fileManager: FileManager

    /// The dragged region (AppKit global points, clamped) and its screen, while in Section mode.
    private var selection: (rect: CGRect, screen: ScreenInfo)?
    private var recordingStartDate: Date?
    /// The in-progress `.part` file, deleted whenever a recording fails without a usable file.
    private var partURL: URL?
    /// Called once the recording in progress has finished, so the app can quit (see `finishForTermination`).
    private var terminationWaiters: [() -> Void] = []

    public init(
        recorder: ScreenRecording = ScreenRecorder(),
        controlPanel: RecordControlPresenting = RecordControlPanel(),
        regionOverlay: RegionSelecting = RegionSelectionOverlay(),
        outline: RecordingOutlinePresenting = RecordingOutlineWindow(),
        defaults: UserDefaults = .standard,
        // Runs capture start one runloop turn after the panel is ordered out, so it is not recorded.
        deferStart: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        outputFolder: URL = RecordingFileNamer.defaultFolder(),
        ensureScreenAccess: @escaping () -> Bool = CapturePermissions.ensureScreenAccess,
        // Completes synchronously when the answer is already known, as CapturePermissions does.
        requestMicrophoneAccess: @escaping (@escaping (Bool) -> Void) -> Void =
            CapturePermissions.requestMicrophoneAccess,
        presentMicrophoneDenied: @escaping () -> Void = CapturePermissions.presentMicrophoneAccessAlert,
        screens: @escaping () -> [ScreenInfo] = ScreenInfo.current,
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        now: @escaping () -> Date = Date.init,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        presentError: @escaping (String, Error) -> Void = RecordingCoordinator.presentErrorAlert,
        presentScreenAccessDenied: @escaping () -> Void = CapturePermissions.presentScreenAccessAlert,
        fileManager: FileManager = .default
    ) {
        self.recorder = recorder
        self.controlPanel = controlPanel
        self.regionOverlay = regionOverlay
        self.outline = outline
        self.defaults = defaults
        self.deferStart = deferStart
        self.outputFolder = outputFolder
        self.ensureScreenAccess = ensureScreenAccess
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.presentMicrophoneDenied = presentMicrophoneDenied
        self.screens = screens
        self.mouseLocation = mouseLocation
        self.now = now
        self.reveal = reveal
        self.presentError = presentError
        self.presentScreenAccessDenied = presentScreenAccessDenied
        self.fileManager = fileManager
        controlPanel.controlDelegate = self
        regionOverlay.selectionDelegate = self
        recorder.onInterruption = { [weak self] error in
            self?.recordingInterrupted(error)
        }
    }

    // MARK: - StatusBarControllerDelegate

    public func recordScreenRequested() {
        guard let configuring = state.next(.recordRequested) else { return }
        // Checked before the panel appears: the permission alert would sit below the panel's level,
        // and a new grant needs a relaunch anyway.
        guard ensureScreenAccess() else { return }
        state = configuring

        options = RecordingOptions.load(from: defaults)
        showPanel()
    }

    public func stopRequested() {
        guard let finishing = state.next(.stopRequested) else { return }
        finishRecording(finishing, interruption: nil)
    }

    // MARK: - Quitting

    /// Lets a quit finish the recording first. Returns true when the caller must wait for `completion`,
    /// which runs once on the main queue when the file is finished (with a synchronous recorder, before
    /// this returns). Returns false when nothing is being recorded and the app can quit now; the panel
    /// and overlay are dismissed and `completion` is never called.
    public func finishForTermination(_ completion: @escaping () -> Void) -> Bool {
        switch state {
        case .recording:
            terminationWaiters.append(completion)
            stopRequested()
            return true
        case .starting, .finishing:
            // Starting: stopped as soon as capture is up (or released if start fails).
            terminationWaiters.append(completion)
            return true
        case .configuring, .selecting:
            cancelConfiguring()
            return false
        case .idle:
            return false
        }
    }

    // MARK: - Failures

    /// Capture or writing failed mid-recording: finish with what was captured, reveal it, explain.
    private func recordingInterrupted(_ error: Error) {
        guard let finishing = state.next(.failed) else { return }
        finishRecording(finishing, interruption: error)
    }

    /// Stops the recorder, returns to idle and the normal icon, then saves or discards the file.
    /// Exactly one alert is shown on any failure.
    private func finishRecording(_ finishing: RecordingState, interruption: Error?) {
        state = finishing
        recorder.stop { [weak self] result in
            guard let self = self else { return }
            let startDate = self.recordingStartDate
            self.recordingStartDate = nil
            self.state = self.state.next(.didFinish) ?? .idle
            self.outline.hide()
            self.onRecordingChanged?(false)

            switch result {
            case .success(let partURL):
                if self.finalize(partURL, startDate: startDate), let interruption = interruption {
                    self.presentError("Recording stopped: \(interruption.localizedDescription)",
                                      RecordingError.partialRecordingSaved)
                }
            case .failure(RecordingError.recordingIncomplete(let keptURL, _)):
                // Writing failed, but the fragmented file holds everything up to the failure.
                let reason = interruption ?? result.failureError
                if self.finalize(keptURL, startDate: startDate), let reason = reason {
                    self.presentError("Recording stopped: \(reason.localizedDescription)",
                                      RecordingError.partialRecordingSaved)
                }
            case .failure(let error):
                self.discardPartFile()
                if let interruption = interruption,
                   interruption.localizedDescription != error.localizedDescription {
                    self.presentError("Recording stopped: \(interruption.localizedDescription)", error)
                } else {
                    self.presentError("The recording could not be saved.", error)
                }
            }
            self.partURL = nil
            self.releaseTerminationWaiters()
        }
    }

    private func releaseTerminationWaiters() {
        let waiters = terminationWaiters
        terminationWaiters = []
        waiters.forEach { $0() }
    }

    private func discardPartFile() {
        guard let url = partURL, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - RecordControlPanelDelegate

    public func recordControl(didChangeOptions newOptions: RecordingOptions) {
        guard state == .configuring || state == .selecting else { return }
        let areaChanged = newOptions.area != options.area
        let microphoneTurnedOn = newOptions.microphone && !options.microphone
        options = newOptions
        options.save(to: defaults)
        if microphoneTurnedOn {
            ensureMicrophoneAccess { _ in }
        }
        guard areaChanged else { return }
        switch options.area {
        case .section:
            enterSection()
        case .fullscreen:
            exitSection()
        }
    }

    public func recordControlDidRequestRecord() {
        guard state.next(.recordConfirmed) != nil else { return }
        // Record is disabled until a region exists; ignore it if it fires anyway.
        if state == .selecting && selection == nil { return }
        guard options.microphone else {
            startRecording()
            return
        }
        // Re-checked here: access may have changed since the switch was turned on, or the saved
        // toggle predates any prompt. A denial turns the mic off and leaves the panel up, so the next
        // Record is video-only.
        ensureMicrophoneAccess { [weak self] granted in
            if granted {
                self?.startRecording()
            }
        }
    }

    private func startRecording() {
        guard let starting = state.next(.recordConfirmed) else { return }
        if state == .selecting && selection == nil { return }
        let target = captureTarget()
        state = starting
        selection = nil
        controlPanel.dismiss()
        regionOverlay.dismiss()
        deferStart { [weak self] in
            self?.beginCapture(target)
        }
    }

    public func recordControlDidCancel() {
        cancelConfiguring()
    }

    /// Esc in Section mode drops the selection and returns to Fullscreen; Esc otherwise cancels.
    public func recordControlDidPressEscape() {
        guard state == .selecting else {
            cancelConfiguring()
            return
        }
        options.area = .fullscreen
        options.save(to: defaults)
        controlPanel.setArea(.fullscreen)
        exitSection()
    }

    // MARK: - RegionSelectionOverlayDelegate

    public func regionSelection(didSelect rect: CGRect, on screen: ScreenInfo) {
        guard state == .selecting else { return }
        selection = (rect, screen)
        controlPanel.setRecordEnabled(true)
    }

    public func regionSelectionDidClear() {
        guard state == .selecting else { return }
        selection = nil
        controlPanel.setRecordEnabled(false)
    }

    // MARK: - Private

    private func enterSection() {
        guard let selecting = state.next(.sectionChosen) else { return }
        state = selecting
        selection = nil
        controlPanel.setRecordEnabled(false)
        regionOverlay.show()
    }

    private func exitSection() {
        guard let configuring = state.next(.fullscreenChosen) else { return }
        state = configuring
        selection = nil
        regionOverlay.dismiss()
        controlPanel.setRecordEnabled(true)
    }

    /// Asks for mic access; on denial switches the mic off, saves that, and offers System Preferences.
    /// Number of microphone requests still waiting on the system prompt. While above zero the overlay
    /// and panel step aside, because both sit above the prompt's window level and would block it.
    private var pendingMicrophonePrompts = 0

    private func ensureMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        var answered = false
        var suspended = false
        requestMicrophoneAccess { [weak self] granted in
            answered = true
            guard let self = self else { return }
            if suspended {
                self.pendingMicrophonePrompts -= 1
                if self.pendingMicrophonePrompts == 0 {
                    self.setPromptSuspension(false)
                }
            }
            if !granted {
                self.options.microphone = false
                self.options.save(to: self.defaults)
                self.controlPanel.setMicrophone(false)
                self.presentMicrophoneDenied()
            }
            completion(granted)
        }
        // An answer that did not arrive synchronously means the system prompt is on screen.
        if !answered {
            suspended = true
            pendingMicrophonePrompts += 1
            if pendingMicrophonePrompts == 1 {
                setPromptSuspension(true)
            }
        }
    }

    private func setPromptSuspension(_ suspended: Bool) {
        controlPanel.setSuspended(suspended)
        // Only resume the overlay if Section mode is still active when the prompt is answered.
        if suspended || state == .selecting {
            regionOverlay.setSuspended(suspended)
        }
    }

    /// Shows the panel with the current options, entering Section mode when that was last used.
    private func showPanel() {
        controlPanel.show(options: options)
        controlPanel.setRecordEnabled(true)
        if options.area == .section {
            enterSection()
        }
    }

    private func cancelConfiguring() {
        guard let idle = state.next(.cancel) else { return }
        state = idle
        selection = nil
        regionOverlay.dismiss()
        controlPanel.dismiss()
    }

    /// Section records the dragged region on the screen where the drag began. Fullscreen records the
    /// display under the mouse when Record is pressed. Nil when there is nothing to capture.
    private func captureTarget() -> CaptureTarget? {
        if state == .selecting {
            guard let selection = selection else { return nil }
            let screen = selection.screen
            let region = ScreenGeometry.captureRegion(for: selection.rect, on: screen)
            // Back from display-relative top-left points to AppKit global points.
            let outlineRect = CGRect(x: screen.frame.minX + region.sourceRect.minX,
                                     y: screen.frame.maxY - region.sourceRect.maxY,
                                     width: region.sourceRect.width, height: region.sourceRect.height)
            return CaptureTarget(displayID: screen.id, sourceRect: region.sourceRect,
                                 pixelSize: region.pixelSize, outlineRect: outlineRect)
        }
        let all = screens()
        guard let screen = ScreenGeometry.screen(containing: mouseLocation(), in: all) ?? all.first else {
            return nil
        }
        return CaptureTarget(displayID: screen.id, sourceRect: nil,
                             pixelSize: ScreenGeometry.pixelSize(for: screen.frame, scale: screen.scale),
                             outlineRect: nil)
    }

    private func beginCapture(_ target: CaptureTarget?) {
        guard state == .starting else { return }
        do {
            try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            failStart("Could not create the recordings folder.", error)
            return
        }
        guard let target = target else {
            failStart("Could not start recording.", RecordingError.noDisplay)
            return
        }

        let startDate = now()
        let finalURL = RecordingFileNamer.url(for: startDate, in: outputFolder, fileManager: fileManager)
        let partURL = RecordingFileNamer.partURL(for: finalURL)
        let config = RecordingConfig(
            displayID: target.displayID,
            sourceRect: target.sourceRect,
            outputURL: partURL,
            pixelSize: target.pixelSize,
            captureMic: options.microphone,
            captureSystemAudio: options.systemAudio
        )
        recordingStartDate = startDate
        self.partURL = partURL

        recorder.start(config) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                guard let recording = self.state.next(.didStart) else { return }
                self.state = recording
                if let outlineRect = target.outlineRect {
                    self.outline.show(around: outlineRect)
                }
                self.onRecordingChanged?(true)
                if !self.terminationWaiters.isEmpty {
                    // A quit arrived while starting: finish right away so the app can exit.
                    self.stopRequested()
                }
            case .failure(let error):
                self.failStart("Could not start recording.", error)
            }
        }
    }

    /// Start failed: back to the panel when the user can fix it (the display went away), otherwise idle.
    /// Exactly one alert is shown.
    private func failStart(_ message: String, _ error: Error) {
        recordingStartDate = nil
        discardPartFile()
        partURL = nil

        if CapturePermissions.isScreenAccessError(error) {
            state = state.next(.startFailed) ?? .idle
            presentScreenAccessDenied()
        } else if Self.isRetryable(error), terminationWaiters.isEmpty,
                  let configuring = state.next(.startFailedRetryable) {
            state = configuring
            presentError(message, error)
            showPanel()
        } else {
            state = state.next(.startFailed) ?? .idle
            presentError(message, error)
        }
        releaseTerminationWaiters()
    }

    /// A display removed between opening the panel and pressing Record: pick again from the panel.
    private static func isRetryable(_ error: Error) -> Bool {
        return (error as? RecordingError) == .displayNotFound
    }

    /// Renames the finished `.part` file to its final, collision-free name and reveals it.
    /// Returns false (after an alert) when the file could not be moved.
    @discardableResult
    private func finalize(_ partURL: URL, startDate: Date?) -> Bool {
        let finalURL = RecordingFileNamer.url(
            for: startDate ?? now(),
            in: partURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        do {
            try fileManager.moveItem(at: partURL, to: finalURL)
            reveal(finalURL)
            return true
        } catch {
            presentError("The recording could not be saved.", error)
            return false
        }
    }

    /// The default `presentError`: one warning alert, app activated, above the panel and overlay.
    public static func presentErrorAlert(_ message: String, _ error: Error) {
        AlertPresenter.run(message: message, informativeText: error.localizedDescription)
    }
}

private extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
