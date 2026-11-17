import Foundation
import Darwin

let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "caf", "aiff", "aif", "flac", "alac", "ogg", "opus", "wma"]
let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "mpeg", "mpg", "ts", "mts"]
func fileKind(_ ext: String) -> String { audioExtensions.contains(ext) ? "audio" : videoExtensions.contains(ext) ? "video" : "other" }
func canonicalPath(_ path: String) -> String {
    var candidate = URL(fileURLWithPath:path).standardizedFileURL.path
    var suffix = [String]()
    while true {
        if let resolved = realpath(candidate, nil) {
            defer { free(resolved) }
            let base = String(cString:resolved)
            return suffix.reversed().reduce(base) { ($0 == "/" ? "" : $0) + "/" + $1 }
        }
        if candidate == "/" { return path }
        suffix.append((candidate as NSString).lastPathComponent)
        candidate = (candidate as NSString).deletingLastPathComponent
    }
}
func isWithin(_ path: String, _ directory: String) -> Bool { path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/") }
func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased() }
struct FileRecord {
    var path: String
    var name: String
    var ext: String
    var kind: String
    var size: Int64
    var modified: Double
    var duration: Double = 0
    var bpm = ""
    var key = ""
    var bitrate: Double = 0
    var resolution = ""
    var fps: Double = 0
    var metadataState = "pending"
    var url: URL { URL(fileURLWithPath: path) }
    var durationText: String {
        guard duration > 0, duration.isFinite else { return "—" }
        let seconds = Int(duration)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var bitrateText: String { bitrate > 0 ? String(format: "%.0f kbps", bitrate / 1000) : "—" }
}
struct SearchResult { let files: [FileRecord]; let total: Int; let elapsed: Double }
struct MediaInfo {
    var duration: Double = 0
    var bpm = ""
    var key = ""
    var bitrate: Double = 0
    var resolution = ""
    var fps: Double = 0
    var state = "ready"
}
