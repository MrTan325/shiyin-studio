import Foundation

/// Compact, recording-oriented time/frequency contrast codes derived from the full
/// existing descriptor. No network and no file-name similarity is used for retrieval.
struct FastFingerprint:Codable {
    let schema:Int
    let identity:String
    let codes:[UInt32]
    let fallback:Bool
    static func make(_ record:IndexedSong,repository:FingerprintRepository,checkpoint:()->Bool)throws->FastFingerprint {
        let song=try repository.load(record)
        var codes=[UInt32]();codes.reserveCapacity(song.frames.count)
        for t in song.frames.indices {
            if t%64==0 && !checkpoint(){throw CancellationError()}
            let left=song.frames[max(0,t-2)],right=song.frames[min(song.frames.count-1,t+2)]
            var code:UInt32=0
            for bit in 0..<32 {
                let band=2+bit*43/32
                let contrast=(right[band]-left[band])-(right[band+1]-left[band+1])
                if contrast>0 {code |= UInt32(1)<<UInt32(bit)}
            }
            let entropy=code.nonzeroBitCount
            codes.append(entropy>=4 && entropy<=28 ? code:0)
        }
        let useful=codes.filter{$0 != 0}
        return FastFingerprint(schema:1,identity:record.identity,codes:codes,
            fallback:useful.count<max(8,codes.count/10) || Set(useful).count<8)
    }
    static func load(_ record:IndexedSong,repository:FingerprintRepository,directory:URL,checkpoint:()->Bool)throws->FastFingerprint {
        guard checkpoint() else{throw CancellationError()}
        let url=directory.appendingPathComponent(record.identity+".plist")
        if let bytes=try? Data(contentsOf:url),let value=try? PropertyListDecoder().decode(FastFingerprint.self,from:bytes),value.schema==1,value.identity==record.identity,value.codes.count==record.frameCount {return value}
        let value=try make(record,repository:repository,checkpoint:checkpoint)
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        try encoder.encode(value).write(to:url,options:.atomic)
        return value
    }
    static func keys(_ code:UInt32)->[UInt16] {
        [UInt16(code&4095),UInt16(4096+((code>>10)&4095)),UInt16(8192+((code>>20)&4095))]
    }
}

struct FastSearchStats {
    var songs=0,postings=0,commonBuckets=0,fallbackSongs=0,candidates=0,stride=2
    var description:String {"快速索引：\(songs) 首 · 候选 \(candidates) 对 · 保守回退 \(fallbackSongs) 首"}
}
private struct FastPosting {let song:UInt32;let second:UInt32;let code:UInt32}
private final class FastBucket {
    var postings=[FastPosting]()
    var documents=0,lastSong:UInt32?=nil,ignored=false
    func add(_ value:FastPosting,limit:Int){
        if ignored{return}
        if lastSong != value.song {documents+=1;lastSong=value.song}
        if documents>limit{ignored=true;postings=[];return}
        postings.append(value)
    }
}
private struct FastVoteKey:Hashable {let song:Int;let offsetBin:Int}
private struct FastVote {
    var count=0,lastSecond = -1,regions:UInt8=0,first=Int.max,last=0
    mutating func add(_ second:Int,duration:Double){
        guard second != lastSecond else{return};lastSecond=second;count+=1
        regions |= UInt8(1)<<UInt8(min(2,Int(Double(second)/max(1,duration)*3)))
        first=min(first,second);last=max(last,second)
    }
}

