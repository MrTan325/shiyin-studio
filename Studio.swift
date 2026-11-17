import AppKit
import SwiftUI
import Combine

/// Keeps explicit file selection distinct from a recursive directory scope.
enum StudioInput {
    static func songs(_ urls:[URL])->[URL] {
        var seen=Set<String>()
        return urls.map{$0.standardizedFileURL}.filter{url in
            guard fileKind(url.pathExtension.lowercased())=="audio",AudioEngine.extensions.contains(url.pathExtension.lowercased()),
                  let info=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
                  info.isRegularFile==true,info.isSymbolicLink != true else{return false}
            return seen.insert(canonicalPath(url.path)).inserted
        }
    }
}

final class StudioController:NSViewController {
    let search:SearchController
    let model:Model
    weak var app:AppDelegate?
    private var hosting:NSHostingController<ContentView>!
    private let tabs=NSSegmentedControl(labels:["文件搜索","歌曲查重"],trackingMode:.selectOne,target:nil,action:nil)
    private let allButton=NSButton(title:"检索目录查重",target:nil,action:nil)
    private let importButton=NSButton(title:"导入原拾音目录…",target:nil,action:nil)
    private let summary=NSTextField(labelWithString:"搜索与查重共用目录入口 · 音频仅在本机处理")
    private var subscriptions=Set<AnyCancellable>()
    init(search:SearchController,model:Model,app:AppDelegate){self.search=search;self.model=model;self.app=app;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError()}
    override func loadView(){
        view=NSView()
        tabs.target=self;tabs.action=#selector(switchPage);tabs.selectedSegment=0;tabs.segmentStyle = .rounded
        allButton.target=self;allButton.action=#selector(allRoots);allButton.bezelStyle = .rounded
        importButton.target=self;importButton.action=#selector(importRoots);importButton.bezelStyle = .rounded
        summary.font = .systemFont(ofSize:11);summary.textColor = .secondaryLabelColor
        let top=NSStackView(views:[tabs,summary,NSView(),importButton,allButton]);top.spacing=14;top.alignment = .centerY
        top.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(top)
        let content=NSView();content.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(content)
        hosting=NSHostingController(rootView:ContentView(model:model))
        for child in [search as NSViewController,hosting!] {
            addChild(child);child.view.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(child.view)
            NSLayoutConstraint.activate([child.view.topAnchor.constraint(equalTo:content.topAnchor),child.view.bottomAnchor.constraint(equalTo:content.bottomAnchor),child.view.leadingAnchor.constraint(equalTo:content.leadingAnchor),child.view.trailingAnchor.constraint(equalTo:content.trailingAnchor)])
        }
        hosting.view.isHidden=true
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo:view.topAnchor,constant:12),top.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:18),top.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-18),top.heightAnchor.constraint(equalToConstant:32),content.topAnchor.constraint(equalTo:top.bottomAnchor,constant:10),content.bottomAnchor.constraint(equalTo:view.bottomAnchor),content.leadingAnchor.constraint(equalTo:view.leadingAnchor),content.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        model.$busy.receive(on:RunLoop.main).sink{[weak self] busy in
            self?.allButton.isEnabled = !busy;self?.importButton.isEnabled = !busy
            self?.summary.stringValue=busy ? "歌曲查重正在后台进行 · 可切换搜索，文件移动和重命名暂不可用":"搜索与查重共用目录入口 · 音频仅在本机处理"
        }.store(in:&subscriptions)
    }
    @objc private func switchPage(){show(tabs.selectedSegment)}
    func showSearch(){show(0)}
    func showDedup(){show(1)}
    private func show(_ page:Int){
        _=view;tabs.selectedSegment=page;search.view.isHidden=page != 0;hosting.view.isHidden=page != 1
        if page==0{search.focusSearch()}else{search.view.window?.makeFirstResponder(nil)}
        model.mixer.pause()
    }
    @objc private func allRoots(){app?.sendToDedup(app?.roots.map{URL(fileURLWithPath:$0)} ?? [],selectedOnly:false)}
    @objc private func importRoots(){
        guard let app,!app.fileChangesBlocked else{return}
        let legacy=UserDefaults.standard.persistentDomain(forName:"com.mrtan.mediasearch")?["SearchRoots"] as? [String] ?? []
        guard !legacy.isEmpty else{app.alert("未找到原拾音搜索保存的目录。请在搜索页点击“检索目录…”添加。");return}
        let panel=NSAlert();panel.messageText="导入原拾音的检索目录？"
        panel.informativeText="只导入目录设置，本试用版会建立独立索引。\n\n"+legacy.joined(separator:"\n")
        panel.addButton(withTitle:"导入目录");panel.addButton(withTitle:"取消")
        if panel.runModal() == .alertFirstButtonReturn {app.saveRoots(Array(Set(app.roots+legacy)));showSearch()}
    }
}
extension AppDelegate {
    func sendToDedup(_ urls:[URL],selectedOnly:Bool){
        guard !fileChangesBlocked else{alert("请先停止当前查重或等待文件操作完成，再更换查重范围。");return}
        let scope=selectedOnly ? StudioInput.songs(urls):urls
        guard !scope.isEmpty else{alert(selectedOnly ? "请选择受支持的歌曲文件。视频和其他文件不会送入歌曲查重。":"请先添加检索目录。");return}
        if selectedOnly && scope.count<2{alert("请至少选择两首受支持的歌曲，再进行相互查重。");return}
        if dedup.hasScanned || !dedup.matches.isEmpty {
            let dialog=NSAlert();dialog.messageText="更换查重范围？";dialog.informativeText="将清除当前查重结果和勾选，不移动任何文件。";dialog.addButton(withTitle:"更换范围");dialog.addButton(withTitle:"取消")
            guard dialog.runModal() == .alertFirstButtonReturn else{return}
        }
        dedup.invalidateAfterFileChange();dedup.folders=scope
        dedup.phase="查重范围已准备";dedup.status=selectedOnly ? "仅比对所选的 \(scope.count) 首歌曲；点击开始频谱扫描":"已导入 \(scope.count) 个检索目录；点击开始频谱扫描"
        quickPopover?.performClose(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);studio.showDedup()
    }
}
