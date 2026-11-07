import Foundation

/// Turns recordings left unfinished by a crash, force quit or power loss into visible files.
///
/// An in-progress recording is the hidden `.<name>.mp4.part` next to its final name. Recordings are
/// written as fragmented MP4, so such a leftover plays up to its last fragment; it only needs a
/// visible `.mp4` name (AVFoundation picks the format from the extension).
public enum RecordingRecovery {
    /// A leftover touched more recently than this may still be written by another running instance
    /// (fragments are flushed every 2 s), so it is left alone.
    public static let minimumIdleTime: TimeInterval = 30

    /// Renames every idle leftover in `folder` to "<name> (recovered).mp4" (made unique), removes empty
    /// ones, and returns the recovered files.
    @discardableResult
    public static func recoverUnfinished(
        in folder: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        var recovered: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let finalName = finalName(forPartFile: entry.lastPathComponent) else { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < minimumIdleTime {
                continue
            }
            if (values?.fileSize ?? 0) == 0 {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let destination = uniqueURL(for: finalName, in: folder, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: entry, to: destination)
                recovered.append(destination)
            } catch {
                NSLog("%@ could not recover %@: %@", AppConfig.appName, entry.lastPathComponent,
                      error.localizedDescription)
            }
        }
        return recovered
    }

    /// ".Screen Recording X.mp4.part" → "Screen Recording X (recovered).mp4"; nil for other files.
    static func finalName(forPartFile name: String) -> String? {
        let suffix = ".\(RecordingFileNamer.fileExtension).part"
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
        let base = String(name.dropFirst().dropLast(suffix.count))
        return "\(base) (recovered).\(RecordingFileNamer.fileExtension)"
    }

    private static func uniqueURL(for name: String, in folder: URL, fileManager: FileManager) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }
}
