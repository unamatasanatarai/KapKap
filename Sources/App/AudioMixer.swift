import AVFoundation
import CoreMedia

/// Converts each audio source to 48 kHz stereo Float32, places it on a shared host-time timeline,
/// sums the sources and emits fixed-size chunks with contiguous timestamps for one AAC track.
///
/// Timeline: frame 0 is `origin` (the writer session start, set by `begin(at:)`). Audio before
/// `begin` or stamped before the origin is dropped. A chunk is emitted once every source has
/// data for it, or once the clock is `jitter` past its end; a lagging source is padded with silence
/// so one stalled source never blocks the others. With one source this is a converting pass-through.
///
/// Not thread-safe: the owner calls it from one serial queue. `output` runs synchronously on that queue.
public final class AudioMixer {
    public enum SourceID: Hashable {
        case microphone
        case system
    }

    public static let sampleRate: Double = 48_000
    /// Float32, deinterleaved, 2 channels.
    public static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Cached format description for `AudioMixer.format`, avoiding continuous recreation at 50 Hz.
    public static let formatDescription: CMAudioFormatDescription? = {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }()

    public let chunkFrames: AVAudioFrameCount

    /// Samples buffered for one source, starting at absolute timeline frame `start`.
    private final class Track {
        var start: Int64 = 0
        var channels: [[Float]] = [[], []]
        var end: Int64 { return start + Int64(channels[0].count) }

        /// Drops everything before `frame`; an empty track moves up to `frame`.
        func trim(before frame: Int64) {
            let drop = Int(min(max(frame - start, 0), Int64(channels[0].count)))
            if drop > 0 {
                for c in channels.indices { channels[c].removeFirst(drop) }
            }
            start = max(start + Int64(drop), frame)
        }
    }

    /// Per-source format conversion, recreated when the source format changes.
    private struct SourceConverter {
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter
    }

    private let jitterFrames: Int64
    /// The largest silence gap materialised at once. A legitimate gap (a source that stalled while the
    /// clock ran) is first shrunk by emitting up to the clock; anything still larger is a bogus or
    /// discontinuous timestamp ahead of the clock, and padding it could allocate gigabytes.
    private let maxGapFrames: Int64
    /// Buffers dropped because their timestamp was implausibly far ahead of the clock.
    public private(set) var droppedDiscontinuities = 0
    /// Timestamps within this many frames of a track's end are treated as contiguous, which absorbs
    /// capture jitter and resampler length variation while bounding clock drift.
    private let snapFrames: Int64
    private let now: () -> CMTime
    private let output: (AVAudioPCMBuffer, CMTime) -> Void

    private var tracks: [SourceID: Track] = [:]
    private var converters: [SourceID: SourceConverter] = [:]
    private var origin: CMTime?
    /// Next timeline frame to emit.
    private var cursor: Int64 = 0

    public init(
        sources: [SourceID],
        chunkFrames: AVAudioFrameCount = 960,
        jitter: TimeInterval = 0.1,
        snapTolerance: TimeInterval = 0.01,
        now: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
        output: @escaping (AVAudioPCMBuffer, CMTime) -> Void
    ) {
        self.chunkFrames = max(chunkFrames, 1)
        self.jitterFrames = Int64((jitter * Self.sampleRate).rounded())
        self.snapFrames = Int64((snapTolerance * Self.sampleRate).rounded())
        self.maxGapFrames = jitterFrames + Int64(Self.sampleRate)
        self.now = now
        self.output = output
        for source in sources {
            tracks[source] = Track()
        }
    }

    /// Sets the timeline origin (the writer session start). Only the first call has an effect.
    public func begin(at origin: CMTime) {
        guard self.origin == nil, origin.isValid else { return }
        self.origin = origin
    }

    // MARK: - Input

    /// Converts a captured buffer to the mixer format and places it at its presentation time.
    public func push(_ sampleBuffer: CMSampleBuffer, from source: SourceID) {
        guard origin != nil, tracks[source] != nil, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        let time = sampleBuffer.presentationTimeStamp
        if pcm.format.isEqual(Self.format) {
            push(pcm, at: time, from: source)
        } else if let converted = convert(pcm, from: source) {
            push(converted, at: time, from: source)
        }
    }

