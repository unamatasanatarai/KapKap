import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Captures one display and writes H.264 video into an `.mp4` with `AVAssetWriter`. macOS 13+ captures with
/// ScreenCaptureKit; macOS 12 uses `CGDisplayStream`, because ScreenCaptureKit there can start "successfully"
/// and then deliver no frames at all (seen on 12.7.6, also by the sibling Recall app).
/// With the microphone and/or system audio (macOS 13+) on, audio goes through `AudioMixer` into one AAC track.
/// All capture, mixer and writer state is confined to `captureQueue`; completions are delivered on the main queue.
public final class ScreenRecorder: NSObject, ScreenRecording {
    private let captureQueue = DispatchQueue(label: "\(AppConfig.bundleIdentifier).screen-capture")

    /// Set and called on the main queue.
    public var onInterruption: ((Error) -> Void)?

    private var stream: SCStream?
    /// The macOS 12 capture backend; see `usesDisplayStream`.
    private var displayStream: CGDisplayStream?
    /// Bumped per display stream so a stopped stream's late frames never reach a newer recording.
    private var displayStreamGeneration = 0
    /// `stop` was requested: frames still in flight must not be appended while the writer finishes.
    private var videoStopping = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var mixer: AudioMixer?
    private var microphone: MicrophoneCapture?
    private var outputURL: URL?
    private var sessionStarted = false
    private var lastSampleBuffer: CMSampleBuffer?
    private var lastPresentationTime: CMTime = .invalid
    /// The stream stopped on its own (SCStreamDelegate); `stop` must not call `stopCapture` again.
    private var streamStopped = false
    /// An interruption was reported for the current recording; report only the first.
    private var interruptionReported = false
    /// Mixed audio the writer was not ready for, retried before newer audio (bounded, oldest dropped).
    private var pendingAudio: [CMSampleBuffer] = []
    private var droppedAudioChunks = 0
    /// Polls free disk space while recording.
    private var diskMonitor: DispatchSourceTimer?
    /// Free bytes on the volume holding a URL (injectable for tests).
    private let freeSpace: (URL) -> Int64?

    public init(freeSpace: @escaping (URL) -> Int64? = ScreenRecorder.availableCapacity) {
        self.freeSpace = freeSpace
        super.init()
    }

    // MARK: - Disk space

    /// A recording does not start with less free space than this.
    public static let minimumFreeSpaceToStart: Int64 = 1_000_000_000
    /// A running recording is stopped and saved when free space drops below this.
    public static let minimumFreeSpaceWhileRecording: Int64 = 300_000_000
    static let diskCheckInterval: TimeInterval = 5
    /// At most this much mixed audio waits for the writer before the oldest chunk is dropped.
    static let maxPendingAudioChunks = 50

    /// Free bytes for new data on the volume holding `url`. "Important usage" capacity (which counts
    /// purgeable space) is preferred, but some volumes, such as HFS+ disk images and drives, report 0
    /// for it; then the plain free capacity is used.
    public static func availableCapacity(for url: URL) -> Int64? {
        let folder = url.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        return chooseCapacity(important: values?.volumeAvailableCapacityForImportantUsage,
                              plain: values?.volumeAvailableCapacity.map(Int64.init))
    }

    static func chooseCapacity(important: Int64?, plain: Int64?) -> Int64? {
        if let important = important, important > 0 {
            return important
        }
        return plain
    }

    /// Throws when there is not enough room to start. Unknown free space does not block recording.
    func checkFreeSpaceToStart(_ url: URL) throws {
        if let available = freeSpace(url), available < Self.minimumFreeSpaceToStart {
            throw RecordingError.notEnoughDiskSpace(availableBytes: available)
        }
    }

