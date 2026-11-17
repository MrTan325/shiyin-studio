import Foundation
import CryptoKit

struct IndexedSong:Codable {
    let song:SongPrint
    let identity:String
    let frameCount:Int
    let cacheURL:URL
    let cacheSize:Int64
    let cacheModified:Double
    let schema:Int
    init(_ full:SongPrint,cacheURL:URL) {
        self.schema=1
        self.song=SongPrint(path:full.path,size:full.size,modified:full.modified,duration:full.duration,frames:[],spectrum:full.spectrum,note:full.note)
        self.identity=PairCache.identity(full);self.frameCount=full.frames.count;self.cacheURL=cacheURL
        let attrs=try? FileManager.default.attributesOfItem(atPath:cacheURL.path)
        cacheSize=(attrs?[.size] as? NSNumber)?.int64Value ?? 0
        cacheModified=(attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
    func saveSummary() {
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        if let data=try? encoder.encode(self) {try? data.write(to:cacheURL.appendingPathExtension("index"),options:.atomic)}
    }
    static func summary(_ url:URL,path:String,size:Int64,modified:Double)->IndexedSong? {
        guard let data=try? Data(contentsOf:url.appendingPathExtension("index")),
          let value=try? PropertyListDecoder().decode(IndexedSong.self,from:data),
          value.schema==1,value.song.frames.isEmpty,value.song.spectrum.count==48,value.song.path==path,value.song.size==size,value.song.modified==modified,
          value.frameCount>=6,value.identity.count==64,value.cacheURL==url,
          let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),
          (attrs[.size] as? NSNumber)?.int64Value==value.cacheSize,
          (attrs[.modificationDate] as? Date)?.timeIntervalSince1970==value.cacheModified else{return nil}
        return value
    }
}

/// Full descriptors live on disk. Only a byte-budgeted LRU is retained between batches.
final class FingerprintRepository {
    private struct Entry {let song:SongPrint;let bytes:Int;var used:Int}
    private let lock=NSLock()
    private var entries=[String:Entry](),clock=0
    private(set) var residentBytes=0
    let budget:Int
    init(budget:Int=48*1024*1024) {self.budget=max(0,budget)}
    func load(_ record:IndexedSong) throws -> SongPrint {
        lock.lock();defer{lock.unlock()};clock+=1
        if var entry=entries[record.song.path] {entry.used=clock;entries[record.song.path]=entry;return entry.song}
        let value:SongPrint=try autoreleasepool {
            let attrs=try FileManager.default.attributesOfItem(atPath:record.cacheURL.path)
            guard (attrs[.size] as? NSNumber)?.int64Value==record.cacheSize,
              (attrs[.modificationDate] as? Date)?.timeIntervalSince1970==record.cacheModified else {throw AudioError.message("指纹缓存已改变，请重新扫描")}
            let bytes=try Data(contentsOf:record.cacheURL)
            let value=try PropertyListDecoder().decode(SongPrint.self,from:bytes)
            guard value.path==record.song.path,value.size==record.song.size,value.modified==record.song.modified,value.frames.count==record.frameCount,value.spectrum.count==48,value.frames.allSatisfy({$0.count==48}) else {throw AudioError.message("指纹缓存已变化，请重新扫描：\(record.song.path)")}
            return value
        }
        let weight=value.frames.reduce(0){$0+$1.count*MemoryLayout<Float>.stride+32}
        if weight<=budget {
            while residentBytes+weight>budget,let oldest=entries.min(by:{$0.value.used<$1.value.used}) {
                residentBytes-=oldest.value.bytes;entries.removeValue(forKey:oldest.key)
            }
            entries[record.song.path]=Entry(song:value,bytes:weight,used:clock);residentBytes+=weight
        }
        return value
    }
}

/// Coalesces arbitrarily many worker events into one pending main-queue update.
final class ProgressRelay:@unchecked Sendable {
    private let lock=NSLock()
    private var action:(()->Void)?
    private var pending=false,closed=false
    let interval:Double
    init(interval:Double=0.15){self.interval=interval}
    func submit(_ update:@escaping ()->Void) {
        lock.lock()
        guard !closed else {lock.unlock();return}
        action=update
        if pending {lock.unlock();return}
        pending=true;lock.unlock()
        DispatchQueue.main.asyncAfter(deadline:.now()+interval) {[weak self] in
            guard let self=self else{return}
            self.lock.lock();let work=self.closed ? nil:self.action
            self.action=nil;self.pending=false;self.lock.unlock();work?()
        }
    }
    func close(){lock.lock();closed=true;action=nil;lock.unlock()}
}

final class ScanIssues:@unchecked Sendable {
    private let lock=NSLock();private var messages=[String]();private var omitted=0
    func record(_ value:String){lock.lock();defer{lock.unlock()};if messages.count<200 {messages.append(value)} else {omitted+=1}}
    func take()->[String]{lock.lock();defer{lock.unlock()};let value=messages+(omitted>0 ? ["另有 \(omitted) 次类似比对读取问题"]:[]);messages=[];omitted=0;return value}
}