    /// Testable core: places a buffer already in `AudioMixer.format` on the timeline.
    public func push(_ buffer: AVAudioPCMBuffer, at time: CMTime, from source: SourceID) {
        guard let origin = origin, let track = tracks[source], time.isValid, buffer.frameLength > 0,
              buffer.format.isEqual(Self.format), let data = buffer.floatChannelData else {
            return
        }
        let count = Int64(buffer.frameLength)
        var frame = Self.frames(between: origin, and: time)
        if abs(frame - track.end) <= snapFrames {
            frame = track.end
        }

        if frame - track.end > maxGapFrames {
            // Let the clock emit (and trim) what it can; a stalled source's track then starts near now.
            emitReady()
            if frame - track.end > maxGapFrames {
                droppedDiscontinuities += 1
                if droppedDiscontinuities == 1 {
                    NSLog("AudioMixer: dropped a %@ buffer stamped %.1f s ahead of its track",
                          String(describing: source), Double(frame - track.end) / Self.sampleRate)
                }
                return
            }
        }

        var skip: Int64 = 0
        if frame > track.end {
            // A gap: pad with silence up to this buffer.
            let gap = Int(frame - track.end)
            for c in track.channels.indices {
                track.channels[c].append(contentsOf: repeatElement(0, count: gap))
            }
        } else if frame < track.end {
            // Overlaps audio already buffered or emitted (or precedes the origin): keep only the new tail.
            skip = track.end - frame
        }

        if skip < count {
            let first = Int(skip)
            let total = Int(count)
            for c in track.channels.indices {
                track.channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c] + first, count: total - first))
            }
        }
        emitReady()
    }

    /// Emits whatever the clock allows; call it regularly (e.g. per video frame) so a stalled
    /// source turns into silence instead of a gap.
    public func pump() {
        emitReady()
    }

    /// Emits everything up to `time`, padding missing audio with silence; the last chunk may be partial.
    public func flush(until time: CMTime) {
        guard let origin = origin, time.isValid else { return }
        let endFrame = Self.frames(between: origin, and: time)
        while cursor < endFrame {
            emit(frames: AVAudioFrameCount(min(Int64(chunkFrames), endFrame - cursor)))
        }
    }

    // MARK: - Emitting

    private func emitReady() {
        guard let origin = origin else { return }
        let clockFrame = Self.frames(between: origin, and: now())
        while true {
            let target = cursor + Int64(chunkFrames)
            let allSourcesReady = tracks.values.allSatisfy { $0.end >= target }
            let windowPassed = clockFrame >= target + jitterFrames
            guard allSourcesReady || windowPassed else { return }
            emit(frames: chunkFrames)
        }
    }

    private func emit(frames count: AVAudioFrameCount) {
        guard let origin = origin, count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: count),
              let outData = out.floatChannelData else {
            return
        }
        out.frameLength = count
        let channelCount = Int(Self.format.channelCount)
        let length = Int(count)
        for c in 0..<channelCount {
            outData[c].initialize(repeating: 0, count: length)
        }

        let chunkEnd = cursor + Int64(count)
        for track in tracks.values {
            let from = max(cursor, track.start)
            let to = min(chunkEnd, track.end)
            guard from < to else { continue }
            let src = Int(from - track.start)
            let dst = Int(from - cursor)
            let n = Int(to - from)
            for c in 0..<channelCount {
                track.channels[c].withUnsafeBufferPointer { samples in
                    let target = outData[c] + dst
                    for i in 0..<n {
                        target[i] += samples[src + i]
                    }
                }
            }
        }
        // Clamp after summing; a single source within ±1 passes through untouched.
        for c in 0..<channelCount {
            let samples = outData[c]
            for i in 0..<length {
                samples[i] = min(max(samples[i], -1), 1)
            }
        }

        let time = CMTimeAdd(origin, CMTime(value: cursor, timescale: CMTimeScale(Self.sampleRate)))
        cursor = chunkEnd
        for track in tracks.values {
            track.trim(before: cursor)
        }
        output(out, time)
    }

    // MARK: - Conversion

    private func convert(_ buffer: AVAudioPCMBuffer, from source: SourceID) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if converters[source]?.inputFormat.isEqual(inputFormat) != true {
            guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else { return nil }
            if inputFormat.channelCount == 1 {
                // Mono to stereo: feed the one input channel to both outputs.
                converter.channelMap = [0, 0]
            }
            converters[source] = SourceConverter(inputFormat: inputFormat, converter: converter)
        }
        guard let converter = converters[source]?.converter else { return nil }

        let ratio = Self.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    // MARK: - Helpers

    static func frames(between origin: CMTime, and time: CMTime) -> Int64 {
        return Int64((CMTimeGetSeconds(CMTimeSubtract(time, origin)) * sampleRate).rounded())
    }

    /// Copies a linear PCM sample buffer into an `AVAudioPCMBuffer` in the buffer's own format.
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Wraps a PCM buffer in a `CMSampleBuffer` stamped at `time`, ready for an `AVAssetWriterInput`.
    public static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let formatDescription: CMAudioFormatDescription
        if buffer.format.isEqual(Self.format), let cached = Self.formatDescription {
            formatDescription = cached
        } else {
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: buffer.format.streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            ) == noErr, let created = description else {
                return nil
            }
            formatDescription = created
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let result = sampleBuffer else {
            return nil
        }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            result,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else {
            return nil
        }
        return result
    }
}
