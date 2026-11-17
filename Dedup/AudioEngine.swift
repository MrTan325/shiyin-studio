import Foundation
import AVFoundation
import Accelerate

struct SongPrint: Codable, Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Double
    let duration: Double
    let frames: [[Float]]
    let spectrum: [Float]
    var note: String? = nil
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct Match: Identifiable {
    let id = UUID()
    let first: SongPrint
    let second: SongPrint
    let score: Float
    let offset: Int
}
enum AudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
final class AudioEngine {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4"]
    static let version = 4
    let sampleRate: Double = 8000
    let fftSize = 2048
    let bandCount = 48
    func fingerprint(_ url: URL, cancelled: () -> Bool = { false }) throws -> SongPrint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        let channels = Int(format.channelCount)
        guard sourceRate > 0, channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw AudioError.message("无法解码音频") }
        let duration = Double(file.length) / sourceRate
        guard duration >= 8 else { throw AudioError.message("音频短于 8 秒，跳过") }
        // Decode the entire recording while retaining only a small PCM working buffer.
        let limit = file.length
        let accumulator = try SpectrumAccumulator()
        var samples = [Float](); samples.reserveCapacity(32768)
        // Windowed box averaging before decimation reduces aliasing without loading the entire track.
        var nextOutput = sourceRate / sampleRate
        var position: Double = 0
        var sum: Float = 0
        var count: Float = 0
        var tailNote: String? = nil
        var readFrames: AVAudioFramePosition = 0
        while readFrames < limit {
            if cancelled() { throw CancellationError() }
            let requested = AVAudioFrameCount(min(32768, limit - readFrames))
            do {
                try file.read(into: buffer, frameCount: requested)
            } catch {
                let ns = error as NSError
                let remaining = Double(limit - readFrames) / sourceRate
                // Some MP3 decoders report an inaccurate final frame count and throw
                // nilError at EOF. Only tolerate this specific error within 100 ms
                // of the physical track end, after substantial successful decoding.
                if ns.domain == "Foundation._GenericObjCError", ns.code == 0,
                   limit == file.length, readFrames >= AVAudioFramePosition(sourceRate * 8),
                   remaining >= 0, remaining <= 0.1 {
                    tailNote = String(format:"系统解码器无法读取末尾约 %.3f 秒；已使用此前正常读取的音频完成分析，请试听核对。", remaining)
                    break
                }
                throw AudioError.message("读取音频失败（已读取 \(String(format: "%.1f", Double(readFrames) / sourceRate)) 秒）：\(ns.localizedDescription) [\(ns.domain):\(ns.code)]")
            }
            if buffer.frameLength == 0 {
                let missing=Double(limit-readFrames)/sourceRate
                if missing>0.1 {throw AudioError.message("音频提前结束，缺少约 \(String(format:"%.2f",missing)) 秒，未将其作为完整歌曲分析")}
                if missing>0 {tailNote=String(format:"音频末尾约 %.3f 秒未能读取，已分析此前内容。",missing)}
                break
            }
            guard let data = buffer.floatChannelData else {throw AudioError.message("无法读取单精度音频数据")}
            readFrames += AVAudioFramePosition(buffer.frameLength)
            for i in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<channels { value += data[channel][i] }
                value /= Float(channels)
                sum += value; count += 1; position += 1
                if position >= nextOutput {
                    samples.append(sum / max(count, 1)); sum = 0; count = 0
                    nextOutput += sourceRate / sampleRate
                    if samples.count >= 32768 {
                        try accumulator.append(samples, cancelled: cancelled)
                        samples.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        try accumulator.append(samples, cancelled: cancelled)
        let result = accumulator.finish()
        guard result.frames.count >= 6 else { throw AudioError.message("有效音频不足或接近静音") }
        return SongPrint(path: url.path, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                         modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                         duration: duration, frames: result.frames, spectrum: result.spectrum, note: tailNote)
    }
    func describe(_ samples: [Float], cancelled: () -> Bool = { false }) throws -> (frames: [[Float]], spectrum: [Float]) {
        let accumulator = try SpectrumAccumulator()
        try accumulator.append(samples, cancelled: cancelled)
        return accumulator.finish()
    }
    func normalize(_ values: [Float]) -> [Float] {
        let mean = values.reduce(0, +) / Float(max(values.count, 1))
        let centered = values.map { $0 - mean }
        let magnitude = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        if magnitude < 0.0001 { return values.map { _ in 0 } }
        return centered.map { $0 / magnitude }
    }
    func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count,b.count) { sum += a[i] * b[i] }
        return sum
    }
    func compare(_ a: SongPrint, _ b: SongPrint, cancelled: ()->Bool = {false}) -> (score: Float, offset: Int)? {
        guard abs(a.duration - b.duration) <= max(20, min(a.duration, b.duration) * 0.12) else { return nil }
        let count = min(a.frames.count, b.frames.count)
        guard count >= 6 else { return nil }
        var best: Float = -1; var bestOffset = 0
        // Compare time-varying spectra, not only the overall tonal balance.
        for offset in -20...20 {
            if cancelled() {return nil}
            let startA = max(0, -offset), startB = max(0, offset)
            let overlap = min(a.frames.count - startA, b.frames.count - startB)
            guard overlap >= max(6, Int(Float(count) * 0.75)) else { continue }
            var spectral: Float = 0; var changes: Float = 0; var changeCount = 0
            for i in 0..<overlap {
                if i % 64 == 0 && cancelled() {return nil}
                spectral += cosine(a.frames[startA + i], b.frames[startB + i])
                if i > 0 {
                    let x=a.frames[startA+i],y=b.frames[startB+i]
                    let previousX=a.frames[startA+i-1],previousY=b.frames[startB+i-1]
                    var aa:Float=0,bb:Float=0,dd:Float=0
                    for band in 0..<min(x.count,y.count) {
                        let dx=x[band]-previousX[band],dy=y[band]-previousY[band]
                        aa+=dx*dx;bb+=dy*dy;dd+=dx*dy
                    }
                    let ma=sqrt(aa),mb=sqrt(bb)
                    if ma>0.015 && mb>0.015 {changes+=dd/(ma*mb);changeCount+=1}
                }
            }
            let shape = spectral / Float(overlap)
            let movement = changeCount >= max(3,overlap/5) ? max(0, changes / Float(changeCount)) : 0
            let score = max(0,min(1,shape * 0.55 + movement * 0.45))
            if score > best { best = score; bestOffset = offset }
        }
        return best >= 0 ? (best, bestOffset) : nil
    }
}
