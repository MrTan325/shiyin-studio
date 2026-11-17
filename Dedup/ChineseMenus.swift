import AppKit

/// Keep AppKit/SwiftUI-generated menus Chinese without changing system language,
/// menu actions, keyboard shortcuts, first-responder validation or window titles.
final class ChineseMenus:NSObject,NSApplicationDelegate {
    private var observers=[NSObjectProtocol](),queued=false,translating=false
    func applicationDidFinishLaunching(_ notification:Notification){
        for name in [NSMenu.didAddItemNotification,NSMenu.didChangeItemNotification,NSMenu.didBeginTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.schedule()})
        }
        schedule()
    }
    func applicationDidBecomeActive(_ notification:Notification){schedule()}
    private func schedule(){
        guard !queued && !translating else{return};queued=true
        DispatchQueue.main.async{[weak self] in guard let self=self else{return};self.queued=false;self.translating=true
            if let menu=NSApp.mainMenu {self.translate(menu)}
            self.translating=false
        }
    }
    func translate(_ menu:NSMenu){
        for item in menu.items {
            let title=Self.localized(item.title)
            if title != item.title {item.title=title}
            if let submenu=item.submenu {translate(submenu)}
        }
    }
    static func localized(_ title:String)->String {
        let words:[String:String]=[
            "File":"文件","Edit":"编辑","View":"显示","Window":"窗口","Help":"帮助","Format":"格式","Tingwen":"听纹歌曲查重",
            "Undo":"撤销","Redo":"重做","Cut":"剪切","Copy":"拷贝","Paste":"粘贴","Delete":"删除","Select All":"全选",
            "Paste and Match Style":"粘贴并匹配样式","Paste and Preserve Style":"粘贴并保留样式","Find":"查找","Find…":"查找…","Find...":"查找…",
            "Find Next":"查找下一个","Find Previous":"查找上一个","Use Selection for Find":"使用所选内容查找","Jump to Selection":"跳到所选内容",
            "Spelling and Grammar":"拼写和语法","Show Spelling and Grammar":"显示拼写和语法","Check Document Now":"立即检查文稿","Check Spelling While Typing":"键入时检查拼写","Check Grammar With Spelling":"检查拼写时检查语法","Correct Spelling Automatically":"自动纠正拼写",
            "Substitutions":"替换","Show Substitutions":"显示替换","Smart Copy/Paste":"智能拷贝/粘贴","Smart Quotes":"智能引号","Smart Dashes":"智能破折号","Smart Links":"智能链接","Data Detectors":"数据检测器","Text Replacement":"文本替换",
            "Transformations":"转换","Make Upper Case":"变为大写","Make Lower Case":"变为小写","Capitalize":"首字母大写","Speech":"语音","Start Speaking":"开始朗读","Stop Speaking":"停止朗读",
            "Start Dictation…":"开始听写…","Start Dictation...":"开始听写…","Emoji & Symbols":"表情与符号","Services":"服务","Hide Others":"隐藏其他","Show All":"全部显示",
            "Minimize":"最小化","Zoom":"缩放","Bring All to Front":"前置全部窗口","Close":"关闭","Close Window":"关闭窗口",
            "Enter Full Screen":"进入全屏幕","Exit Full Screen":"退出全屏幕","Show Toolbar":"显示工具栏","Hide Toolbar":"隐藏工具栏","Customize Toolbar…":"自定工具栏…","Customize Toolbar...":"自定工具栏…",
            "Show Sidebar":"显示边栏","Hide Sidebar":"隐藏边栏","Show Tab Bar":"显示标签页栏","Hide Tab Bar":"隐藏标签页栏","Show All Tabs":"显示所有标签页","Exit Tab Overview":"退出标签页概览","Show Previous Tab":"显示上一个标签页","Show Next Tab":"显示下一个标签页","Move Tab to New Window":"将标签页移到新窗口","Merge All Windows":"合并所有窗口",
            "Settings…":"设置…","Preferences…":"偏好设置…","Settings...":"设置…","Preferences...":"偏好设置…"
        ]
        if let value=words[title]{return value}
        for (prefix,localized) in [("About ","关于 "),("Hide ","隐藏 "),("Quit ","退出 ")] {
            if title.hasPrefix(prefix){return localized+title.dropFirst(prefix.count)}
        }
        if title.hasSuffix(" Help"){return String(title.dropLast(5))+" 帮助"}
        return title
    }
    deinit{for token in observers{NotificationCenter.default.removeObserver(token)}}
}
