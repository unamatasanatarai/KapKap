import Foundation

/// Output locations for recordings: `~/Movies/<AppName>/Screen Recording YYYY-MM-DD at HH.MM.SS.mp4`.
public enum RecordingFileNamer {
    public static let fileExtension = "mp4"

    public static func defaultFolder(appName: String = AppConfig.appName) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent(appName, isDirectory: true)
    }

    /// "Screen Recording 2026-11-06 at 21.05.03" in the given time zone.
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date))"
    }

    /// The first free name in `folder`, appending " 2", " 3", ... on collision.
    public static func url(
        for date: Date,
        in folder: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) -> URL {
        let base = baseName(for: date, timeZone: timeZone)
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    /// Hidden in-progress file next to the final one: `.<name>.mp4.part`.
    public static func partURL(for finalURL: URL) -> URL {
        return finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).part")
    }
}