    /// Runs on `captureQueue` after capture starts; stops the recording before the disk fills.
    private func startDiskMonitor(_ url: URL) {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + Self.diskCheckInterval, repeating: Self.diskCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.writer != nil, !self.interruptionReported else { return }
            if let available = self.freeSpace(url), available < Self.minimumFreeSpaceWhileRecording {
                NSLog("%@ stopping: only %lld bytes free", AppConfig.appName, available)
                self.reportInterruption(RecordingError.diskAlmostFull)
            }
        }
        timer.resume()
        diskMonitor = timer
    }

    // MARK: - ScreenRecording

    /// How long `start` waits for ScreenCaptureKit before giving up. The capture daemon (replayd) can
    /// wedge and never answer, which would otherwise leave the app stuck in "starting".
    public static let startTimeout: TimeInterval = 10
    /// How long `stop` waits for ScreenCaptureKit before finalizing writing anyway.
    public static let stopTimeout: TimeInterval = 6

    /// CGDisplayStream on macOS 12, ScreenCaptureKit on 13+ (which system audio needs anyway).
    public static var usesDisplayStream: Bool {
        if #available(macOS 13, *) { return false }
        return true
    }

    public func start(_ config: RecordingConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        // `finish` runs at most once (on `captureQueue`); a timeout and a late answer race for it.
        var finished = false
        let finish: (Result<Void, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { completion(result) }
        }
        if Self.usesDisplayStream {
            captureQueue.async {
                self.startDisplayStream(config, finish: finish)
            }
            return
        }
        captureQueue.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard !finished else { return }
            NSLog("%@ screen capture did not start within %.0f s", AppConfig.appName, Self.startTimeout)
            if let stream = self?.stream {
                stream.stopCapture { _ in }
            }
            self?.displayStream?.stop()
            self?.discardOutput()
            finish(.failure(RecordingError.captureServiceNotResponding))
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            self.captureQueue.async {
                guard !finished else { return }
                if let error = error {
                    finish(.failure(error))
                    return
                }
                guard self.stream == nil else {
                    finish(.failure(RecordingError.alreadyRecording))
                    return
                }
                guard let content = content,
                      let display = content.displays.first(where: { $0.displayID == config.displayID }) else {
                    finish(.failure(RecordingError.displayNotFound))
                    return
                }

                do {
                    try self.checkFreeSpaceToStart(config.outputURL)
                    try self.prepareWriter(config)
                    if config.captureMic {
                        try self.startMicrophone()
                    }
                } catch {
                    self.discardOutput()
                    finish(.failure(error))
                    return
                }

                // Exclude our own windows as a safety net; the app normally shows none while recording.
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let streamConfig = Self.streamConfiguration(config)
                NSLog("%@ capture display %u (%d×%d pt) sourceRect %@ output %d×%d", AppConfig.appName,
                      display.displayID, display.width, display.height,
                      config.sourceRect.map { NSStringFromRect($0) } ?? "full", streamConfig.width, streamConfig.height)
                let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                    // System audio is delivered on `captureQueue` too, so the mixer stays confined to it.
                    if #available(macOS 13, *), config.captureSystemAudio {
                        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.captureQueue)
                    }
                } catch {
                    self.discardOutput()
                    finish(.failure(error))
                    return
                }
                self.stream = stream

                stream.startCapture { [weak self] error in
                    guard let self = self else { return }
                    self.captureQueue.async {
                        // Timed out meanwhile: the stream was already stopped and the output discarded.
                        guard !finished, stream === self.stream else { return }
                        if let error = error {
                            self.discardOutput()
                            finish(.failure(error))
                        } else {
                            // No seed frame here: CGDisplayCreateImage is deprecated on macOS 14 and
                            // triggers legacy-capture prompts on macOS 15; ScreenCaptureKit on 13+
                            // delivers a complete first frame itself.
                            self.startDiskMonitor(config.outputURL)
                            finish(.success(()))
                        }
                    }
                }
            }
        }
    }

    public func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        let finish: (Result<URL, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        // SCK stamps frames on the host clock; the stop request time marks the end of the recording.
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())

        captureQueue.async {
            self.videoStopping = true
            if let displayStream = self.displayStream {
                self.stopMicrophone()
                if !self.streamStopped {
                    displayStream.stop()
                }
                self.finishWriting(at: stopTime, completion: finish)
                return
            }
            guard let stream = self.stream else {
                finish(.failure(RecordingError.notRecording))
                return
            }
            // Stop the mic first so no audio arrives after the stop time.
            self.stopMicrophone()
            if self.streamStopped {
                // Salvage after the stream died: finish with the frames captured so far.
                self.finishWriting(at: stopTime, completion: finish)
                return
            }

            var finishedWriting = false
            let performFinish: () -> Void = { [weak self] in
                guard let self = self, !finishedWriting else { return }
                finishedWriting = true
                self.finishWriting(at: stopTime, completion: finish)
            }

            self.captureQueue.asyncAfter(deadline: .now() + Self.stopTimeout) {
                guard !finishedWriting else { return }
                NSLog("%@ screen capture did not stop within %.0f s; finishing recording", AppConfig.appName, Self.stopTimeout)
                performFinish()
            }

            stream.stopCapture { [weak self] _ in
                guard let self = self else { return }
                self.captureQueue.async {
                    performFinish()
                }
            }
        }
    }

    // MARK: - CGDisplayStream (macOS 12)

    /// Runs on `captureQueue`.
    private func startDisplayStream(_ config: RecordingConfig, finish: @escaping (Result<Void, Error>) -> Void) {
        guard stream == nil, displayStream == nil else {
            finish(.failure(RecordingError.alreadyRecording))
            return
        }
        do {
            try checkFreeSpaceToStart(config.outputURL)
            try prepareWriter(config)
            if config.captureMic {
                try startMicrophone()
            }
        } catch {
            discardOutput()
            finish(.failure(error))
            return
        }

        displayStreamGeneration += 1
        let generation = displayStreamGeneration
        let width = Int(config.pixelSize.width)
        let height = Int(config.pixelSize.height)
        NSLog("%@ CGDisplayStream capture of display %u, sourceRect %@, output %d×%d", AppConfig.appName,
              config.displayID, config.sourceRect.map { NSStringFromRect($0) } ?? "full", width, height)
        let created = CGDisplayStream(
            dispatchQueueDisplay: config.displayID,
            outputWidth: width,
            outputHeight: height,
            // Bi-planar 4:2:0, the encoder's native input: about 40% of BGRA's bytes per frame and
            // no colour conversion before H.264 encoding.
            pixelFormat: Int32(Self.displayStreamPixelFormat),
            properties: Self.displayStreamProperties(config) as CFDictionary,
            queue: captureQueue
        ) { [weak self] status, displayTime, surface, _ in
            // Runs on `captureQueue`.
            guard let self = self, generation == self.displayStreamGeneration, !self.videoStopping else { return }
            switch status {
            case .frameComplete:
                guard let surface = surface,
                      let pixelBuffer = Self.retainedPixelBuffer(for: surface),
                      let sampleBuffer = Self.sampleBuffer(
                        from: pixelBuffer, at: CMClockMakeHostTimeFromSystemUnits(displayTime)) else { return }
                self.appendVideo(sampleBuffer)
            case .stopped:
                // Not requested by `stop`: the display was reconfigured or went away.
                self.streamStopped = true
                self.stopMicrophone()
                self.reportInterruption(RecordingError.displayNotFound)
            default:
                break
            }
        }
        guard let displayStream = created else {
            discardOutput()
            finish(.failure(RecordingError.writerFailed("The screen capture stream could not be created.")))
            return
        }
        let result = displayStream.start()
        guard result == .success else {
            discardOutput()
            finish(.failure(RecordingError.writerFailed("Screen capture could not start (error \(result.rawValue)).")))
            return
        }
        self.displayStream = displayStream
        // CGDisplayStream (like ScreenCaptureKit on 12.x) only delivers a frame when the area changes,
        // so seed the video with a still: a static area still yields a recording of the right length.
        appendSeedFrame(config)
        startDiskMonitor(config.outputURL)
        finish(.success(()))
    }

    static let displayStreamPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static func displayStreamProperties(_ config: RecordingConfig) -> [CFString: Any] {
        var properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: (1.0 / 60.0) as CFNumber,
            CGDisplayStream.showCursor: kCFBooleanTrue as Any,
            CGDisplayStream.queueDepth: 6 as CFNumber,
            CGDisplayStream.preserveAspectRatio: kCFBooleanFalse as Any
        ]
        if let sourceRect = config.sourceRect {
            // Display-relative points with a top-left origin, like `RecordingConfig.sourceRect`.
            properties[CGDisplayStream.sourceRect] = sourceRect.dictionaryRepresentation
        }
        return properties
    }

    /// Wraps `surface` without copying. The stream recycles a surface once the handler returns unless
    /// its use count is raised, and the encoder reads frames later, so the count is held until the
    /// pixel buffer is released (same approach as Recall's DisplayStreamSource).
    private static func retainedPixelBuffer(for surface: IOSurfaceRef) -> CVPixelBuffer? {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanaged) == kCVReturnSuccess,
              let pixelBuffer = unmanaged?.takeRetainedValue() else {
            return nil
        }
        IOSurfaceIncrementUseCount(surface)
        CVBufferSetAttachment(pixelBuffer, SurfaceUseToken.attachmentKey, SurfaceUseToken(surface: surface),
                              .shouldNotPropagate)
        return pixelBuffer
    }

    // MARK: - Setup

    private static func streamConfiguration(_ config: RecordingConfig) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(config.pixelSize.width)
        cfg.height = Int(config.pixelSize.height)
        if let sourceRect = config.sourceRect {
            cfg.sourceRect = sourceRect
        }
        cfg.showsCursor = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 6
        if #available(macOS 13, *), config.captureSystemAudio {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = Int(AudioMixer.sampleRate)
            cfg.channelCount = 2
        }
        return cfg
    }

    private func prepareWriter(_ config: RecordingConfig) throws {
        let url = config.outputURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let width = Int(config.pixelSize.width)
        let height = Int(config.pixelSize.height)
        let writer = try Self.makeWriter(url: url)
        let settings = Self.videoSettings(width: width, height: height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingError.writerFailed("The video input could not be added.")
        }
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        var mixer: AudioMixer?
        let sources = Self.audioSources(for: config)
        if !sources.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("The audio input could not be added.")
            }
            writer.add(input)
            audioInput = input
            mixer = AudioMixer(sources: sources) { [weak self] buffer, time in
                self?.appendAudio(buffer, at: time)
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.writerFailed("Writing could not start.")
        }

        self.writer = writer
        self.videoInput = input
        self.audioInput = audioInput
        self.mixer = mixer
        self.outputURL = url
        self.sessionStarted = false
        self.lastSampleBuffer = nil
        self.lastPresentationTime = .invalid
    }

    /// How often the writer adds a movie fragment. The `.part` file is playable up to the last fragment,
    /// so a crash, power loss, force quit or writer failure keeps everything but the last moments.
    public static let fragmentInterval = CMTime(value: 2, timescale: 1)

    /// An MP4 writer that writes a fragmented movie: a small index every `fragmentInterval` instead of
    /// one index at the end, so the file on disk is readable while it is still being written.
    static func makeWriter(url: URL) throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = fragmentInterval
        return writer
    }

    /// H.264 settings for the video track.
    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: 60,
                // No B-frames. With frame reordering, movie fragments plus the sparse frames of a still
                // screen make the writer fail with -16341 after ~20 frames (reproduced on macOS 12.7);
                // live capture gains nothing from reordering anyway.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
    }

    /// Screen-content bitrate: 4 Mbit/s at 1440×900, scaled by pixel count^0.75, within 1.5–24 Mbit/s
    /// (the curve Recall uses). 2880×1800 → ~11.3 Mbit/s instead of the former 31 Mbit/s.
    static func videoBitRate(width: Int, height: Int) -> Int {
        let pixels = Double(max(width, 1) * max(height, 1))
        let rate = 4_000_000 * pow(pixels / (1440 * 900), 0.75)
        return Int(min(max(rate, 1_500_000), 24_000_000))
    }

    /// Whether ScreenCaptureKit can capture system audio on this Mac (macOS 13+).
    public static var isSystemAudioAvailable: Bool {
        if #available(macOS 13, *) {
            return true
        }
        return false
    }

    /// The mixer sources for a recording. The file gets an audio track iff this is non-empty.
    public static func audioSources(
        for config: RecordingConfig,
        systemAudioAvailable: Bool = ScreenRecorder.isSystemAudioAvailable
    ) -> [AudioMixer.SourceID] {
        var sources: [AudioMixer.SourceID] = []
        if config.captureMic {
            sources.append(.microphone)
        }
        if config.captureSystemAudio && systemAudioAvailable {
            sources.append(.system)
        }
        return sources
    }

    /// AAC, 48 kHz stereo, 160 kbps: the single mixed audio track.
    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioMixer.sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000
    ]

    // MARK: - Audio

    private func startMicrophone() throws {
        let microphone = MicrophoneCapture { [weak self] sampleBuffer in
            guard let self = self else { return }
            self.captureQueue.async {
                self.mixer?.push(sampleBuffer, from: .microphone)
            }
        }
        try microphone.start()
        self.microphone = microphone
    }

    private func stopMicrophone() {
        microphone?.stop()
        microphone = nil
    }

    /// Mixer output; runs on `captureQueue`. The mixer only emits after the session has started.
    private func appendAudio(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard !videoStopping, sessionStarted, let writer = writer, writer.status == .writing,
              let sampleBuffer = AudioMixer.sampleBuffer(from: buffer, at: time) else {
            return
        }
        pendingAudio.append(sampleBuffer)
        if pendingAudio.count > Self.maxPendingAudioChunks {
            pendingAudio.removeFirst()
            droppedAudioChunks += 1
            if droppedAudioChunks == 1 || droppedAudioChunks % 50 == 0 {
                NSLog("%@ dropped %d audio chunks: the writer fell behind", AppConfig.appName, droppedAudioChunks)
            }
        }
        drainPendingAudio()
    }

    /// Appends queued audio in order while the writer accepts it. Runs on `captureQueue`.
    private func drainPendingAudio() {
        guard let writer = writer, writer.status == .writing, let input = audioInput else { return }
        while let next = pendingAudio.first, input.isReadyForMoreMediaData {
            pendingAudio.removeFirst()
            if !input.append(next) {
                reportWriterFailureIfNeeded()
                pendingAudio.removeAll()
                return
            }
        }
    }

    // MARK: - Interruptions

    /// Reports the first mid-recording failure to the owner on the main queue. Runs on `captureQueue`.
    private func reportInterruption(_ error: Error) {
        guard writer != nil, !interruptionReported else { return }
        interruptionReported = true
        DispatchQueue.main.async { [weak self] in
            self?.onInterruption?(error)
        }
    }

    /// Disk full or an encoder error moves the writer to `.failed`; nothing more can be written.
    private func reportWriterFailureIfNeeded() {
        guard let writer = writer, writer.status == .failed else { return }
        reportInterruption(writer.error ?? RecordingError.writerFailed("Unknown error"))
    }

    // MARK: - Finishing

    private func finishWriting(at stopTime: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        videoStopping = true
        guard let writer = writer, let input = videoInput, let url = outputURL else {
            reset()
            completion(.failure(RecordingError.notRecording))
            return
        }
        guard sessionStarted, writer.status == .writing else {
            if sessionStarted, writer.status == .failed {
                // Fragmented writing: the file holds everything up to the last fragment. Keep it.
                let reason = (writer.error ?? RecordingError.writerFailed("Unknown error")).localizedDescription
                reset()
                completion(.failure(Self.keptOrLost(url, reason: reason)))
                return
            }
            discardOutput()
            completion(.failure(RecordingError.noFramesCaptured))
            return
        }

        // A static screen yields few frames; repeat the last one at the stop time so the
        // file lasts as long as the recording did.
        var endTime = lastPresentationTime
        if let last = lastSampleBuffer, CMTimeCompare(stopTime, lastPresentationTime) > 0,
           let retimed = Self.retime(last, to: stopTime), input.isReadyForMoreMediaData, input.append(retimed) {
            endTime = stopTime
        }

        // Emit the audio still buffered in the mixer, padded with silence up to the end.
        stopMicrophone()
        mixer?.flush(until: endTime)
        mixer = nil
        drainPendingAudio()
        if !pendingAudio.isEmpty {
            NSLog("%@ %d audio chunks still pending at stop were dropped", AppConfig.appName, pendingAudio.count)
            pendingAudio.removeAll()
        }
        audioInput?.markAsFinished()

        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.captureQueue.async {
                let result: Result<URL, Error>
                if writer.status == .completed {
                    result = .success(url)
                } else {
                    let reason = (writer.error ?? RecordingError.writerFailed("Unknown error")).localizedDescription
                    result = .failure(Self.keptOrLost(url, reason: reason))
                }
                self.reset()
                completion(result)
            }
        }
    }

    /// After a writer failure: the fragmented file is kept when it has content, otherwise removed.
    private static func keptOrLost(_ url: URL, reason: String) -> Error {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size > 0 {
            return RecordingError.recordingIncomplete(url: url, reason: reason)
        }
        try? FileManager.default.removeItem(at: url)
        return RecordingError.writerFailed(reason)
    }

    // MARK: - Seed frame

    /// Appends a still of the capture area at the current host time, unless a frame already arrived.
    /// Runs on `captureQueue`.
    private func appendSeedFrame(_ config: RecordingConfig) {
        guard !sessionStarted else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let bounds = CGDisplayBounds(config.displayID)
        let area = config.sourceRect ?? CGRect(origin: .zero, size: bounds.size)
        guard let image = CGDisplayCreateImage(config.displayID, rect: area),
              let bgra = Self.sampleBuffer(from: image, size: config.pixelSize, at: time),
              let sampleBuffer = Self.converted(bgra, to: Self.displayStreamPixelFormat) else {
            NSLog("%@ could not grab the first frame of the capture area", AppConfig.appName)
            return
        }
        appendVideo(sampleBuffer)
    }

    /// Draws `image` scaled into a BGRA pixel buffer of `size` and wraps it as a video sample buffer.
    static func sampleBuffer(from image: CGImage, size: CGSize, at time: CMTime) -> CMSampleBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return sampleBuffer(from: buffer, at: time)
    }

    /// The same frame in `pixelFormat`, so every frame given to the encoder has one format.
    static func converted(_ sampleBuffer: CMSampleBuffer, to pixelFormat: OSType) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        if CVPixelBufferGetPixelFormatType(source) == pixelFormat { return sampleBuffer }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let transfer = session else { return nil }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                                  pixelFormat, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let destination = output,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else {
            return nil
        }
        return Self.sampleBuffer(from: destination, at: sampleBuffer.presentationTimeStamp)
    }

    /// Wraps a pixel buffer as a video sample buffer stamped at `time`.
    static func sampleBuffer(from buffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let formatDescription = format else {
            return nil
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    /// Cancels the writer and deletes any partial file.
    private func discardOutput() {
        writer?.cancelWriting()
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        reset()
    }

    private func reset() {
        diskMonitor?.cancel()
        diskMonitor = nil
        pendingAudio.removeAll()
        droppedAudioChunks = 0
        stopMicrophone()
        stream = nil
        displayStream = nil
        displayStreamGeneration += 1
        videoStopping = false
        writer = nil
        videoInput = nil
        audioInput = nil
        mixer = nil
        outputURL = nil
        sessionStarted = false
        lastSampleBuffer = nil
        lastPresentationTime = .invalid
        streamStopped = false
        interruptionReported = false
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !videoStopping else { return }
        if #available(macOS 13, *), type == .audio {
            // System audio; the mixer drops it until the first video frame sets the timeline origin.
            guard sampleBuffer.isValid else { return }
            mixer?.push(sampleBuffer, from: .system)
            return
        }
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        guard let writer = writer else { return }
        guard writer.status == .writing else {
            reportWriterFailureIfNeeded()
            return
        }

        appendVideo(sampleBuffer)
    }
}

