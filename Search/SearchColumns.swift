import AppKit

enum SearchColumns {
    static let definitions:[(id:String,title:String,width:CGFloat)] = [
        ("name","文件名",280),("bpm","BPM",70),("key","KEY",70),("duration","时长",85),
        ("resolution","分辨率",120),("fps","FPS",70),("bitrate","码率",105),
        ("ext","格式",75),("size","文件大小",100),("path","文件位置",430)
    ]
    static let key="SearchHiddenColumns.v1"
    static let changed=Notification.Name("ShiyinSearchColumnVisibilityChanged")
    static func hidden(in defaults:UserDefaults = .standard)->Set<String> {
        let allowed=Set(definitions.map{$0.id}).subtracting(["name"])
        return Set(defaults.stringArray(forKey:key) ?? []).intersection(allowed)
    }
    static func save(_ hidden:Set<String>,in defaults:UserDefaults = .standard){
        let allowed=Set(definitions.map{$0.id}).subtracting(["name"])
        defaults.set(hidden.intersection(allowed).sorted(),forKey:key)
        NotificationCenter.default.post(name:changed,object:nil)
    }
}
final class ColumnMenuHeaderView:NSTableHeaderView {
    var makeColumnMenu:(()->NSMenu)?
    override func menu(for event:NSEvent)->NSMenu? {makeColumnMenu?() ?? super.menu(for:event)}
}
