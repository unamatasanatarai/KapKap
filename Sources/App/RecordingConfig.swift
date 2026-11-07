import CoreGraphics
import Foundation

/// Everything a recorder needs to capture one display (or a region of it) into a file.
public struct RecordingConfig: Equatable {
    public let displayID: CGDirectDisplayID
    /// Region in display-relative points with a top-left origin, or nil for the whole display.
    public let sourceRect: CGRect?
    public let outputURL: URL
    /// Output size in pixels; both dimensions are even.
    public let pixelSize: CGSize
    public let captureMic: Bool
    public let captureSystemAudio: Bool

    public init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?,
        outputURL: URL,
        pixelSize: CGSize,
        captureMic: Bool,
        captureSystemAudio: Bool
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.outputURL = outputURL
        self.pixelSize = pixelSize
        self.captureMic = captureMic
        self.captureSystemAudio = captureSystemAudio
    }
}
