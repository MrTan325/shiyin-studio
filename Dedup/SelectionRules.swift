import Foundation

enum BatchCriterion: String,CaseIterable { case folder="文件夹", size="文件大小", duration="歌曲时长", similarity="相似程度", nameKeyword="文件名关键词", nameLength="文件名长度" }
enum BatchOrder: String,CaseIterable {case smaller="较小 / 较短的副本",larger="较大 / 较长的副本",range="指定范围"}
enum BatchAction:String,CaseIterable {case select="勾选匹配文件",deselect="取消匹配文件勾选"}
struct BatchRequest {
    var action:BatchAction = .select
    var criterion:BatchCriterion = .folder
    var folder=""
    var order:BatchOrder = .smaller
    var minimum:Double=0
    var maximum:Double=Double.greatestFiniteMagnitude
    var similarity:Float=0.94
    var nameKeywords=[String]()
    var requireAllKeywords=false
}
struct BatchResult {let paths:Set<String>;let protected:Int;let proposed:Int}
enum SelectionRules {
    static func nameLength(_ song:SongPrint) -> Int {
        URL(fileURLWithPath:song.path).deletingPathExtension().lastPathComponent.count
    }
    static func parseKeywords(_ text:String) -> [String] {
        text.components(separatedBy:CharacterSet(charactersIn:",，;；\n\r"))
            .map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
    }
    static func apply(_ request:BatchRequest,matches:[Match],existing:Set<String>) -> BatchResult {
        var desired=Set<String>()
        func smaller(_ a:SongPrint,_ b:SongPrint,_ duration:Bool) -> SongPrint {
            let x=duration ? a.duration:Double(a.size),y=duration ? b.duration:Double(b.size)
            if x==y {return a.path<b.path ? a:b};return x<y ? a:b
        }
        for m in matches {
            let a=m.first,b=m.second
            switch request.criterion {
            case .folder:
                let base=URL(fileURLWithPath:request.folder).standardizedFileURL.path
                guard !request.folder.isEmpty else {continue}
                for song in [a,b] where song.path.hasPrefix(base=="/" ? "/":base+"/") {desired.insert(song.path)}
            case .nameKeyword:
                let words=request.nameKeywords.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
                guard !words.isEmpty else {continue}
                for song in [a,b] {
                    let checks=words.map {song.name.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) != nil}
                    if request.requireAllKeywords ? checks.allSatisfy({$0}):checks.contains(true) {desired.insert(song.path)}
                }
            case .size,.duration,.nameLength:
                let duration=request.criterion == .duration
                if request.order == .range {
                    for song in [a,b] {
                        let value:Double
                        if request.criterion == .nameLength {value=Double(nameLength(song))}
                        else {value=duration ? song.duration:Double(song.size)/1048576}
                        if value>=request.minimum && value<=request.maximum {desired.insert(song.path)}
                    }
                } else {
                    let small:SongPrint
                    if request.criterion == .nameLength {
                        let x=nameLength(a),y=nameLength(b)
                        small = x==y ? (a.path<b.path ? a:b):(x<y ? a:b)
                    } else {small=smaller(a,b,duration)}
                    desired.insert(request.order == .smaller ? small.path:(small.path==a.path ? b.path:a.path))
                }
            case .similarity:
                if m.score>=request.similarity {desired.insert(smaller(a,b,false).path)}
            }
        }
        if request.criterion == .nameKeyword && request.action == .deselect {
            return BatchResult(paths:existing.subtracting(desired),protected:0,proposed:desired.count)
        }
        var result=existing.union(desired)
        // Every displayed edge retains an unselected endpoint, including chains and triangles.
        for m in matches.sorted(by:{$0.first.path+$0.second.path < $1.first.path+$1.second.path}) {
            if result.contains(m.first.path) && result.contains(m.second.path) {
                let a=m.first,b=m.second
                let keep:SongPrint
                if desired.contains(a.path) != desired.contains(b.path) {keep=desired.contains(a.path) ? b:a}
                else if a.size != b.size {keep=a.size>b.size ? a:b}
                else if a.duration != b.duration {keep=a.duration>b.duration ? a:b}
                else {keep=a.path<b.path ? a:b}
                result.remove(keep.path)
            }
        }
        return BatchResult(paths:result,protected:existing.union(desired).subtracting(result).count,proposed:desired.count)
    }
}
