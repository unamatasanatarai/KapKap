import Cocoa

/// Thrown by `expect` so the runner reports a failure instead of trapping like `assert`.
struct RecordingTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw RecordingTestFailure(description: message)
    }
}

/// Records calls and lets each test decide when and how start/stop complete.
private final class FakeScreenRecorder: ScreenRecording {
    var onInterruption: ((Error) -> Void)?
    var startedConfigs: [RecordingConfig] = []
    var stopCount = 0
    var startResult: Result<Void, Error> = .success(())
    /// When true, stop writes a file at the config's output URL before completing.
    var stopWritesFile = true
    /// When set, stop fails with this error, leaving the file behind like a recorder that crashed mid-finish.
    var stopError: Error?
    /// When true, start/stop hold their completion until the test calls `completeStart`/`completeStop`.
    var defersStart = false
    var defersStop = false
    private var pendingStart: ((Result<Void, Error>) -> Void)?
    private var pendingStop: (() -> Void)?

    func start(_ config: RecordingConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        startedConfigs.append(config)
        if defersStart {
            pendingStart = completion
        } else {
            completion(startResult)
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        stopCount += 1
        guard let url = startedConfigs.last?.outputURL else {
            completion(.failure(RecordingError.notRecording))
            return
        }
        let finish = { [self] in
            if self.stopWritesFile {
                FileManager.default.createFile(atPath: url.path, contents: Data("video".utf8))
            }
            if let error = self.stopError {
                completion(.failure(error))
            } else {
                completion(.success(url))
            }
        }
        if defersStop {
            pendingStop = finish
        } else {
            finish()
        }
    }

    func completeStart() {
        let completion = pendingStart
        pendingStart = nil
        completion?(startResult)
    }

    func completeStop() {
        let finish = pendingStop
        pendingStop = nil
        finish?()
    }

    /// Simulates SCStreamDelegate didStopWithError or a writer failure mid-recording.
    func interrupt(_ error: Error) {
        onInterruption?(error)
    }
}

/// Stands in for the floating panel; records what the coordinator asked it to do.
private final class FakeControlPanel: RecordControlPresenting {
    weak var controlDelegate: RecordControlPanelDelegate?
    var shownOptions: [RecordingOptions] = []
    var dismissCount = 0
    var area: RecordingOptions.Area = .fullscreen
    var recordEnabled = true
    var microphoneSwitch: Bool?
    var isVisible = false

    func show(options: RecordingOptions) {
        shownOptions.append(options)
        area = options.area
        isVisible = true
    }

    func dismiss() {
        dismissCount += 1
        isVisible = false
    }

    func setArea(_ area: RecordingOptions.Area) {
        self.area = area
    }

    func setRecordEnabled(_ enabled: Bool) {
        recordEnabled = enabled
    }

    func setMicrophone(_ on: Bool) {
        microphoneSwitch = on
    }

    var isSuspended = false
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }
}

/// Stands in for the TCC microphone check. `pending` holds a prompt the test answers later.
private final class FakeMicrophoneAccess {
    var answer: Bool? = true
    var requestCount = 0
    var deniedAlertCount = 0
    var pending: ((Bool) -> Void)?

    func request(_ completion: @escaping (Bool) -> Void) {
        requestCount += 1
        if let answer = answer {
            completion(answer)
        } else {
            pending = completion
        }
    }

    func answerPrompt(_ granted: Bool) {
        let completion = pending
        pending = nil
        completion?(granted)
    }
}

/// Stands in for the per-screen overlay windows.
private final class FakeRegionOverlay: RegionSelecting {
    weak var selectionDelegate: RegionSelectionOverlayDelegate?
    var isVisible = false
    var showCount = 0

    func show() {
        showCount += 1
        isVisible = true
    }

    func dismiss() {
        isVisible = false
    }

    var isSuspended = false
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }
}

private final class FakeOutline: RecordingOutlinePresenting {
    var shown: CGRect?
    var hideCount = 0
    func show(around rect: CGRect) { shown = rect }
    func hide() {
        shown = nil
        hideCount += 1
    }
}

private struct FakeError: Error {}

