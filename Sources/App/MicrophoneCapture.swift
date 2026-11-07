import AVFoundation
import CoreMedia

/// Captures the default audio input with `AVCaptureSession` and hands each buffer, stamped on the
/// host clock (the clock ScreenCaptureKit uses), to `handler` on a private queue.
public final class MicrophoneCapture: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "\(AppConfig.bundleIdentifier).microphone")
    private let handler: (CMSampleBuffer) -> Void

    public init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    /// Configures the session with the default audio device and starts it. Blocks until running.
    public func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.microphoneUnavailable("No microphone was found.")
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.microphoneUnavailable("The microphone could not be added to the capture session.")
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        observeSessionProblems()
        session.startRunning()
        guard session.isRunning else {
            removeObservers()
            throw RecordingError.microphoneUnavailable("The microphone did not start.")
        }
    }

    private var observers: [NSObjectProtocol] = []

    /// A microphone that fails or is taken away mid-recording leaves silence; at least say why in the log.
    private func observeSessionProblems() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                                            queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            NSLog("%@ microphone failed: %@", AppConfig.appName, error?.localizedDescription ?? "unknown error")
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session,
                                            queue: nil) { _ in
            NSLog("%@ microphone was interrupted; the recording continues with silence", AppConfig.appName)
        })
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil,
                                            queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice,
                  self?.session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device == device }) == true
            else { return }
            NSLog("%@ microphone %@ was disconnected; the recording continues with silence",
                  AppConfig.appName, device.localizedName)
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Stops the session. Blocks until no more buffers are delivered.
    public func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        output.setSampleBufferDelegate(nil, queue: nil)
        removeObservers()
    }

    /// Re-stamps a buffer from the session's clock onto the host clock, when they differ.
    private func hostTimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        let hostClock = CMClockGetHostTimeClock()
        guard let sessionClock = session.synchronizationClock, !CFEqual(sessionClock, hostClock) else {
            return sampleBuffer
        }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid else { return sampleBuffer }
        var timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: CMSyncConvertTime(pts, from: sessionClock, to: hostClock),
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? (copy ?? sampleBuffer) : sampleBuffer
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        handler(hostTimed(sampleBuffer))
    }
}
