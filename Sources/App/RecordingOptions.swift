import Foundation

/// The choices made in the record control panel. They persist in `UserDefaults` so the panel
/// reopens with the last values.
public struct RecordingOptions: Equatable {
    public enum Area: String {
        case fullscreen
        case section
    }

    public var area: Area
    public var microphone: Bool
    public var systemAudio: Bool

    public init(area: Area = .fullscreen, microphone: Bool = false, systemAudio: Bool = false) {
        self.area = area
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    static let areaKey = "recording.area"
    static let microphoneKey = "recording.microphone"
    static let systemAudioKey = "recording.systemAudio"

    /// Reads saved options; missing or unknown values fall back to the defaults.
    public static func load(from defaults: UserDefaults) -> RecordingOptions {
        var options = RecordingOptions()
        if let raw = defaults.string(forKey: areaKey), let area = Area(rawValue: raw) {
            options.area = area
        }
        options.microphone = defaults.bool(forKey: microphoneKey)
        options.systemAudio = defaults.bool(forKey: systemAudioKey)
        return options
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(area.rawValue, forKey: Self.areaKey)
        defaults.set(microphone, forKey: Self.microphoneKey)
        defaults.set(systemAudio, forKey: Self.systemAudioKey)
    }
}
