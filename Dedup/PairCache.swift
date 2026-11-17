import Foundation
import CryptoKit
import SQLite3

/// Stores all candidate scores, including rejected pairs, independently of UI thresholds.
final class PairCache {
    private let cancelled:()->Bool
    private var db: OpaquePointer?
    private let lock=NSLock()
    private var read:OpaquePointer?,write:OpaquePointer?
    private(set) var hits=0
    private(set) var misses=0
    private var writes=0
    static func identity(_ song:SongPrint) -> String {
        var hash=SHA256()
        hash.update(data:Data("full-v4-score-v1|\(song.path)|\(song.size)|\(song.modified)|\(song.duration)|".utf8))
        for frame in song.frames {frame.withUnsafeBytes{hash.update(bufferPointer:$0)}}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func key(_ a:String,_ b:String)->(String,Bool) {a<=b ? (a+":"+b,false):(b+":"+a,true)}
    init(_ url:URL,cancelled:@escaping ()->Bool = {false}) throws {
        self.cancelled=cancelled
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {throw AudioError.message("无法打开比对缓存")}
        let context=Unmanaged.passUnretained(self).toOpaque()
        sqlite3_busy_handler(db,{context,attempt in
            guard let context=context else{return 0}
            let owner=Unmanaged<PairCache>.fromOpaque(context).takeUnretainedValue()
            if owner.cancelled() || attempt>=100 {return 0}
            Thread.sleep(forTimeInterval:0.01);return 1
        },context)
        sqlite3_progress_handler(db,1000,{context in
            guard let context=context else{return 0}
            return Unmanaged<PairCache>.fromOpaque(context).takeUnretainedValue().cancelled() ? 1:0
        },context)
        guard sqlite3_exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS pairs(k TEXT PRIMARY KEY,score REAL NOT NULL,offset INTEGER NOT NULL,used INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS pairs_used ON pairs(used);",nil,nil,nil)==SQLITE_OK,
          sqlite3_prepare_v2(db,"SELECT score,offset FROM pairs WHERE k=?",-1,&read,nil)==SQLITE_OK,
          sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO pairs VALUES(?,?,?,strftime('%s','now'))",-1,&write,nil)==SQLITE_OK else {throw AudioError.message("无法初始化比对缓存")}
    }
    private func bind(_ statement:OpaquePointer?,_ key:String) {
        sqlite3_bind_text(statement,1,key,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
    }
    func lookup(_ a:String,_ b:String)->PairScore? {
        lock.lock();defer{lock.unlock()}
        if cancelled(){return nil}
        let (k,reverse)=Self.key(a,b);sqlite3_reset(read);sqlite3_clear_bindings(read);bind(read,k)
        guard sqlite3_step(read)==SQLITE_ROW else {misses+=1;return nil}
        hits+=1
        return PairScore(score:Float(sqlite3_column_double(read,0)),offset:Int(sqlite3_column_int(read,1))*(reverse ? -1:1))
    }
    private func put(_ a:String,_ b:String,_ value:PairScore) {
        guard value.score.isFinite else{return}
        let(k,reverse)=Self.key(a,b);sqlite3_reset(write);sqlite3_clear_bindings(write);bind(write,k)
        sqlite3_bind_double(write,2,Double(value.score));sqlite3_bind_int(write,3,Int32(value.offset*(reverse ? -1:1)))
        if sqlite3_step(write)==SQLITE_DONE {writes+=1}
    }
    func store(_ a:String,_ b:String,_ value:PairScore) {
        lock.lock();defer{lock.unlock()};put(a,b,value)
    }
    func storeBatch(_ values:[(String,String,PairScore)]) {
        guard !values.isEmpty && !cancelled() else{return}
        lock.lock();defer{lock.unlock()}
        let transaction=sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK
        for(a,b,score) in values {if cancelled(){break};put(a,b,score)}
        if transaction {sqlite3_exec(db,"COMMIT",nil,nil,nil)}
    }
    func prune() {
        lock.lock();defer{lock.unlock()}
        guard writes>0 else{return}
        sqlite3_exec(db,"DELETE FROM pairs WHERE k IN (SELECT k FROM pairs ORDER BY used DESC LIMIT -1 OFFSET 500000)",nil,nil,nil)
    }
    deinit {sqlite3_busy_handler(db,nil,nil);sqlite3_progress_handler(db,0,nil,nil);sqlite3_finalize(read);sqlite3_finalize(write);sqlite3_close(db)}
}