/// One index of sampled anchors; queries examine every second to tolerate offsets
/// that do not coincide with the anchor sampling interval. Very common keys are
/// excluded; low-information/short tracks use the original conservative filter.
enum FastCandidateBuilder {
    static func build(records:[IndexedSong],repository:FingerprintRepository,directory:URL,
        checkpoint:()->Bool,progress:(String,Int,Int)->Void,
        emit:(Int,Int)throws->Void)throws->FastSearchStats {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var stats=FastSearchStats();stats.songs=records.count
        let totalFrames=records.reduce(Int64(0)){$0+Int64($1.frameCount)}
        let step=max(2,Int(ceil(Double(totalFrames)*3/1_000_000)))
        stats.stride=step
        let commonLimit=max(40,records.count/30)
        let shortLimit=max(40,Double(step*4))
        var buckets=[UInt16:FastBucket]();buckets.reserveCapacity(12288)
        var fallback=Set<Int>()
        for (i,record) in records.enumerated() {
            guard checkpoint() else{throw CancellationError()}
            try autoreleasepool {
                let fingerprint=try FastFingerprint.load(record,repository:repository,directory:directory,checkpoint:checkpoint)
                if fingerprint.fallback || record.song.duration<shortLimit {fallback.insert(i)}
                for t in Swift.stride(from:0,to:fingerprint.codes.count,by:step) {
                    let code=fingerprint.codes[t];if code==0{continue}
                    let posting=FastPosting(song:UInt32(i),second:UInt32(t),code:code)
                    for key in FastFingerprint.keys(code) {
                        let bucket:FastBucket
                        if let existing=buckets[key]{bucket=existing}else{bucket=FastBucket();buckets[key]=bucket}
                        bucket.add(posting,limit:commonLimit)
                    }
                }
            }
            progress("建立快速时序指纹索引",i+1,records.count)
        }
        for bucket in buckets.values {bucket.postings.sort{$0.second<$1.second}}
        // If suppression leaves too little evidence, conservatively retain original screening.
        for (i,record) in records.enumerated() where !fallback.contains(i) {
            let fingerprint=try FastFingerprint.load(record,repository:repository,directory:directory,checkpoint:checkpoint)
            var retained=0
            for t in Swift.stride(from:0,to:fingerprint.codes.count,by:step) {
                let code=fingerprint.codes[t]
                if code != 0 && FastFingerprint.keys(code).contains(where:{buckets[$0]?.ignored == false}){retained+=1}
            }
            if retained<8 {fallback.insert(i)}
        }
        stats.postings=buckets.values.reduce(0){$0+$1.postings.count}
        stats.commonBuckets=buckets.values.filter{$0.ignored}.count;stats.fallbackSongs=fallback.count
        let engine=AudioEngine(),overall=records.map{AudioEngine().normalize($0.song.spectrum)}
        func eligible(_ a:Int,_ b:Int)->Bool {
            let first=records[a].song,second=records[b].song
            return abs(first.duration-second.duration)<=max(20,min(first.duration,second.duration)*0.12)
                && engine.cosine(overall[a],overall[b])>0.92
        }
        for (q,record) in records.enumerated() {
            guard checkpoint() else{throw CancellationError()}
            var candidates=Set<Int>()
            if fallback.contains(q) {
                if q>0 {for other in 0..<q {if other%128==0 && !checkpoint(){throw CancellationError()};if eligible(other,q){candidates.insert(other)}}}
            } else {
                for other in fallback where other<q {if eligible(other,q){candidates.insert(other)}}
                let fingerprint=try FastFingerprint.load(record,repository:repository,directory:directory,checkpoint:checkpoint)
                var votes=[FastVoteKey:FastVote]()
                var eligibleMemo=[Int:Bool]()
                for (t,code) in fingerprint.codes.enumerated() {
                    if t%16==0 && !checkpoint(){throw CancellationError()}
                    if code==0 {continue}
                    for key in FastFingerprint.keys(code) {
                        guard let bucket=buckets[key],!bucket.ignored else{continue}
                        var lo=0,hi=bucket.postings.count
                        let earliest=max(0,t-20)
                        while lo<hi {let mid=(lo+hi)/2;if Int(bucket.postings[mid].second)<earliest{lo=mid+1}else{hi=mid}}
                        for posting in bucket.postings[lo...] {
                            if Int(posting.second)>t+20{break}
                            let other=Int(posting.song)
                            if other>=q || fallback.contains(other){continue}
                            let offset=t-Int(posting.second)
                            if abs(offset)>20 || (code^posting.code).nonzeroBitCount>8 {continue}
                            let permitted:Bool
                            if let known=eligibleMemo[other]{permitted=known}else{permitted=eligible(other,q);eligibleMemo[other]=permitted}
                            if !permitted{continue}
                            let voteKey=FastVoteKey(song:other,offsetBin:(offset+20)/2)
                            votes[voteKey,default:FastVote()].add(t,duration:record.song.duration)
                        }
                    }
                }
                for (key,vote) in votes {
                    let expected=min(record.song.duration,records[key.song].song.duration)/Double(step)
                    let required=max(3,min(8,Int(expected*0.2)))
                    if vote.count>=required && vote.regions.nonzeroBitCount>=2
                        && Double(vote.last-vote.first)>=min(60,record.song.duration*0.35) {
                        candidates.insert(key.song)
                    }
                }
            }
            for other in candidates.sorted(){try emit(other,q);stats.candidates+=1}
            progress("检索快速指纹候选",q+1,records.count)
        }
        return stats
    }
}
