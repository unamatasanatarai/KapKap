import AVFoundation
import CoreMedia

private struct AudioMixerTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw AudioMixerTestFailure(description: message)
    }
}

/// Collects mixer output and lets each test move a fake host clock.
private final class MixerHarness {
    /// Session start: 100 s on a 48 kHz timescale, so chunk times are exact.
    static let origin = CMTime(value: 100 * 48_000, timescale: 48_000)

    var clock = MixerHarness.origin
    var chunks: [(buffer: AVAudioPCMBuffer, time: CMTime)] = []
    var mixer: AudioMixer!

    init(sources: [AudioMixer.SourceID] = [.microphone], begin: Bool = true) {
        mixer = AudioMixer(sources: sources, now: { [unowned self] in self.clock }) { [unowned self] buffer, time in
            self.chunks.append((buffer, time))
        }
        if begin {
            mixer.begin(at: Self.origin)
        }
    }

    static func time(atFrame frame: Int64) -> CMTime {
        return CMTimeAdd(origin, CMTime(value: frame, timescale: 48_000))
    }

    func advanceClock(toFrame frame: Int64) {
        clock = Self.time(atFrame: frame)
    }

    var frameCount: Int {
        return chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }
    }

    /// All emitted samples of one channel, in order.
    func samples(channel: Int) -> [Float] {
        var all: [Float] = []
        for chunk in chunks {
            let data = chunk.buffer.floatChannelData![channel]
            all.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.buffer.frameLength)))
        }
        return all
    }
}

/// A 48 kHz stereo buffer whose frame `i` (counted from `startFrame`) is `value(i)` in both channels.
private func stereoBuffer(frames: Int, startFrame: Int = 0, _ value: (Int) -> Float) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<2 {
        for i in 0..<frames {
            buffer.floatChannelData![c][i] = value(startFrame + i)
        }
    }
    return buffer
}

private func sine(_ frame: Int, rate: Double = 48_000, hz: Double = 440, amplitude: Float = 0.5) -> Float {
    return amplitude * Float(sin(2 * Double.pi * hz * Double(frame) / rate))
}

