import Foundation
import AVFoundation
import CoreMedia

/// Reads tags and technical headers only. Never decodes a song to guess BPM/key.
enum MediaReader {
    static var ffprobePath: String? {
        ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read(_ file: FileRecord) async -> MediaInfo {
        if let path = ffprobePath, let info = probe(file.url, executable: path) { return info }
        let asset = AVURLAsset(url: file.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var info = MediaInfo()
        let seconds = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        if seconds.isFinite && seconds > 0 { info.duration = seconds }
        let tracks = (try? await asset.load(.tracks)) ?? []
        for track in tracks {
            let rate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            if rate.isFinite { info.bitrate += max(0,rate) }
            if track.mediaType == .video {
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                info.resolution = "\(Int(abs(rect.width).rounded())) × \(Int(abs(rect.height).rounded()))"
                info.fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            }
        }
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            for item in (try? await asset.loadMetadata(for: format)) ?? [] {
                let id = ((item.identifier?.rawValue ?? "") + " " + String(describing: item.key ?? "" as NSString)).lowercased()
                let stringValue = try? await item.load(.stringValue)
                let numberValue = try? await item.load(.numberValue)
                let value = stringValue ?? numberValue?.stringValue ?? ""
                if id.contains("tbpm") || id.contains("tmpo") || id.contains("bpm") || id.contains("tempo") { if !value.isEmpty { info.bpm = value } }
                if id.contains("tkey") || id.contains("initialkey") || id.contains("initial_key") || id.hasSuffix("/key") { if !value.isEmpty { info.key = value } }
            }
        }
        let tags = readTags(file.url)
        if let bpm = tags["BPM"] ?? tags["TBPM"] ?? tags["TEMPO"] { info.bpm = bpm }
        if let key = tags["INITIALKEY"] ?? tags["KEY"] ?? tags["TKEY"] ?? tags["INITIAL_KEY"] { info.key = key }
        if info.bitrate == 0 && info.duration > 0 { info.bitrate = Double(file.size) * 8 / info.duration }
        if info.duration == 0 && tracks.isEmpty { info.state = "unsupported" }
        return info
    }
    private static func probe(_ url: URL, executable: String) -> MediaInfo? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-v", "error", "-show_entries", "format=duration,bit_rate:format_tags:stream=codec_type,width,height,avg_frame_rate,r_frame_rate,bit_rate:stream_tags", "-of", "json", url.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        // Drain concurrently so unusually large tag payloads cannot block the child.
        let output = OutputBuffer()
        let group = DispatchGroup()
        do { try process.run() } catch { return nil }
        group.enter()
        DispatchQueue.global(qos: .utility).async { output.data = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit(); group.wait()
        guard process.terminationStatus == 0, let object = try? JSONSerialization.jsonObject(with: output.data) as? [String:Any] else { return nil }
        var info = MediaInfo()
        func number(_ value: Any?) -> Double { if let x = value as? NSNumber { return x.doubleValue }; return Double(value as? String ?? "") ?? 0 }
        func tags(_ object: [String:Any]) {
            for (key,value) in object["tags"] as? [String:Any] ?? [:] {
                let name = key.uppercased()
                if ["BPM","TBPM","TEMPO"].contains(name) { info.bpm = String(describing: value) }
                if ["KEY","INITIALKEY","INITIAL_KEY","TKEY"].contains(name) { info.key = String(describing: value) }
            }
        }
        if let format = object["format"] as? [String:Any] { info.duration = number(format["duration"]); info.bitrate = number(format["bit_rate"]); tags(format) }
        for stream in object["streams"] as? [[String:Any]] ?? [] {
            tags(stream)
            if stream["codec_type"] as? String == "video" {
                info.resolution = "\(Int(number(stream["width"]))) × \(Int(number(stream["height"])))"
                let fraction = (stream["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
                if fraction.count == 2 && fraction[1] > 0 { info.fps = fraction[0] / fraction[1] }
            }
        }
        return info
    }
    private final class OutputBuffer { var data = Data() }

    static func readTags(_ url: URL) -> [String:String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }; defer { try? handle.close() }
        // Tag reading is bounded; no full-file mapping or document-content indexing.
        guard let header = try? handle.read(upToCount:10), header.count == 10 else { return [:] }
        let prefix = [UInt8](header)
        let isID3 = String(bytes:prefix.prefix(3),encoding:.ascii) == "ID3"
        let isFLAC = String(bytes:prefix.prefix(4),encoding:.ascii) == "fLaC"
        guard isID3 || isFLAC else { return [:] }
        let requested = isID3 ? min(2 * 1024 * 1024, 10 + (6..<10).reduce(0) { ($0 << 7) | Int(prefix[$1] & 127) }) : 2 * 1024 * 1024
        try? handle.seek(toOffset:0)
        guard let data = try? handle.read(upToCount:requested), data.count >= 10 else { return [:] }
        let bytes = [UInt8](data)
        if String(bytes: bytes.prefix(3), encoding: .ascii) == "ID3" { return id3(bytes) }
        if String(bytes: bytes.prefix(4), encoding: .ascii) == "fLaC" { return flac(bytes) }
        return [:]
    }
    private static func decode(_ bytes: [UInt8]) -> String {
        guard let encoding = bytes.first else { return "" }; let data = Data(bytes.dropFirst())
        let value: String?
        switch encoding {
        case 0: value = String(data: data, encoding: .isoLatin1)
        case 1: value = String(data: data, encoding: .utf16)
        case 2: value = String(data: data, encoding: .utf16BigEndian)
        default: value = String(data: data, encoding: .utf8)
        }
        return (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n\r"))
    }
    private static func id3(_ bytes: [UInt8]) -> [String:String] {
        let version = bytes[3]; guard version == 3 || version == 4 else { return [:] }
        // Extended/unsynchronised tags are left to AVFoundation/ffprobe.
        guard bytes[5] & 0xC0 == 0 else { return [:] }
        func sync(_ start: Int) -> Int { (0..<4).reduce(0) { ($0 << 7) | Int(bytes[start + $1] & 127) } }
        let end = min(bytes.count,10 + sync(6)); var offset = 10; var result = [String:String]()
        while offset + 10 <= end {
            let key = String(bytes: bytes[offset..<offset+4], encoding: .ascii) ?? ""
            let length = version == 4 ? sync(offset+4) : (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset+4+$1]) }
            guard length > 0, length <= end - offset - 10 else { break }
            if bytes[offset+8] == 0 && bytes[offset+9] == 0 {
                let value = decode(Array(bytes[offset+10..<offset+10+length]))
                if key == "TBPM" || key == "TKEY" { result[key] = value }
                if key == "TXXX", let separator = value.firstIndex(of: "\0") {
                    let name = String(value[..<separator]).uppercased()
                    result[name] = String(value[value.index(after: separator)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                }
            }
            offset += 10 + length
        }
        return result
    }
    private static func flac(_ bytes: [UInt8]) -> [String:String] {
        var offset = 4; var result = [String:String]()
        func little(_ p: Int) -> Int { (0..<4).reduce(0) { $0 | (Int(bytes[p+$1]) << ($1*8)) } }
        while offset + 4 <= bytes.count {
            let type = bytes[offset] & 127; let last = bytes[offset] & 128 != 0
            let length = Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3]); offset += 4
            guard length <= bytes.count - offset else { break }
            if type == 4 {
                let end = offset + length; var p = offset
                guard p+4 <= end else { break }; let vendorLength = little(p); p += 4
                guard vendorLength <= end-p else { break }; p += vendorLength
                guard p+4 <= end else { break }; let count = little(p); p += 4
                for _ in 0..<min(count,10000) {
                    guard p+4 <= end else { break }; let size = little(p); p += 4
                    guard size <= end-p else { break }
                    if let entry = String(bytes: bytes[p..<p+size],encoding: .utf8), let split = entry.firstIndex(of: "=") { result[String(entry[..<split]).uppercased()] = String(entry[entry.index(after: split)...]) }
                    p += size
                }
            }
            offset += length
            if last { break }
        }
        return result
    }
}
