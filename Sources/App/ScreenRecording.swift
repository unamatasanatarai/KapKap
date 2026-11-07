import Foundation

/// The capture contract the coordinator depends on, so tests can substitute a fake.
/// Implementations must call every completion and handler on the main queue.
public protocol ScreenRecording: AnyObject {
    /// Called at most once per recording when capture or writing fails mid-recording (the stream
    /// stopped, the writer failed). The owner should then call `stop` to salvage what was recorded.
    var onInterruption: ((Error) -> Void)? { get set }
    func start(_ config: RecordingConfig, completion: @escaping (Result<Void, Error>) -> Void)
    /// Finishes the file and returns its URL (the config's `outputURL`). On failure the partial file is deleted.
    func stop(completion: @escaping (Result<URL, Error>) -> Void)
}