extension ScreenRecorder {
    /// Appends one video frame, starting the writer session on the first. Runs on `captureQueue`.
    fileprivate func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !videoStopping, let writer = writer, let input = videoInput, writer.status == .writing else { return }
        let presentationTime = sampleBuffer.presentationTimeStamp
        // A late seed frame must not go before frames already written.
        if lastPresentationTime.isValid, CMTimeCompare(presentationTime, lastPresentationTime) <= 0 { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
            // Audio is placed relative to the first video frame; anything earlier is dropped.
            mixer?.begin(at: presentationTime)
        }
        mixer?.pump()
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastSampleBuffer = sampleBuffer
            lastPresentationTime = presentationTime
        } else {
            reportWriterFailureIfNeeded()
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    /// The display went away, the Mac slept, or Screen Recording was revoked. The owner salvages the
    /// file by calling `stop`, which finishes writing without calling `stopCapture` again.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("%@ screen capture stopped with error: %@", AppConfig.appName, error.localizedDescription)
        captureQueue.async {
            guard stream === self.stream else { return }
            self.streamStopped = true
            self.stopMicrophone()
            self.reportInterruption(error)
        }
    }
}

/// Attached to a pixel buffer; releases the IOSurface use count when the buffer is deallocated.
private final class SurfaceUseToken {
    static let attachmentKey = "\(AppConfig.bundleIdentifier).surfaceUseToken" as CFString
    private let surface: IOSurfaceRef

    init(surface: IOSurfaceRef) {
        self.surface = surface
    }

    deinit {
        IOSurfaceDecrementUseCount(surface)
    }
}
