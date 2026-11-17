import Foundation

/// Counts exact eligible pairs once; stores consecutive j indices as 12-byte ranges.
/// The denominator is fixed before any CPU/GPU/cache scoring begins.
final class CandidatePlan {
    let url:URL
    private(set) var count=0
    init(directory:URL)throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        url=directory.appendingPathComponent("pairs-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else{throw AudioError.message("无法建立比对任务清单")}
    }
    func build(songs:[SongPrint],checkpoint:()->Bool,progress:(Int,Int)->Void)throws {
        guard songs.count<=Int(UInt32.max) else{throw AudioError.message("文件数超出任务索引范围")}
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()}
        count=0;try handle.truncate(atOffset:0)
        var buffer=Data();buffer.reserveCapacity(65532)
        let engine=AudioEngine(),overall=songs.map{AudioEngine().normalize($0.spectrum)}
        func writeRange(_ i:Int,_ start:Int,_ end:Int)throws {
            for value in [i,start,end] {var word=UInt32(value).littleEndian;withUnsafeBytes(of:&word){buffer.append(contentsOf:$0)}}
            if buffer.count>=65532 {try handle.write(contentsOf:buffer);buffer.removeAll(keepingCapacity:true)}
        }
        if songs.count>1 {
            for i in 0..<(songs.count-1) {
                guard checkpoint() else{throw CancellationError()}
                var first:Int?=nil,last=0
                for j in (i+1)..<songs.count {
                    if j%128==0 && !checkpoint(){throw CancellationError()}
                    if songs[j].duration-songs[i].duration>max(20,songs[i].duration*0.12){break}
                    if engine.cosine(overall[i],overall[j])>0.92 {
                        if first==nil {first=j};last=j+1;count+=1
                    } else if let start=first {try writeRange(i,start,last);first=nil}
                }
                if let start=first {try writeRange(i,start,last)}
                if i%16==0{progress(i+1,songs.count-1)}
            }
        }
        if !buffer.isEmpty{try handle.write(contentsOf:buffer)}
        progress(max(0,songs.count-1),max(0,songs.count-1))
    }
    func buildFast(records:[IndexedSong],repository:FingerprintRepository,directory:URL,checkpoint:()->Bool,progress:(String,Int,Int)->Void)throws->FastSearchStats {
        guard records.count<Int(UInt32.max) else{throw AudioError.message("文件数超出任务索引范围")}
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()}
        count=0;try handle.truncate(atOffset:0)
        var buffer=Data();buffer.reserveCapacity(65532)
        let stats=try FastCandidateBuilder.build(records:records,repository:repository,directory:directory,checkpoint:checkpoint,progress:progress,emit:{i,j in
            for value in [i,j,j+1]{var word=UInt32(value).littleEndian;withUnsafeBytes(of:&word){buffer.append(contentsOf:$0)}}
            count+=1
            if buffer.count>=65532 {try handle.write(contentsOf:buffer);buffer.removeAll(keepingCapacity:true)}
        })
        if !buffer.isEmpty{try handle.write(contentsOf:buffer)}
        return stats
    }
    func forEach(checkpoint:()->Bool,_ action:(AudioPair)throws->Void)throws {
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        while let bytes=try handle.read(upToCount:65532),!bytes.isEmpty {
            guard bytes.count%12==0 else{throw AudioError.message("比对任务清单不完整")}
            for offset in stride(from:0,to:bytes.count,by:12) {
                func read(_ at:Int)->Int {Int(UInt32(littleEndian:bytes.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:at,as:UInt32.self)}))}
                let i=read(offset),start=read(offset+4),end=read(offset+8)
                guard start>i,end>=start else{throw AudioError.message("比对任务索引错误")}
                for j in start..<end {
                    guard checkpoint() else{throw CancellationError()}
                    try action(AudioPair(first:i,second:j))
                }
            }
        }
    }

    deinit{try? FileManager.default.removeItem(at:url)}
}
