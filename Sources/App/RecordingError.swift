import Foundation

public enum RecordingError: LocalizedError, Equatable {
    case noDisplay
    case displayNotFound
    case alreadyRecording
    case notRecording
    case noFramesCaptured
    case captureServiceNotResponding
    case writerFailed(String)
    case microphoneAccessDenied
    case microphoneUnavailable(String)
    /// Capture stopped mid-recording; what was recorded up to then was saved.
    case partialRecordingSaved
    /// Writing failed mid-recording; the fragmented file at `url` holds everything up to the failure.
    case recordingIncomplete(url: URL, reason: String)
    /// Free space on the recordings volume is below what a recording needs.
    case notEnoughDiskSpace(availableBytes: Int64)
    /// Free space ran low during a recording, so it was stopped and saved.
    case diskAlmostFull

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display was found under the mouse."
        case .displayNotFound:
            return "The display is no longer available for capture."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No recording is in progress."
        case .captureServiceNotResponding:
            return "macOS screen capture is not responding. Run \"killall replayd\" in Terminal, or log out and back in, then try again."
        case .noFramesCaptured:
            return "No video frames were captured."
        case .writerFailed(let reason):
            return "The video file could not be written: \(reason)"
        case .microphoneAccessDenied:
            return "Microphone access is not allowed."
        case .microphoneUnavailable(let reason):
            return "The microphone could not be used: \(reason)"
        case .partialRecordingSaved:
            return "What was recorded up to that point has been saved."
        case .recordingIncomplete(_, let reason):
            return "Writing stopped early (\(reason)). What was recorded up to that point has been saved."
        case .notEnoughDiskSpace(let available):
            let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Only \(formatted) is free on the disk that holds your recordings."
        case .diskAlmostFull:
            return "The disk is almost full."
        }
    }
}