public enum AudioMixerTests {
    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        runPassThroughTests(testRunner)
        runTimingTests(testRunner)
        runConversionTests(testRunner)
        runTwoSourceTests(testRunner)
    }

    // MARK: - Single-source pass-through

    private static func runPassThroughTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AudioMixer passes one source through sample-exact in contiguous 960-frame chunks") {
            let harness = MixerHarness()
            let total = 4_800
            var frame = 0
            while frame < total {
                let n = min(512, total - frame)
                let buffer = stereoBuffer(frames: n, startFrame: frame) { sine($0) }
                harness.mixer.push(buffer, at: MixerHarness.time(atFrame: Int64(frame)), from: .microphone)
                frame += n
            }

            try expect(harness.chunks.count == 5, "4800 frames make 5 chunks, got \(harness.chunks.count)")
            for (index, chunk) in harness.chunks.enumerated() {
                try expect(chunk.buffer.frameLength == 960, "chunk \(index) has \(chunk.buffer.frameLength) frames")
                try expect(chunk.buffer.format.isEqual(AudioMixer.format), "chunk \(index) is 48 kHz stereo Float32")
                let expected = MixerHarness.time(atFrame: Int64(index * 960))
                try expect(CMTimeCompare(chunk.time, expected) == 0,
                           "chunk \(index) at \(chunk.time.seconds), expected \(expected.seconds)")
            }
            for channel in 0..<2 {
                let out = harness.samples(channel: channel)
                let mismatch = (0..<total).first { out[$0] != sine($0) }
                try expect(mismatch == nil, "channel \(channel) differs at frame \(mismatch ?? -1)")
            }
        }

        testRunner("AudioMixer flush emits the remaining partial chunk") {
            let harness = MixerHarness()
            harness.mixer.push(stereoBuffer(frames: 1_000) { _ in 0.25 }, at: MixerHarness.origin, from: .microphone)
            try expect(harness.chunks.count == 1, "one full chunk before flush, got \(harness.chunks.count)")

            harness.mixer.flush(until: MixerHarness.time(atFrame: 1_000))
            try expect(harness.chunks.count == 2, "flush adds one chunk, got \(harness.chunks.count)")
            let last = harness.chunks[1]
            try expect(last.buffer.frameLength == 40, "partial chunk of 40 frames, got \(last.buffer.frameLength)")
            try expect(CMTimeCompare(last.time, MixerHarness.time(atFrame: 960)) == 0, "partial chunk follows on")
            try expect(harness.samples(channel: 1).allSatisfy { $0 == 0.25 }, "flushed audio is the pushed audio")
        }

        testRunner("AudioMixer flush pads missing audio with silence up to the stop time") {
            let harness = MixerHarness()
            harness.mixer.push(stereoBuffer(frames: 480) { _ in 0.5 }, at: MixerHarness.origin, from: .microphone)
            harness.mixer.flush(until: MixerHarness.time(atFrame: 2_400))
            try expect(harness.frameCount == 2_400, "flush covers 2400 frames, got \(harness.frameCount)")
            let out = harness.samples(channel: 0)
            try expect(out[0..<480].allSatisfy { $0 == 0.5 } && out[480...].allSatisfy { $0 == 0 },
                       "audio then silence")
        }
    }

    // MARK: - Timeline

    private static func runTimingTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AudioMixer pads a late-starting source with silence up front") {
            let harness = MixerHarness()
            // First mic buffer arrives stamped 50 ms after the session start.
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.25 },
                               at: MixerHarness.time(atFrame: 2_400), from: .microphone)
            try expect(harness.chunks.count == 3, "3360 frames available make 3 chunks, got \(harness.chunks.count)")
            let out = harness.samples(channel: 0)
            try expect(out[0..<2_400].allSatisfy { $0 == 0 }, "silence before the source starts")
            try expect(out[2_400..<2_880].allSatisfy { $0 == 0.25 }, "source audio at its timestamp")
            try expect(CMTimeCompare(harness.chunks[0].time, MixerHarness.origin) == 0, "first chunk at the origin")
        }

        testRunner("AudioMixer drops audio before the session start") {
            let harness = MixerHarness(begin: false)
            harness.mixer.push(stereoBuffer(frames: 4_800) { _ in 0.9 },
                               at: MixerHarness.time(atFrame: -9_600), from: .microphone)
            harness.mixer.begin(at: MixerHarness.origin)
            try expect(harness.chunks.isEmpty, "nothing emitted for audio pushed before begin")

            // Straddles the origin: the first 1000 frames precede it.
            harness.mixer.push(stereoBuffer(frames: 2_920, startFrame: -1_000) { $0 < 0 ? -0.5 : 0.5 },
                               at: MixerHarness.time(atFrame: -1_000), from: .microphone)
            try expect(harness.chunks.count == 2, "1920 frames after the origin make 2 chunks, got \(harness.chunks.count)")
            try expect(harness.samples(channel: 0).allSatisfy { $0 == 0.5 }, "pre-origin frames were dropped")
            try expect(CMTimeCompare(harness.chunks[0].time, MixerHarness.origin) == 0, "first chunk at the origin")
        }

        testRunner("AudioMixer snaps small timestamp jitter so a source stays contiguous") {
            let harness = MixerHarness()
            // Buffers stamped a few ms early or late against their true position.
            for (index, jitter) in [0, 120, -90, 200, -150].enumerated() {
                let frame = index * 960
                harness.mixer.push(stereoBuffer(frames: 960, startFrame: frame) { Float($0) / 10_000 },
                                   at: MixerHarness.time(atFrame: Int64(frame + jitter)), from: .microphone)
            }
            let out = harness.samples(channel: 0)
            try expect(out.count == 4_800, "no frames gained or lost, got \(out.count)")
            let mismatch = (0..<out.count).first { out[$0] != Float($0) / 10_000 }
            try expect(mismatch == nil, "samples out of order at frame \(mismatch ?? -1)")
        }

        testRunner("AudioMixer pads a stalled source with silence once the jitter window passes") {
            let harness = MixerHarness()
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 }, at: MixerHarness.origin, from: .microphone)
            try expect(harness.chunks.count == 1, "one chunk of real audio")

            // 150 ms later the mic has sent nothing more: 100 ms jitter leaves 50 ms (2400 frames) emittable.
            harness.advanceClock(toFrame: 7_200)
            harness.mixer.pump()
            try expect(harness.frameCount == 1_920, "pads through clock − jitter in whole chunks, got \(harness.frameCount)")
            try expect(harness.samples(channel: 0)[960...].allSatisfy { $0 == 0 }, "padding is silence")

            // Audio for the already-padded span arrives late; only its newer tail is kept.
            harness.mixer.push(stereoBuffer(frames: 1_920, startFrame: 960) { _ in 0.75 },
                               at: MixerHarness.time(atFrame: 960), from: .microphone)
            let out = harness.samples(channel: 0)
            try expect(out.count == 2_880, "the late tail fills one more chunk, got \(out.count)")
            try expect(out[1_920...].allSatisfy { $0 == 0.75 }, "late tail placed after the padding")
        }

        testRunner("AudioMixer with two sources waits for both, then pads the one that is missing") {
            let harness = MixerHarness(sources: [.microphone, .system])
            harness.mixer.push(stereoBuffer(frames: 1_920) { sine($0) }, at: MixerHarness.origin, from: .microphone)
            try expect(harness.chunks.isEmpty, "waits for system audio within the jitter window")

            harness.advanceClock(toFrame: 1_920 + 4_800)
            harness.mixer.pump()
            try expect(harness.frameCount == 1_920, "mic emitted once the window passed, got \(harness.frameCount)")
            let out = harness.samples(channel: 1)
            let mismatch = (0..<1_920).first { out[$0] != sine($0) }
            try expect(mismatch == nil, "missing source adds silence, mic unchanged (frame \(mismatch ?? -1))")
        }
    }

    // MARK: - Format conversion

    private static func runConversionTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AudioMixer sample buffer round-trip keeps samples and timing") {
            let buffer = stereoBuffer(frames: 960) { sine($0) }
            let time = MixerHarness.time(atFrame: 960)
            guard let sampleBuffer = AudioMixer.sampleBuffer(from: buffer, at: time) else {
                throw AudioMixerTestFailure(description: "no sample buffer")
            }
            try expect(CMSampleBufferGetNumSamples(sampleBuffer) == 960, "960 samples")
            try expect(CMTimeCompare(sampleBuffer.presentationTimeStamp, time) == 0, "PTS kept")
            guard let back = AudioMixer.pcmBuffer(from: sampleBuffer) else {
                throw AudioMixerTestFailure(description: "no PCM buffer")
            }
            try expect(back.format.isEqual(AudioMixer.format) && back.frameLength == 960, "format and length kept")
            let mismatch = (0..<960).first { back.floatChannelData![1][$0] != sine($0) }
            try expect(mismatch == nil, "samples kept (frame \(mismatch ?? -1))")
        }

        testRunner("AudioMixer converts mono 44.1 kHz input to 48 kHz stereo at the right length") {
            let harness = MixerHarness()
            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let perBuffer = 441
            for index in 0..<100 {
                let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(perBuffer))!
                buffer.frameLength = AVAudioFrameCount(perBuffer)
                for i in 0..<perBuffer {
                    buffer.floatChannelData![0][i] = sine(index * perBuffer + i, rate: 44_100)
                }
                let time = CMTimeAdd(MixerHarness.origin, CMTime(value: Int64(index * perBuffer), timescale: 44_100))
                guard let sampleBuffer = AudioMixer.sampleBuffer(from: buffer, at: time) else {
                    throw AudioMixerTestFailure(description: "no input sample buffer")
                }
                harness.mixer.push(sampleBuffer, from: .microphone)
            }

            // One second of input; the resampler may hold back a few ms until more input arrives.
            let emitted = harness.frameCount
            try expect(emitted <= 48_000 && emitted >= 48_000 - 2 * 960,
                       "about 48000 frames for 1 s of input, got \(emitted)")
            harness.mixer.flush(until: MixerHarness.time(atFrame: 48_000))
            try expect(harness.frameCount == 48_000, "flush completes the second, got \(harness.frameCount)")

            let left = harness.samples(channel: 0)
            let right = harness.samples(channel: 1)
            try expect(left == right, "mono feeds both channels")
            let peak = left[2_400..<40_000].map { abs($0) }.max() ?? 0
            try expect(peak > 0.45 && peak < 0.55, "sine amplitude preserved, peak \(peak)")
        }
    }

    // MARK: - Two sources (system audio + mic)

    private static func runTwoSourceTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AudioMixer sums two sources with known constant values") {
            let harness = MixerHarness(sources: [.microphone, .system])
            harness.mixer.push(stereoBuffer(frames: 1_920) { _ in 0.25 }, at: MixerHarness.origin, from: .microphone)
            try expect(harness.chunks.isEmpty, "nothing emitted until the second source arrives")
            harness.mixer.push(stereoBuffer(frames: 1_920) { _ in 0.5 }, at: MixerHarness.origin, from: .system)
            try expect(harness.chunks.count == 2, "1920 frames from both make 2 chunks, got \(harness.chunks.count)")
            for channel in 0..<2 {
                try expect(harness.samples(channel: channel).allSatisfy { $0 == 0.75 },
                           "channel \(channel) is 0.25 + 0.5")
            }
        }

        testRunner("AudioMixer aligns two sources with offset start times by timestamp") {
            let harness = MixerHarness(sources: [.microphone, .system])
            harness.mixer.push(stereoBuffer(frames: 2_880) { _ in 0.25 }, at: MixerHarness.origin, from: .microphone)
            // System audio starts 20 ms (960 frames) after the mic.
            harness.mixer.push(stereoBuffer(frames: 1_920) { _ in 0.5 },
                               at: MixerHarness.time(atFrame: 960), from: .system)
            try expect(harness.frameCount == 2_880, "both sources end at frame 2880, got \(harness.frameCount)")
            let out = harness.samples(channel: 0)
            try expect(out[0..<960].allSatisfy { $0 == 0.25 }, "mic alone before system audio starts")
            try expect(out[960..<2_880].allSatisfy { $0 == 0.75 }, "both summed once system audio starts")
            for (index, chunk) in harness.chunks.enumerated() {
                try expect(CMTimeCompare(chunk.time, MixerHarness.time(atFrame: Int64(index * 960))) == 0,
                           "chunk \(index) timestamps stay contiguous")
            }
        }

        testRunner("AudioMixer pads a source that stalls past the jitter window while the other continues") {
            let harness = MixerHarness(sources: [.microphone, .system])
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.25 }, at: MixerHarness.origin, from: .microphone)
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 }, at: MixerHarness.origin, from: .system)
            try expect(harness.chunks.count == 1, "one chunk while both deliver")

            // System audio stalls; the mic keeps delivering 100 ms more.
            harness.mixer.push(stereoBuffer(frames: 4_800) { _ in 0.25 },
                               at: MixerHarness.time(atFrame: 960), from: .microphone)
            harness.advanceClock(toFrame: 5_760)
            harness.mixer.pump()
            try expect(harness.frameCount == 960, "within the window the mixer waits, got \(harness.frameCount)")

            harness.advanceClock(toFrame: 5_760 + 4_800)
            harness.mixer.pump()
            try expect(harness.frameCount == 5_760, "mic emitted once the window passed, got \(harness.frameCount)")
            var out = harness.samples(channel: 1)
            try expect(out[0..<960].allSatisfy { $0 == 0.75 }, "summed before the stall")
            try expect(out[960..<5_760].allSatisfy { $0 == 0.25 }, "stalled source adds silence, mic unchanged")

            // System audio resumes on time with the mic.
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.25 },
                               at: MixerHarness.time(atFrame: 5_760), from: .microphone)
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 },
                               at: MixerHarness.time(atFrame: 5_760), from: .system)
            out = harness.samples(channel: 1)
            try expect(out.count == 6_720 && out[5_760...].allSatisfy { $0 == 0.75 }, "summed again after resuming")
        }

        testRunner("AudioMixer clamps a two-source sum beyond ±1") {
            let harness = MixerHarness(sources: [.microphone, .system])
            let value: (Int) -> Float = { $0 % 2 == 0 ? 0.75 : -0.75 }
            harness.mixer.push(stereoBuffer(frames: 960, value), at: MixerHarness.origin, from: .microphone)
            harness.mixer.push(stereoBuffer(frames: 960, value), at: MixerHarness.origin, from: .system)
            let out = harness.samples(channel: 0)
            try expect(out.count == 960, "one chunk, got \(out.count)")
            let mismatch = (0..<960).first { out[$0] != ($0 % 2 == 0 ? 1 : -1) }
            try expect(mismatch == nil, "±1.5 clamps to ±1 (frame \(mismatch ?? -1))")
        }

        testRunner("AudioMixer with either source alone is a sample-exact pass-through") {
            for source in [AudioMixer.SourceID.microphone, .system] {
                let harness = MixerHarness(sources: [source])
                harness.mixer.push(stereoBuffer(frames: 2_880) { sine($0) }, at: MixerHarness.origin, from: source)
                try expect(harness.chunks.count == 3, "\(source): 3 chunks, got \(harness.chunks.count)")
                let out = harness.samples(channel: 0)
                let mismatch = (0..<2_880).first { out[$0] != sine($0) }
                try expect(mismatch == nil, "\(source): passes through unchanged (frame \(mismatch ?? -1))")
            }
        }

        testRunner("ScreenRecorder seed frame encodes into an H.264 mp4 that lasts until the stop time") {
            // A static capture area: only the seed still plus its copy at the stop time (as at stop).
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            let image = ctx.makeImage()!
            let size = CGSize(width: 320, height: 180)
            let start = CMTime(value: 1000, timescale: 1)
            let end = CMTimeAdd(start, CMTime(value: 2, timescale: 1))
            guard let seed = ScreenRecorder.sampleBuffer(from: image, size: size, at: start),
                  let last = ScreenRecorder.sampleBuffer(from: image, size: size, at: end) else {
                throw AudioMixerTestFailure(description: "seed sample buffer not created")
            }
            let pixels = CMSampleBufferGetImageBuffer(seed)!
            try expect(CVPixelBufferGetWidth(pixels) == 320 && CVPixelBufferGetHeight(pixels) == 180, "seed has output size")
            try expect(seed.presentationTimeStamp == start, "seed stamped at start")

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            try expect(writer.startWriting(), "writer starts")
            writer.startSession(atSourceTime: start)
            try expect(input.append(seed), "seed frame accepted by the H.264 input")
            try expect(input.append(last), "stop-time frame accepted")
            input.markAsFinished()
            writer.endSession(atSourceTime: end)
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            try expect(writer.status == .completed, "writer completed: \(String(describing: writer.error))")
            let duration = AVURLAsset(url: url).duration.seconds
            try expect(abs(duration - 2) < 0.1, "file lasts ~2 s, got \(duration)")
        }

        testRunner("ScreenRecorder display stream crops to the section and shows the cursor") {
            func config(_ rect: CGRect?) -> RecordingConfig {
                RecordingConfig(displayID: 1, sourceRect: rect, outputURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                                pixelSize: CGSize(width: 1308, height: 772), captureMic: false, captureSystemAudio: false)
            }
            let section = CGRect(x: 274, y: 275.5, width: 654, height: 386)
            let cropped = ScreenRecorder.displayStreamProperties(config(section))
            let rectDict = cropped[CGDisplayStream.sourceRect] as! CFDictionary
            try expect(CGRect(dictionaryRepresentation: rectDict) == section, "source rect passed through unchanged")
            try expect((cropped[CGDisplayStream.showCursor] as? Bool) == true, "cursor is recorded")
            try expect(ScreenRecorder.displayStreamProperties(config(nil))[CGDisplayStream.sourceRect] == nil,
                       "fullscreen has no source rect")
            if #available(macOS 13, *) {
                try expect(!ScreenRecorder.usesDisplayStream, "ScreenCaptureKit on macOS 13+")
            } else {
                try expect(ScreenRecorder.usesDisplayStream, "CGDisplayStream on macOS 12")
            }
        }

        testRunner("AudioMixer drops a buffer stamped far ahead of the clock instead of padding gigabytes") {
            let harness = MixerHarness()
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 }, at: MixerHarness.time(atFrame: 0), from: .microphone)
            // An hour ahead with the clock still at the start: 172.8 M frames of padding if unbounded.
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 },
                               at: MixerHarness.time(atFrame: 3_600 * 48_000), from: .microphone)
            try expect(harness.mixer.droppedDiscontinuities == 1, "bogus buffer dropped")
            try expect(harness.frameCount == 960, "only the real audio emitted, got \(harness.frameCount)")
        }

        testRunner("AudioMixer keeps sync across a long legitimate stall without buffering the gap") {
            let harness = MixerHarness()
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.5 }, at: MixerHarness.time(atFrame: 0), from: .microphone)
            // The source stalls for 20 s while the clock runs; nothing pumps the mixer meanwhile.
            let resume: Int64 = 20 * 48_000
            harness.advanceClock(toFrame: resume + 960)
            harness.mixer.push(stereoBuffer(frames: 960) { _ in 0.25 }, at: MixerHarness.time(atFrame: resume), from: .microphone)
            try expect(harness.mixer.droppedDiscontinuities == 0, "a stall is not a discontinuity")
            harness.mixer.flush(until: MixerHarness.time(atFrame: resume + 960))
            let samples = harness.samples(channel: 0)
            try expect(samples.count == Int(resume) + 960, "timeline stays continuous, got \(samples.count)")
            try expect(samples[Int(resume)] == 0.25 && samples[Int(resume) - 1] == 0, "resumed audio lands at its own time")
        }

        testRunner("ScreenRecorder video settings: gentle bitrate and no B-frames") {
            let settings = ScreenRecorder.videoSettings(width: 2880, height: 1800)
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            try expect(compression[AVVideoAllowFrameReorderingKey] as? Bool == false,
                       "B-frames + movie fragments + sparse frames fails with -16341")
            let rate = compression[AVVideoAverageBitRateKey] as? Int ?? 0
            try expect((11_000_000...11_600_000).contains(rate), "2880×1800 ≈ 11.3 Mbit/s, got \(rate)")
            try expect(ScreenRecorder.videoBitRate(width: 1440, height: 900) == 4_000_000, "reference point")
            try expect(ScreenRecorder.videoBitRate(width: 100, height: 100) == 1_500_000, "floor")
            try expect(ScreenRecorder.videoBitRate(width: 7680, height: 4320) == 24_000_000, "ceiling")
        }

        testRunner("ScreenRecorder refuses to start without enough free disk space") {
            let url = URL(fileURLWithPath: "/tmp/x.mp4.part")
            let tight = ScreenRecorder(freeSpace: { _ in 500_000_000 })
            do {
                try tight.checkFreeSpaceToStart(url)
                throw AudioMixerTestFailure(description: "500 MB free should block a recording")
            } catch RecordingError.notEnoughDiskSpace(let available) {
                try expect(available == 500_000_000, "reports the free space")
            }
            try ScreenRecorder(freeSpace: { _ in 50_000_000_000 }).checkFreeSpaceToStart(url)
            try ScreenRecorder(freeSpace: { _ in nil }).checkFreeSpaceToStart(url)
            // HFS+ volumes report 0 "important usage" capacity: fall back to the plain figure.
            try expect(ScreenRecorder.chooseCapacity(important: 0, plain: 120_000_000) == 120_000_000, "HFS+ fallback")
            try expect(ScreenRecorder.chooseCapacity(important: 5_000_000_000, plain: 1_000) == 5_000_000_000, "APFS")
            try expect(ScreenRecorder.chooseCapacity(important: nil, plain: nil) == nil, "unknown")
            let tmp = ScreenRecorder.availableCapacity(for: FileManager.default.temporaryDirectory.appendingPathComponent("x"))
            try expect((tmp ?? 0) > 0, "real volume reports free space, got \(String(describing: tmp))")
        }

        testRunner("ScreenRecorder converts the seed frame to the display stream's 4:2:0 format") {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let bgra = ScreenRecorder.sampleBuffer(from: ctx.makeImage()!, size: CGSize(width: 64, height: 36),
                                                   at: CMTime(value: 5, timescale: 1))!
            guard let yuv = ScreenRecorder.converted(bgra, to: ScreenRecorder.displayStreamPixelFormat),
                  let pixels = CMSampleBufferGetImageBuffer(yuv) else {
                throw AudioMixerTestFailure(description: "conversion failed")
            }
            try expect(CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v")
            try expect(CVPixelBufferGetWidth(pixels) == 64 && CVPixelBufferGetHeight(pixels) == 36, "same size")
            try expect(yuv.presentationTimeStamp == CMTime(value: 5, timescale: 1), "same timestamp")
        }

        testRunner("ScreenRecorder writes a fragmented mp4 that plays before it is finished (crash-safe)") {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
            let image = ctx.makeImage()!
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(".rec.mp4.part")
            let writer = try ScreenRecorder.makeWriter(url: url)
            try expect(writer.movieFragmentInterval == ScreenRecorder.fragmentInterval, "fragment interval set")
            let input = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: ScreenRecorder.videoSettings(width: 320, height: 180))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            try expect(writer.startWriting(), "writer starts")
            writer.startSession(atSourceTime: .zero)
            // 6 s of 10 fps media over ~3 s of wall time.
            for frame in 0..<60 {
                let time = CMTime(value: CMTimeValue(frame), timescale: 10)
                guard let bgra = ScreenRecorder.sampleBuffer(from: image, size: CGSize(width: 320, height: 180), at: time),
                      let buffer = ScreenRecorder.converted(bgra, to: ScreenRecorder.displayStreamPixelFormat) else {
                    throw AudioMixerTestFailure(description: "frame \(frame) not created")
                }
                while !input.isReadyForMoreMediaData { usleep(1000) }
                try expect(input.append(buffer), "frame \(frame) appended")
                usleep(50_000)
            }
            // "Crash": what is on disk now, recovered the way the app does it (visible .mp4 name).
            let crashed = dir.appendingPathComponent("crashed.mp4")
            try FileManager.default.copyItem(at: url, to: crashed)
            let asset = AVURLAsset(url: crashed)
            try expect(!asset.tracks(withMediaType: .video).isEmpty, "unfinished file has a video track")
            try expect(asset.duration.seconds >= 2, "plays at least one fragment, got \(asset.duration.seconds) s")

            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 60, timescale: 10))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            try expect(writer.status == .completed, "finishes normally: \(String(describing: writer.error))")
            let final = dir.appendingPathComponent("rec.mp4")
            try FileManager.default.moveItem(at: url, to: final)
            let finished = AVURLAsset(url: final).duration.seconds
            try expect(abs(finished - 6) < 0.2, "finished file lasts ~6 s, got \(finished)")
        }

        testRunner("ScreenRecorder writer survives the sparse frames of a still screen (no -16341)") {
            // Reproduces the live failure offline: 1 frame/s with 2 s fragments failed after ~20 frames
            // while frame reordering (B-frames) was on.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let writer = try ScreenRecorder.makeWriter(url: dir.appendingPathComponent("rec.mp4"))
            let input = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: ScreenRecorder.videoSettings(width: 320, height: 180))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            try expect(writer.startWriting(), "writer starts")
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, ScreenRecorder.displayStreamPixelFormat, nil, &pixels)
            // Host-clock style timestamps, as CGDisplayStream delivers them.
            let base = CMTime(value: 180_000_000_000_000, timescale: 1_000_000_000)
            writer.startSession(atSourceTime: base)
            for second in 0..<40 {
                let time = CMTimeAdd(base, CMTime(value: CMTimeValue(second), timescale: 1))
                let buffer = ScreenRecorder.sampleBuffer(from: pixels!, at: time)!
                while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(200) }
                try expect(writer.status == .writing, "writer failed at frame \(second): \(String(describing: writer.error))")
                try expect(input.append(buffer), "frame \(second) appended")
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTimeAdd(base, CMTime(value: 40, timescale: 1)))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            try expect(writer.status == .completed, "completes: \(String(describing: writer.error))")
        }

        testRunner("ScreenRecorder adds an audio track iff at least one source is enabled") {
            func sources(mic: Bool, system: Bool, available: Bool) -> [AudioMixer.SourceID] {
                let config = RecordingConfig(
                    displayID: 1, sourceRect: nil, outputURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                    pixelSize: CGSize(width: 2, height: 2), captureMic: mic, captureSystemAudio: system)
                return ScreenRecorder.audioSources(for: config, systemAudioAvailable: available)
            }
            try expect(sources(mic: false, system: false, available: true).isEmpty, "no toggles: no audio track")
            try expect(sources(mic: true, system: false, available: true) == [.microphone], "mic only")
            try expect(sources(mic: false, system: true, available: true) == [.system], "system audio only")
            try expect(sources(mic: true, system: true, available: true) == [.microphone, .system], "both mixed")
            try expect(sources(mic: false, system: true, available: false).isEmpty,
                       "system audio is ignored before macOS 13")
            try expect(sources(mic: true, system: true, available: false) == [.microphone],
                       "mic still recorded before macOS 13")
        }

        testRunner("AudioMixer caches format description for standard format") {
            try expect(AudioMixer.formatDescription != nil, "cached format description exists")
            let pcm = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: 960)!
            pcm.frameLength = 960
            let sample = AudioMixer.sampleBuffer(from: pcm, at: CMTime(value: 0, timescale: 48000))!
            try expect(sample.formatDescription == AudioMixer.formatDescription, "uses cached format description")
        }

        testRunner("ScreenRecorder audio buffer capacity and stop timeout are calibrated") {
            try expect(ScreenRecorder.maxPendingAudioChunks == 50, "pending audio chunks capacity is 50 (~1s)")
            try expect(ScreenRecorder.stopTimeout == 6, "stop timeout is 6s")
        }
    }
}