private struct DescribedError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Lists the files left in a folder, including hidden `.part` files.
private func files(in folder: URL) -> [String] {
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// A throwaway `UserDefaults` suite, removed by `cleanup`.
private struct TestDefaults {
    let name = "RecordingTests-\(UUID().uuidString)"
    var defaults: UserDefaults { return UserDefaults(suiteName: name)! }
    func cleanup() { UserDefaults().removePersistentDomain(forName: name) }
}

public enum RecordingTests {
    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        runStateTests(testRunner)
        runOptionsTests(testRunner)
        runFileNamerTests(testRunner)
        runStatusBarTests(testRunner)
        runCoordinatorTests(testRunner)
    }

    // MARK: - RecordingState

    private static func runStateTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingState follows the configure → record → stop lifecycle") {
            var state = RecordingState.idle
            for (event, expected) in [
                (RecordingEvent.recordRequested, RecordingState.configuring),
                (.recordConfirmed, .starting),
                (.didStart, .recording),
                (.stopRequested, .finishing),
                (.didFinish, .idle)
            ] {
                guard let next = state.next(event) else {
                    throw RecordingTestFailure(description: "\(event) rejected in \(state)")
                }
                try expect(next == expected, "\(state) --\(event)--> \(next), expected \(expected)")
                state = next
            }
        }

        testRunner("RecordingState returns to idle when start fails") {
            try expect(RecordingState.starting.next(.startFailed) == .idle, "starting --startFailed--> idle")
        }

        testRunner("RecordingState cancels configuring back to idle") {
            try expect(RecordingState.configuring.next(.cancel) == .idle, "configuring --cancel--> idle")
        }

        testRunner("RecordingState enters and leaves section selection") {
            try expect(RecordingState.configuring.next(.sectionChosen) == .selecting,
                       "configuring --sectionChosen--> selecting")
            try expect(RecordingState.selecting.next(.fullscreenChosen) == .configuring,
                       "selecting --fullscreenChosen--> configuring")
            try expect(RecordingState.selecting.next(.recordConfirmed) == .starting,
                       "selecting --recordConfirmed--> starting")
            try expect(RecordingState.selecting.next(.cancel) == .idle, "selecting --cancel--> idle")
        }

        testRunner("RecordingState failure transitions salvage or return to the panel") {
            try expect(RecordingState.recording.next(.failed) == .finishing, "recording --failed--> finishing")
            try expect(RecordingState.finishing.next(.didFinish) == .idle, "salvage then finishes to idle")
            try expect(RecordingState.starting.next(.startFailedRetryable) == .configuring,
                       "starting --startFailedRetryable--> configuring")
            try expect(RecordingState.finishing.next(.failed) == nil, "a second failure while finishing is ignored")
            try expect(RecordingState.idle.next(.failed) == nil, "a failure while idle is ignored")
        }

        testRunner("RecordingState rejects every other transition") {
            let valid: [RecordingState: [RecordingEvent]] = [
                .idle: [.recordRequested],
                .configuring: [.recordConfirmed, .cancel, .sectionChosen],
                .selecting: [.recordConfirmed, .cancel, .fullscreenChosen],
                .starting: [.didStart, .startFailed, .startFailedRetryable],
                .recording: [.stopRequested, .failed],
                .finishing: [.didFinish]
            ]
            for state in [RecordingState.idle, .configuring, .selecting, .starting, .recording, .finishing] {
                for event in RecordingEvent.allCases where !(valid[state] ?? []).contains(event) {
                    try expect(state.next(event) == nil, "\(state) should ignore \(event)")
                }
            }
            try expect(RecordingState.idle.next(.stopRequested) == nil, "stopRequested while idle is ignored")
            try expect(RecordingState.recording.next(.cancel) == nil, "cancel while recording is ignored")
        }
    }

    // MARK: - RecordingOptions

    private static func runOptionsTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingOptions uses defaults when the store is empty") {
            let store = TestDefaults()
            defer { store.cleanup() }
            let options = RecordingOptions.load(from: store.defaults)
            try expect(options == RecordingOptions(area: .fullscreen, microphone: false, systemAudio: false),
                       "unexpected defaults \(options)")
        }

        testRunner("RecordingOptions round-trips through UserDefaults") {
            let store = TestDefaults()
            defer { store.cleanup() }
            let saved = RecordingOptions(area: .section, microphone: true, systemAudio: true)
            saved.save(to: store.defaults)
            let loaded = RecordingOptions.load(from: store.defaults)
            try expect(loaded == saved, "loaded \(loaded), expected \(saved)")
        }

        testRunner("RecordingOptions ignores an unknown saved area") {
            let store = TestDefaults()
            defer { store.cleanup() }
            store.defaults.set("everything", forKey: "recording.area")
            try expect(RecordingOptions.load(from: store.defaults).area == .fullscreen, "falls back to fullscreen")
        }
    }

    // MARK: - RecordingFileNamer

    private static let utc = TimeZone(identifier: "UTC")!

    private static func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 6
        components.hour = 9
        components.minute = 5
        components.second = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    private static func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func runFileNamerTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingFileNamer formats the file name for a fixed date") {
            let folder = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
            let url = RecordingFileNamer.url(for: fixedDate(), in: folder, timeZone: utc)
            try expect(url.lastPathComponent == "Screen Recording 2026-11-06 at 09.05.03.mp4",
                       "unexpected name \(url.lastPathComponent)")
            try expect(url.deletingLastPathComponent().path == folder.path, "file should be inside the folder")
        }

        testRunner("RecordingFileNamer appends 2 and 3 on collisions") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let first = RecordingFileNamer.url(for: fixedDate(), in: folder, timeZone: utc)
            FileManager.default.createFile(atPath: first.path, contents: Data())
            let second = RecordingFileNamer.url(for: fixedDate(), in: folder, timeZone: utc)
            try expect(second.lastPathComponent == "Screen Recording 2026-11-06 at 09.05.03 2.mp4",
                       "unexpected second name \(second.lastPathComponent)")
            FileManager.default.createFile(atPath: second.path, contents: Data())
            let third = RecordingFileNamer.url(for: fixedDate(), in: folder, timeZone: utc)
            try expect(third.lastPathComponent == "Screen Recording 2026-11-06 at 09.05.03 3.mp4",
                       "unexpected third name \(third.lastPathComponent)")
        }

        testRunner("RecordingFileNamer builds a hidden .part URL next to the final file") {
            let final = URL(fileURLWithPath: "/tmp/KapKap/Screen Recording 2026-11-06 at 09.05.03.mp4")
            let part = RecordingFileNamer.partURL(for: final)
            try expect(part.lastPathComponent == ".Screen Recording 2026-11-06 at 09.05.03.mp4.part",
                       "unexpected part name \(part.lastPathComponent)")
            try expect(part.deletingLastPathComponent() == final.deletingLastPathComponent(),
                       "part file should share the final file's folder")
        }

        testRunner("RecordingFileNamer default folder is ~/Movies/<AppName>") {
            let folder = RecordingFileNamer.defaultFolder(appName: "KapKap")
            try expect(folder.lastPathComponent == "KapKap", "unexpected folder \(folder.path)")
            try expect(folder.deletingLastPathComponent().lastPathComponent == "Movies",
                       "folder should be inside Movies: \(folder.path)")
        }
    }

    // MARK: - StatusBarController

    private static func runStatusBarTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("StatusBarController menu offers Record Screen with Shift-Cmd-R") {
            let controller = StatusBarController()
            guard let item = controller.currentMenu.items.first(where: { $0.title == "Record Screen" }) else {
                throw RecordingTestFailure(description: "Record Screen item missing")
            }
            try expect(item.keyEquivalent == "r", "key equivalent should be r")
            try expect(item.keyEquivalentModifierMask == [.command, .shift], "modifiers should be Shift-Cmd")
        }

        testRunner("StatusBarController left click records, right or Control click opens the menu") {
            let result = StatusBarController.clickResult
            try expect(result(false, .leftMouseUp, []) == .recordScreen, "left click starts Record Screen")
            try expect(result(false, .rightMouseUp, []) == .showMenu, "right click opens the menu")
            try expect(result(false, .leftMouseUp, .control) == .showMenu, "Control-click opens the menu")
            try expect(result(true, .leftMouseUp, []) == .stop, "left click while recording stops")
            try expect(result(true, .rightMouseUp, []) == .stop, "right click while recording stops")
        }

        testRunner("StatusBarController has no permanent menu so left clicks reach the action") {
            let controller = StatusBarController()
            try expect(controller.currentStatusItem.menu == nil, "idle mode has no attached menu")
            try expect(controller.currentStatusItem.button?.action != nil, "idle mode has a click action")
            controller.setRecording(true)
            try expect(controller.currentStatusItem.menu == nil, "recording mode has no menu")
            controller.setRecording(false)
            try expect(controller.currentMenu.items.contains { $0.title == "Record Screen" }, "menu keeps Record Screen")
        }

        testRunner("StatusBarController click asks the delegate to record when idle and to stop when recording") {
            final class Spy: StatusBarControllerDelegate {
                var records = 0
                var stops = 0
                func recordScreenRequested() { records += 1 }
                func stopRequested() { stops += 1 }
            }
            let spy = Spy()
            let controller = StatusBarController()
            controller.delegate = spy
            guard let button = controller.currentStatusItem.button, let action = button.action else {
                throw RecordingTestFailure(description: "no button action")
            }
            NSApp.sendAction(action, to: button.target, from: button)
            try expect(spy.records == 1 && spy.stops == 0, "idle click records, got \(spy.records)/\(spy.stops)")
            controller.setRecording(true)
            NSApp.sendAction(action, to: button.target, from: button)
            try expect(spy.stops == 1, "recording click stops, got \(spy.stops)")
        }

        testRunner("QuitConfirmation quits only on a second press within the window") {
            let quit = QuitConfirmation(window: 2)
            var prompts: [Bool] = []
            quit.onPromptChanged = { prompts.append($0) }
            let t0 = Date(timeIntervalSince1970: 1000)
            try expect(!quit.press(at: t0), "first press does not quit")
            try expect(quit.isArmed && prompts == [true], "first press shows the prompt")
            try expect(quit.press(at: t0.addingTimeInterval(1.5)), "second press within 2 s quits")
            try expect(!quit.isArmed && prompts == [true, false], "prompt hidden after quitting")
        }

        testRunner("QuitConfirmation expires after the window and starts over") {
            let quit = QuitConfirmation(window: 2)
            var prompts: [Bool] = []
            quit.onPromptChanged = { prompts.append($0) }
            let t0 = Date(timeIntervalSince1970: 1000)
            quit.press(at: t0)
            quit.expire(at: t0.addingTimeInterval(1))
            try expect(quit.isArmed, "not expired before the window ends")
            quit.expire(at: t0.addingTimeInterval(2))
            try expect(!quit.isArmed && prompts == [true, false], "expired: prompt hidden")
            try expect(!quit.press(at: t0.addingTimeInterval(3)), "a late press re-arms instead of quitting")
            try expect(!quit.press(at: t0.addingTimeInterval(5.5)) && quit.isArmed,
                       "a press after the window (even without expire) re-arms")
        }

        testRunner("StatusBarController routes the Quit key equivalent to the double-press handler") {
            let controller = StatusBarController()
            try expect(controller.quitKeyHandler == nil, "no handler until the app delegate sets one")
            guard let quit = controller.currentMenu.items.first(where: { $0.title.hasPrefix("Quit") }) else {
                throw RecordingTestFailure(description: "Quit item missing")
            }
            try expect(quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == [.command], "Quit shows ⌘Q")
        }

        testRunner("StatusBarController uses 18pt template icons: record when idle, stop while recording") {
            let idle = StatusBarController.statusIcon(recording: false)
            let recording = StatusBarController.statusIcon(recording: true)
            for image in [idle, recording] {
                try expect(image.size == NSSize(width: 18, height: 18), "icon should be 18x18")
                try expect(image.isTemplate, "template, so macOS tints it for light and dark menu bars")
            }
            // The stop square is cut out of the core disc: its centre is filled when idle, empty when recording.
            func alpha(_ image: NSImage, at point: NSPoint) -> CGFloat {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
                return rep.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.alphaComponent ?? 0
            }
            // The stop square spans 90...150 of 240 → 6.75...11.25 pt of an 18 pt icon.
            let barPoint = NSPoint(x: 9, y: 9)
            try expect(alpha(idle, at: barPoint) > 0.9, "record icon: solid disc")
            try expect(alpha(recording, at: barPoint) < 0.1, "stop icon: square cut out")
        }
    }

    // MARK: - RecordingCoordinator

    /// The dev Mac: one 1280×800 pt Retina display (2560×1600 px).
    private static let retinaScreen = ScreenInfo(id: 7, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)

    private static func makeCoordinator(
        recorder: FakeScreenRecorder,
        folder: URL,
        panel: FakeControlPanel = FakeControlPanel(),
        overlay: FakeRegionOverlay = FakeRegionOverlay(),
        outline: FakeOutline = FakeOutline(),
        defaults: UserDefaults? = nil,
        screens: [ScreenInfo] = [retinaScreen],
        mouse: CGPoint = CGPoint(x: 100, y: 100),
        screenAccess: Bool = true,
        microphone: FakeMicrophoneAccess = FakeMicrophoneAccess(),
        revealed: @escaping (URL) -> Void = { _ in },
        errors: @escaping (String, Error) -> Void = { _, _ in },
        screenAccessDenied: @escaping () -> Void = {}
    ) -> RecordingCoordinator {
        return RecordingCoordinator(
            recorder: recorder,
            controlPanel: panel,
            regionOverlay: overlay,
            outline: outline,
            defaults: defaults ?? UserDefaults(suiteName: "RecordingTests-\(UUID().uuidString)")!,
            deferStart: { $0() },
            outputFolder: folder,
            ensureScreenAccess: { screenAccess },
            requestMicrophoneAccess: microphone.request,
            presentMicrophoneDenied: { microphone.deniedAlertCount += 1 },
            screens: { screens },
            mouseLocation: { mouse },
            now: { fixedDate() },
            reveal: revealed,
            presentError: errors,
            presentScreenAccessDenied: screenAccessDenied
        )
    }

    private static func runCoordinatorTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator records, stops, renames .part and reveals the file") {
            let folder = try makeTempFolder().appendingPathComponent("KapKap", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
            let recorder = FakeScreenRecorder()
            var revealed: [URL] = []
            var errors: [Error] = []
            var recordingFlags: [Bool] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder,
                revealed: { revealed.append($0) }, errors: { errors.append($1) })
            coordinator.onRecordingChanged = { recordingFlags.append($0) }

            coordinator.recordScreenRequested()
            try expect(coordinator.state == .configuring, "panel shown first, got \(coordinator.state)")
            try expect(recorder.startedConfigs.isEmpty, "capture waits for Record")
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .recording, "state should be recording, got \(coordinator.state)")
            try expect(recordingFlags == [true], "status item should switch to recording")
            guard let config = recorder.startedConfigs.first else {
                throw RecordingTestFailure(description: "recorder not started")
            }
            try expect(config.displayID == 7 && config.sourceRect == nil, "fullscreen of the chosen display")
            try expect(config.pixelSize == CGSize(width: 2560, height: 1600), "pixel size passed through")
            try expect(!config.captureMic && !config.captureSystemAudio, "audio toggles default to off")
            try expect(config.outputURL.pathExtension == "part", "recorder writes to a .part file")
            try expect(FileManager.default.fileExists(atPath: folder.path), "output folder created on demand")

            coordinator.recordScreenRequested()
            try expect(recorder.startedConfigs.count == 1, "record while recording is ignored")

            coordinator.stopRequested()
            try expect(coordinator.state == .idle, "state should be idle after stop, got \(coordinator.state)")
            try expect(recordingFlags == [true, false], "status item should return to menu mode")
            try expect(errors.isEmpty, "no errors expected, got \(errors)")
            try expect(revealed.count == 1, "the finished file should be revealed once")
            let expectedName = RecordingFileNamer.url(for: fixedDate(), in: URL(fileURLWithPath: "/x")).lastPathComponent
            try expect(revealed.first?.lastPathComponent == expectedName,
                       "revealed \(revealed.first?.lastPathComponent ?? "nil"), expected \(expectedName)")
            try expect(FileManager.default.fileExists(atPath: revealed.first?.path ?? ""), "final file exists")
            try expect(!FileManager.default.fileExists(atPath: config.outputURL.path), ".part file renamed away")
        }

        testRunner("RecordingCoordinator returns to idle and reports when start fails") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.startResult = .failure(FakeError())
            var errors: [Error] = []
            var recordingFlags: [Bool] = []
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, errors: { errors.append($1) })
            coordinator.onRecordingChanged = { recordingFlags.append($0) }

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(errors.count == 1, "the failure should be presented once")
            try expect(recordingFlags.isEmpty, "status item must not enter recording mode")

            coordinator.stopRequested()
            try expect(recorder.stopCount == 0, "stop while idle is ignored")
        }

        testRunner("RecordingCoordinator does not start without screen access") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, panel: panel, screenAccess: false)

            coordinator.recordScreenRequested()
            try expect(coordinator.state == .idle, "state should stay idle")
            try expect(panel.shownOptions.isEmpty, "panel must not appear without screen access")
            try expect(recorder.startedConfigs.isEmpty, "recorder must not start")
        }

        runPanelFlowTests(testRunner)
    }

    private static func runPanelFlowTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator ✕ and Esc dismiss the panel without recording") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, panel: panel)
            try expect(panel.controlDelegate === coordinator, "coordinator handles panel actions")

            coordinator.recordScreenRequested()
            try expect(panel.isVisible && coordinator.state == .configuring, "panel shown")
            coordinator.recordControlDidCancel()
            try expect(!panel.isVisible && coordinator.state == .idle, "✕ dismisses and returns to idle")

            coordinator.recordScreenRequested()
            coordinator.recordControlDidPressEscape()
            try expect(!panel.isVisible && coordinator.state == .idle, "Esc dismisses and returns to idle")

            coordinator.recordControlDidRequestRecord()
            try expect(recorder.startedConfigs.isEmpty, "recorder never started")
            try expect(coordinator.state == .idle, "Record while idle is ignored")
        }

        testRunner("RecordingCoordinator Record hides the panel and starts with the chosen options") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, panel: panel, defaults: store.defaults)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(microphone: true, systemAudio: true))
            coordinator.recordControlDidRequestRecord()
            try expect(!panel.isVisible, "panel ordered out before capture")
            try expect(coordinator.state == .recording, "state should be recording, got \(coordinator.state)")
            guard let config = recorder.startedConfigs.first else {
                throw RecordingTestFailure(description: "recorder not started")
            }
            try expect(config.captureMic && config.captureSystemAudio, "audio options passed to the recorder")
            try expect(config.sourceRect == nil, "fullscreen has no source rect")
        }

        testRunner("RecordingCoordinator remembers the toggles across panel openings") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, panel: panel, defaults: store.defaults)

            coordinator.recordScreenRequested()
            try expect(panel.shownOptions.last?.microphone == false, "microphone starts off")
            coordinator.recordControl(didChangeOptions: RecordingOptions(microphone: true))
            coordinator.recordControlDidCancel()

            coordinator.recordScreenRequested()
            try expect(panel.shownOptions.last?.microphone == true, "microphone remembered after cancel")
            try expect(RecordingOptions.load(from: store.defaults).microphone, "saved to UserDefaults")
        }

        runSectionFlowTests(testRunner)
        runMicrophoneAccessTests(testRunner)
        runFailureTests(testRunner)
        runTerminationTests(testRunner)
    }

    private static func runMicrophoneAccessTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator turning the mic on asks for access once") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let microphone = FakeMicrophoneAccess()
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, panel: panel, defaults: store.defaults,
                microphone: microphone)

            coordinator.recordScreenRequested()
            try expect(microphone.requestCount == 0, "no prompt while the mic is off")
            coordinator.recordControl(didChangeOptions: RecordingOptions(microphone: true))
            try expect(microphone.requestCount == 1, "turning the mic on asks for access")
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .fullscreen, microphone: true,
                                                                         systemAudio: true))
            try expect(microphone.requestCount == 1, "other changes with the mic on do not ask again")
            try expect(panel.microphoneSwitch == nil && microphone.deniedAlertCount == 0, "granted: switch untouched")
            try expect(coordinator.options.microphone, "mic stays on")
        }

        testRunner("RecordingCoordinator denied mic access flips the switch off and alerts") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let microphone = FakeMicrophoneAccess()
            microphone.answer = nil
            let panel = FakeControlPanel()
            let recorder = FakeScreenRecorder()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, panel: panel, defaults: store.defaults, microphone: microphone)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(microphone: true))
            try expect(microphone.deniedAlertCount == 0, "nothing shown while the prompt is up")
            microphone.answerPrompt(false)
            try expect(panel.microphoneSwitch == false, "switch flipped off")
            try expect(microphone.deniedAlertCount == 1, "alert offering System Preferences shown once")
            try expect(!coordinator.options.microphone, "mic option off")
            try expect(!RecordingOptions.load(from: store.defaults).microphone, "off is saved")

            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .recording, "video-only recording still starts")
            try expect(recorder.startedConfigs.first?.captureMic == false, "no mic capture")
        }

        testRunner("RecordingCoordinator re-checks mic access at Record time") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            // The toggle was saved on before access was ever decided, then denied in System Preferences.
            RecordingOptions(microphone: true).save(to: store.defaults)
            let microphone = FakeMicrophoneAccess()
            microphone.answer = false
            let panel = FakeControlPanel()
            let recorder = FakeScreenRecorder()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, panel: panel, defaults: store.defaults, microphone: microphone)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(microphone.requestCount == 1, "access checked at Record")
            try expect(recorder.startedConfigs.isEmpty, "denied: recording does not start yet")
            try expect(coordinator.state == .configuring && panel.isVisible, "panel stays up")
            try expect(panel.microphoneSwitch == false && microphone.deniedAlertCount == 1, "switch off, alert shown")

            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .recording, "second Record records video only")
            try expect(recorder.startedConfigs.first?.captureMic == false, "no mic capture")
        }

        testRunner("RecordingCoordinator starts with the mic once a Record-time prompt is granted") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            RecordingOptions(microphone: true).save(to: store.defaults)
            let microphone = FakeMicrophoneAccess()
            microphone.answer = nil
            let recorder = FakeScreenRecorder()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, defaults: store.defaults, microphone: microphone)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(recorder.startedConfigs.isEmpty && coordinator.state == .configuring, "waits for the prompt")
            microphone.answerPrompt(true)
            try expect(coordinator.state == .recording, "state should be recording, got \(coordinator.state)")
            try expect(recorder.startedConfigs.first?.captureMic == true, "mic captured")
        }
        testRunner("RecordingCoordinator Section steps the overlay and panel aside while the mic prompt is up") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let microphone = FakeMicrophoneAccess()
            microphone.answer = nil
            let panel = FakeControlPanel()
            let overlay = FakeRegionOverlay()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, panel: panel, overlay: overlay,
                defaults: store.defaults, microphone: microphone)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section))
            try expect(!overlay.isSuspended && !panel.isSuspended, "nothing suspended before the prompt")
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section, microphone: true))
            try expect(overlay.isSuspended, "overlay hidden so the system prompt is clickable")
            try expect(panel.isSuspended, "panel dropped below the system prompt")
            microphone.answerPrompt(true)
            try expect(!overlay.isSuspended && !panel.isSuspended, "both restored after the answer")
            try expect(coordinator.state == .selecting && overlay.isVisible, "still selecting a section")
        }

        testRunner("RecordingCoordinator does not suspend anything when mic access is already decided") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let panel = FakeControlPanel()
            let overlay = FakeRegionOverlay()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, panel: panel, overlay: overlay,
                defaults: store.defaults)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section))
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section, microphone: true))
            try expect(!overlay.isSuspended && !panel.isSuspended, "no prompt, no suspension")
        }
    }

    private static func runSectionFlowTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator Section shows the overlay and disables Record until a drag") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let overlay = FakeRegionOverlay()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, panel: panel, overlay: overlay, defaults: store.defaults)
            try expect(overlay.selectionDelegate === coordinator, "coordinator handles overlay results")

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section))
            try expect(coordinator.state == .selecting, "state should be selecting, got \(coordinator.state)")
            try expect(overlay.isVisible, "overlay shown")
            try expect(!panel.recordEnabled, "Record disabled until a region exists")

            coordinator.recordControlDidRequestRecord()
            try expect(recorder.startedConfigs.isEmpty && coordinator.state == .selecting,
                       "Record without a region is ignored")

            // Drag from (100, 100) to (741, 501) in AppKit points on the 1280×800 Retina screen.
            coordinator.regionSelection(
                didSelect: CGRect(x: 100, y: 100, width: 641, height: 401), on: retinaScreen)
            try expect(panel.recordEnabled, "Record enabled after a drag")
            coordinator.regionSelectionDidClear()
            try expect(!panel.recordEnabled, "a new drag disables Record again")
            coordinator.regionSelection(
                didSelect: CGRect(x: 100, y: 100, width: 641, height: 401), on: retinaScreen)

            coordinator.recordControlDidRequestRecord()
            try expect(!overlay.isVisible && !panel.isVisible, "overlay and panel ordered out")
            try expect(coordinator.state == .recording, "state should be recording, got \(coordinator.state)")
            guard let config = recorder.startedConfigs.first else {
                throw RecordingTestFailure(description: "recorder not started")
            }
            try expect(config.displayID == 7, "records the screen where the drag began")
            try expect(config.pixelSize == CGSize(width: 1282, height: 802),
                       "odd 641×401 pt at 2× is 1282×802 px, got \(config.pixelSize)")
            try expect(config.sourceRect == CGRect(x: 100, y: 299, width: 641, height: 401),
                       "top-left origin source rect, got \(String(describing: config.sourceRect))")
        }

        testRunner("RecordingCoordinator keeps and reveals the file when writing fails mid-recording") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let recorder = FakeScreenRecorder()
            var revealed: [URL] = []
            var alerts: [(String, Error)] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, defaults: store.defaults,
                revealed: { revealed.append($0) }, errors: { alerts.append(($0, $1)) })

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            guard let part = recorder.startedConfigs.last?.outputURL else {
                throw RecordingTestFailure(description: "not started")
            }
            recorder.stopError = RecordingError.recordingIncomplete(url: part, reason: "disk full")
            recorder.interrupt(RecordingError.writerFailed("disk full"))

            try expect(coordinator.state == .idle, "back to idle, got \(coordinator.state)")
            try expect(revealed.count == 1 && revealed[0].pathExtension == "mp4", "kept file revealed: \(revealed)")
            try expect(FileManager.default.fileExists(atPath: revealed[0].path), "kept file exists")
            try expect(!FileManager.default.fileExists(atPath: part.path), ".part renamed, not deleted")
            try expect(alerts.count == 1, "exactly one alert, got \(alerts.count)")
            try expect(alerts[0].0.hasPrefix("Recording stopped"), "alert explains the stop: \(alerts[0].0)")
        }

        testRunner("RecordingRecovery renames idle leftovers, skips active ones and removes empty ones") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let fm = FileManager.default
            let now = Date()
            func make(_ name: String, bytes: Int, age: TimeInterval) -> URL {
                let url = folder.appendingPathComponent(name)
                fm.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
                try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
                return url
            }
            _ = make(".Screen Recording A.mp4.part", bytes: 100, age: 3600)
            let active = make(".Screen Recording B.mp4.part", bytes: 100, age: 1)
            let empty = make(".Screen Recording C.mp4.part", bytes: 0, age: 3600)
            _ = make("Screen Recording A (recovered).mp4", bytes: 5, age: 3600)
            let unrelated = make("notes.txt.part", bytes: 10, age: 3600)

            let recovered = RecordingRecovery.recoverUnfinished(in: folder, now: now)
            try expect(recovered.map { $0.lastPathComponent } == ["Screen Recording A (recovered) 2.mp4"],
                       "idle leftover gets a unique visible name: \(recovered.map { $0.lastPathComponent })")
            try expect(fm.fileExists(atPath: active.path), "a file still being written is left alone")
            try expect(!fm.fileExists(atPath: empty.path), "empty leftovers are removed")
            try expect(fm.fileExists(atPath: unrelated.path), "unrelated files untouched")
            try expect(RecordingRecovery.finalName(forPartFile: "Screen Recording.mp4") == nil, "only .part files")
        }

        testRunner("RecordingCoordinator outlines the section while it records, not fullscreen") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let outline = FakeOutline()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, outline: outline, defaults: store.defaults)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section))
            let rect = CGRect(x: 10, y: 10, width: 200, height: 100)
            coordinator.regionSelection(didSelect: rect, on: retinaScreen)
            try expect(outline.shown == nil, "no outline before recording")
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .recording, "recording, got \(coordinator.state)")
            try expect(outline.shown == rect, "outline around the captured area, got \(String(describing: outline.shown))")
            coordinator.stopRequested()
            try expect(outline.shown == nil && outline.hideCount >= 1, "outline hidden when the recording ends")

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .fullscreen))
            coordinator.recordControlDidRequestRecord()
            try expect(outline.shown == nil, "fullscreen has no outline")
        }

        testRunner("SelectionEditing finds handles, moves within the screen and resizes with a minimum") {
            let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
            let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
            let handle = { SelectionEditing.handle(at: $0, in: rect) }
            try expect(handle(CGPoint(x: 200, y: 150)) == .inside, "middle moves")
            try expect(handle(CGPoint(x: 100, y: 150)) == .left, "left edge")
            try expect(handle(CGPoint(x: 304, y: 150)) == .right, "just outside the right edge still grabs it")
            try expect(handle(CGPoint(x: 200, y: 200)) == .top, "top is maxY in AppKit coordinates")
            try expect(handle(CGPoint(x: 101, y: 199)) == .topLeft, "top-left corner")
            try expect(handle(CGPoint(x: 299, y: 101)) == .bottomRight, "bottom-right corner")
            try expect(handle(CGPoint(x: 50, y: 150)) == nil, "outside starts a new selection")

            let moved = SelectionEditing.apply(.inside, to: rect, delta: CGVector(dx: 2000, dy: -500),
                                               bounds: bounds, minSize: 16)
            try expect(moved == CGRect(x: 1080, y: 0, width: 200, height: 100), "move slides along the edges: \(moved)")
            let wider = SelectionEditing.apply(.right, to: rect, delta: CGVector(dx: 50, dy: 30),
                                               bounds: bounds, minSize: 16)
            try expect(wider == CGRect(x: 100, y: 100, width: 250, height: 100), "right edge only changes width: \(wider)")
            let corner = SelectionEditing.apply(.topLeft, to: rect, delta: CGVector(dx: -20, dy: 10),
                                                bounds: bounds, minSize: 16)
            try expect(corner == CGRect(x: 80, y: 100, width: 220, height: 110), "corner moves two edges: \(corner)")
            let tiny = SelectionEditing.apply(.right, to: rect, delta: CGVector(dx: -195, dy: 0),
                                              bounds: bounds, minSize: 16)
            try expect(tiny.width == 16 && tiny.minX == 100, "never narrower than the minimum: \(tiny)")
            let flipped = SelectionEditing.apply(.right, to: rect, delta: CGVector(dx: -300, dy: 0),
                                                 bounds: bounds, minSize: 16)
            try expect(flipped == CGRect(x: 0, y: 100, width: 100, height: 100), "dragging past the other edge flips: \(flipped)")
            let clamped = SelectionEditing.apply(.top, to: rect, delta: CGVector(dx: 0, dy: 5000),
                                                 bounds: bounds, minSize: 16)
            try expect(clamped.maxY == 800, "resizing stops at the screen edge: \(clamped)")
        }

        testRunner("RecordingOutlineWindow gradient repeats exactly, so the one-period scroll is seamless") {
            let bands = RecordingOutlineWindow.repeatedBands(periods: 4)
            let perPeriod = RecordingOutlineWindow.bandColors.count
            try expect(bands.colors.count == 4 * perPeriod + 1 && bands.locations.count == bands.colors.count,
                       "whole periods plus a closing stop")
            try expect(bands.locations.first == 0 && bands.locations.last == 1, "spans the layer")
            for i in 0..<perPeriod {
                let a = bands.locations[i].doubleValue, b = bands.locations[i + perPeriod].doubleValue
                try expect(abs((b - a) - 0.25) < 1e-9, "every period has the same width")
                try expect(bands.colors[i] == bands.colors[i + perPeriod], "every period has the same colours")
            }
            try expect(bands.colors.last == bands.colors.first, "the last period closes into the next one")
            try expect(abs(RecordingOutlineWindow.axisAngle - (-20 * .pi / 180)) < 1e-9, "70° bands → −20° axis")
        }

        testRunner("RecordingOutlineWindow animates while shown (even with Reduce Motion) and stops when hidden") {
            let outline = RecordingOutlineWindow()
            outline.show(around: CGRect(x: 100, y: 100, width: 300, height: 200))
            try expect(outline.isAnimating && outline.isStepping, "shimmer runs while recording")
            outline.simulateOcclusion(visible: false)
            try expect(outline.isAnimating && !outline.isStepping, "no stepping while it cannot be seen")
            outline.simulateOcclusion(visible: true)
            try expect(outline.isStepping, "resumes when visible again")
            outline.hide()
            try expect(!outline.isAnimating && !outline.isStepping, "stops when hidden")
            outline.simulateOcclusion(visible: true)
            try expect(!outline.isStepping, "an occlusion change after hiding does not restart it")
        }

        testRunner("RecordingOutlineWindow tiles a sharp 1-pixel ring just outside the gap") {
            try expect(RecordingOutlineWindow.lineWidth(scale: 2) == 0.5, "1 px on Retina is 0.5 pt")
            try expect(RecordingOutlineWindow.lineWidth(scale: 1) == 1, "1 px on a standard display")
            let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
            let outer = RecordingOutlineWindow.frame(around: rect, scale: 2)
            try expect(outer == rect.insetBy(dx: -2.5, dy: -2.5), "gap 2 pt + 1 px line: \(outer)")
            let edges = RecordingOutlineWindow.edgeRects(around: rect, scale: 2)
            try expect(edges.count == 4, "four edges")
            for edge in edges {
                try expect(min(edge.width, edge.height) == 0.5, "each edge is one pixel thick: \(edge)")
                try expect(!edge.intersects(rect), "no edge touches the captured area")
                try expect(outer.contains(edge), "edges stay within the outline")
            }
            // The edges tile the ring exactly: area = outer − inner, no overlaps, so corners are square.
            let ring = outer.width * outer.height - (outer.width - 1) * (outer.height - 1)
            let total = edges.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            try expect(abs(total - ring) < 1e-9, "edges cover the ring once: \(total) vs \(ring)")
            for i in 0..<4 { for j in (i + 1)..<4 {
                try expect(edges[i].intersection(edges[j]).isEmpty, "edges \(i) and \(j) do not overlap")
            } }
        }

        testRunner("RecordingOutlineWindow edge gradients follow one global 70° pattern, so bands meet at corners") {
            func phase(at s: CGFloat, origin: CGPoint, direction: CGVector) -> CGFloat {
                RecordingOutlineWindow.phase(at: CGPoint(x: origin.x + direction.dx * s, y: origin.y + direction.dy * s))
            }
            for (origin, direction, length) in [
                (CGPoint(x: 0, y: 0), CGVector(dx: 1, dy: 0), CGFloat(905)),   // bottom
                (CGPoint(x: 0, y: 504.5), CGVector(dx: 1, dy: 0), CGFloat(905)), // top
                (CGPoint(x: 0, y: 0.5), CGVector(dx: 0, dy: 1), CGFloat(504)),  // left (phase falls with y)
                (CGPoint(x: 904.5, y: 0.5), CGVector(dx: 0, dy: 1), CGFloat(504))
            ] {
                let g = RecordingOutlineWindow.edgeGradient(origin: origin, direction: direction, length: length)
                let wavelength = abs(g.shift)
                // Covers the edge before and after sliding one wavelength.
                try expect(g.start <= min(0, -g.shift) + 1e-9 && g.end >= length + max(0, -g.shift) - 1e-9 &&
                           g.start + wavelength * 0 <= 0, "covers the edge throughout the slide: \(g)")
                try expect(min(g.start, g.start + g.shift) <= 1e-9 && max(g.end, g.end + g.shift) >= length - 1e-9,
                           "still covers after sliding: \(g)")
                try expect(abs((g.end - g.start) - CGFloat(g.periods) * wavelength) < 1e-6, "whole periods")
                // The gradient's first colour sits on a whole period of the global pattern.
                let anchor = g.reversed ? g.end : g.start
                let p = phase(at: anchor, origin: origin, direction: direction)
                try expect(abs(p - p.rounded()) < 1e-6, "anchored on a whole period: phase \(p)")
                // Sliding by `shift` advances the pattern by exactly one period along this edge.
                let step = phase(at: anchor + g.shift, origin: origin, direction: direction) - p
                try expect(abs(abs(step) - 1) < 1e-6, "one-period slide, got \(step)")
                // Colours run in increasing phase from the anchor.
                let ahead = phase(at: anchor + (g.reversed ? -1 : 1), origin: origin, direction: direction)
                try expect(ahead > p, "colour order follows the pattern")
            }
        }

        testRunner("RecordingOutlineWindow frame leaves the captured area untouched") {
            let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
            let frame = RecordingOutlineWindow.frame(around: rect)
            try expect(frame.contains(rect), "outline window surrounds the area")
            try expect(frame.minX < rect.minX - RecordingOutlineWindow.gap, "line starts outside the gap")
        }

        testRunner("RecordingCoordinator Esc in Section returns to Fullscreen, Esc again cancels") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let overlay = FakeRegionOverlay()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, panel: panel, overlay: overlay, defaults: store.defaults)

            coordinator.recordScreenRequested()
            coordinator.recordControl(didChangeOptions: RecordingOptions(area: .section))
            coordinator.regionSelection(didSelect: CGRect(x: 10, y: 10, width: 200, height: 100), on: retinaScreen)

            coordinator.recordControlDidPressEscape()
            try expect(coordinator.state == .configuring, "first Esc returns to configuring")
            try expect(!overlay.isVisible, "first Esc hides the overlay")
            try expect(panel.area == .fullscreen && panel.isVisible, "panel switched back to Fullscreen")
            try expect(panel.recordEnabled, "Fullscreen can record right away")
            try expect(RecordingOptions.load(from: store.defaults).area == .fullscreen, "Fullscreen saved")

            coordinator.recordControlDidPressEscape()
            try expect(coordinator.state == .idle && !panel.isVisible, "second Esc cancels the panel")
            try expect(recorder.startedConfigs.isEmpty, "nothing recorded")
        }

        testRunner("RecordingCoordinator reopens in Section mode with the overlay when last used") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TestDefaults()
            defer { store.cleanup() }
            RecordingOptions(area: .section).save(to: store.defaults)
            let panel = FakeControlPanel()
            let overlay = FakeRegionOverlay()
            let coordinator = makeCoordinator(
                recorder: FakeScreenRecorder(), folder: folder, panel: panel, overlay: overlay,
                defaults: store.defaults)

            coordinator.recordScreenRequested()
            try expect(coordinator.state == .selecting && overlay.isVisible, "Section restored with overlay")
            try expect(panel.area == .section && !panel.recordEnabled, "panel shows Section, Record disabled")

            coordinator.recordControlDidCancel()
            try expect(coordinator.state == .idle && !overlay.isVisible && !panel.isVisible,
                       "✕ removes both the overlay and the panel")
        }

        testRunner("RecordingCoordinator Fullscreen records the display under the mouse") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            let external = ScreenInfo(id: 9, frame: CGRect(x: 1280, y: 0, width: 1920, height: 1080), scale: 1)
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, screens: [retinaScreen, external],
                mouse: CGPoint(x: 2000, y: 500))

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            guard let config = recorder.startedConfigs.first else {
                throw RecordingTestFailure(description: "recorder not started")
            }
            try expect(config.displayID == 9 && config.sourceRect == nil, "whole external display")
            try expect(config.pixelSize == CGSize(width: 1920, height: 1080), "1× display at native pixels")
        }

        testRunner("RecordingCoordinator reports no display and returns to idle") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            var errors: [Error] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, screens: [], errors: { errors.append($1) })

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(recorder.startedConfigs.isEmpty, "recorder not started")
            try expect((errors.first as? RecordingError) == .noDisplay, "noDisplay presented")
        }
    }

    // MARK: - Failures

    /// Collects every alert the coordinator presents.
    private final class AlertLog {
        var messages: [String] = []
        var errors: [Error] = []
        var screenAccessAlerts = 0
        var count: Int { return messages.count + screenAccessAlerts }
        func present(_ message: String, _ error: Error) {
            messages.append(message)
            errors.append(error)
        }
    }

    private static func runFailureTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator shows the Screen Recording alert when capture is denied at start") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.startResult = .failure(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                                                    code: -3801))
            let alerts = AlertLog()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, errors: alerts.present,
                screenAccessDenied: { alerts.screenAccessAlerts += 1 })

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(alerts.screenAccessAlerts == 1 && alerts.count == 1, "only the permission alert, once")
            try expect(files(in: folder).isEmpty, "no files left behind: \(files(in: folder))")
        }

        testRunner("RecordingCoordinator returns to the panel when the display went away before Record") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.startResult = .failure(RecordingError.displayNotFound)
            let panel = FakeControlPanel()
            let alerts = AlertLog()
            var recordingFlags: [Bool] = []
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, panel: panel, errors: alerts.present)
            coordinator.onRecordingChanged = { recordingFlags.append($0) }

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .configuring, "back to configuring, got \(coordinator.state)")
            try expect(panel.isVisible && panel.recordEnabled, "panel shown again, ready to record")
            try expect(alerts.count == 1, "the failure is presented once, got \(alerts.count)")
            try expect((alerts.errors.first as? RecordingError) == .displayNotFound, "displayNotFound presented")
            try expect(recordingFlags.isEmpty, "status item never entered recording mode")

            recorder.startResult = .success(())
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .recording, "a second Record works, got \(coordinator.state)")
        }

        testRunner("RecordingCoordinator alerts and stays idle when the recordings folder cannot be created") {
            let parent = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: parent) }
            // A regular file where a folder is needed makes createDirectory throw.
            let blocker = parent.appendingPathComponent("KapKap")
            FileManager.default.createFile(atPath: blocker.path, contents: Data())
            let recorder = FakeScreenRecorder()
            let alerts = AlertLog()
            let coordinator = makeCoordinator(
                recorder: recorder, folder: blocker.appendingPathComponent("Recordings", isDirectory: true),
                errors: alerts.present)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(recorder.startedConfigs.isEmpty, "recorder not started")
            try expect(alerts.count == 1 && alerts.messages.first == "Could not create the recordings folder.",
                       "folder alert presented once: \(alerts.messages)")
        }

        testRunner("RecordingCoordinator salvages, reveals and alerts when capture stops mid-recording") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            let alerts = AlertLog()
            var revealed: [URL] = []
            var recordingFlags: [Bool] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, revealed: { revealed.append($0) }, errors: alerts.present)
            coordinator.onRecordingChanged = { recordingFlags.append($0) }

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            recorder.interrupt(DescribedError("The display was disconnected."))
            try expect(recorder.stopCount == 1, "the recorder is stopped to finish the file")
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(recordingFlags == [true, false], "icon returns to normal")
            try expect(revealed.count == 1 && FileManager.default.fileExists(atPath: revealed[0].path),
                       "the partial recording is saved and revealed")
            try expect(alerts.count == 1, "presented once, got \(alerts.count)")
            try expect(alerts.messages.first == "Recording stopped: The display was disconnected.",
                       "alert names the reason: \(alerts.messages)")
            try expect(!files(in: folder).contains { $0.hasSuffix(".part") }, "no .part left: \(files(in: folder))")

            recorder.interrupt(FakeError())
            coordinator.stopRequested()
            try expect(recorder.stopCount == 1 && alerts.count == 1, "late failures and stops are ignored when idle")
        }

        testRunner("RecordingCoordinator deletes .part and alerts once when salvage fails after an interruption") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.stopError = RecordingError.writerFailed("The disk is full.")
            let alerts = AlertLog()
            var revealed: [URL] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, revealed: { revealed.append($0) }, errors: alerts.present)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            recorder.interrupt(RecordingError.writerFailed("The disk is full."))
            recorder.interrupt(RecordingError.writerFailed("The disk is full."))
            try expect(recorder.stopCount == 1, "stopped once despite two reports")
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(alerts.count == 1 && alerts.messages.first == "The recording could not be saved.",
                       "one save-failure alert: \(alerts.messages)")
            try expect(revealed.isEmpty, "nothing revealed")
            try expect(files(in: folder).isEmpty, ".part deleted: \(files(in: folder))")
        }

        testRunner("RecordingCoordinator deletes .part and alerts once when finishing fails") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.stopError = RecordingError.writerFailed("Encoder error.")
            let alerts = AlertLog()
            var revealed: [URL] = []
            var recordingFlags: [Bool] = []
            let coordinator = makeCoordinator(
                recorder: recorder, folder: folder, revealed: { revealed.append($0) }, errors: alerts.present)
            coordinator.onRecordingChanged = { recordingFlags.append($0) }

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            coordinator.stopRequested()
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(recordingFlags == [true, false], "icon returns to normal")
            try expect(alerts.count == 1, "presented once, got \(alerts.count)")
            try expect((alerts.errors.first as? RecordingError) == .writerFailed("Encoder error."), "writer error shown")
            try expect(revealed.isEmpty, "nothing revealed")
            try expect(files(in: folder).isEmpty, ".part deleted: \(files(in: folder))")
        }
    }

    // MARK: - Quitting

    private static func runTerminationTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RecordingCoordinator quit while recording stops and finishes the file before replying") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.defersStop = true
            var revealed: [URL] = []
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, revealed: { revealed.append($0) })

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            var replies = 0
            let mustWait = coordinator.finishForTermination { replies += 1 }
            try expect(mustWait, "quit waits while recording")
            try expect(recorder.stopCount == 1, "quit stops the recorder")
            try expect(coordinator.state == .finishing && replies == 0, "no reply before the file is finished")

            recorder.completeStop()
            try expect(replies == 1, "reply once the file is finished, got \(replies)")
            try expect(coordinator.state == .idle, "state should be idle, got \(coordinator.state)")
            try expect(revealed.count == 1 && FileManager.default.fileExists(atPath: revealed[0].path),
                       "the file is finalized")
        }

        testRunner("RecordingCoordinator quit while finishing waits for the file") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.defersStop = true
            let coordinator = makeCoordinator(recorder: recorder, folder: folder)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            coordinator.stopRequested()
            var replies = 0
            try expect(coordinator.finishForTermination { replies += 1 }, "quit waits while finishing")
            try expect(recorder.stopCount == 1, "not stopped twice")
            recorder.completeStop()
            try expect(replies == 1, "reply after finishing, got \(replies)")
        }

        testRunner("RecordingCoordinator quit while starting stops as soon as capture is up") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            recorder.defersStart = true
            let coordinator = makeCoordinator(recorder: recorder, folder: folder)

            coordinator.recordScreenRequested()
            coordinator.recordControlDidRequestRecord()
            try expect(coordinator.state == .starting, "state should be starting, got \(coordinator.state)")
            var replies = 0
            try expect(coordinator.finishForTermination { replies += 1 }, "quit waits while starting")
            recorder.completeStart()
            try expect(recorder.stopCount == 1, "stopped once capture started")
            try expect(replies == 1 && coordinator.state == .idle, "reply after the file is finished")
        }

        testRunner("RecordingCoordinator quit when not recording lets the app quit at once") {
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recorder = FakeScreenRecorder()
            let panel = FakeControlPanel()
            let coordinator = makeCoordinator(recorder: recorder, folder: folder, panel: panel)

            var replies = 0
            try expect(!coordinator.finishForTermination { replies += 1 }, "idle quits now")
            coordinator.recordScreenRequested()
            try expect(!coordinator.finishForTermination { replies += 1 }, "configuring quits now")
            try expect(!panel.isVisible && coordinator.state == .idle, "the panel is dismissed")
            try expect(replies == 0 && recorder.stopCount == 0, "nothing to wait for")
        }
    }
}
