import AppKit
import QuickLookUI
import SwiftUI
import Combine

final class FileTable: NSTableView {
    var preview: (() -> Void)?
    var openFile: (() -> Void)?
    var cutFiles: (() -> Void)?
    var copyFiles: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var renameFile: (() -> Void)?
    @objc func cut(_ sender:Any?) { cutFiles?() }
    @objc func copy(_ sender:Any?) { copyFiles?() }
    @objc func paste(_ sender:Any?) { pasteFiles?() }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if window?.firstResponder === self && event.modifierFlags.intersection([.command,.option,.control,.shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": cutFiles?(); return true
            case "c": copyFiles?(); return true
            case "v": pasteFiles?(); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with:event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120 { renameFile?(); return }
        if event.keyCode == 49 { preview?(); return }
        if event.keyCode == 36 { openFile?(); return }
        super.keyDown(with:event)
    }
}

final class SearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation {
    let db: Database
    weak var app: AppDelegate?
    let search = NSSearchField()
    let table = FileTable()
    private let footer = NSTextField(labelWithString:"添加检索目录以开始")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString:"选择文件后按空格预览；双击打开，⌘R 在 Finder 中显示")
    private let category = NSSegmentedControl(labels:["全部文件","歌曲","视频","其他"],trackingMode:.selectOne,target:nil,action:nil)
    private let scope = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let queryQueue = DispatchQueue(label:"MediaSearch.search",qos:.userInitiated)
    private var work: DispatchWorkItem?
    private var serial = 0
    private var rows = [FileRecord]()
    private var draggedURLs = [URL]()
    private var total = 0
    private var elapsed: Double = 0
    private var sortKey = "name"
    private var ascending = true
    private var indexedStatus = "就绪"
    private var columnObserver:NSObjectProtocol?
    private let compact: Bool
    init(db: Database, app: AppDelegate, compact: Bool = false) { self.db = db; self.app = app; self.compact = compact; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        let title = NSTextField(labelWithString:compact ? "拾音工作台" : "拾音工作台")
        title.font = .systemFont(ofSize:compact ? 19 : 25,weight:.bold)
        let subtitle = NSTextField(labelWithString:"文件即刻可寻，媒体信息一目了然")
        subtitle.font = .systemFont(ofSize:12); subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views:[title,subtitle]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 5
        let operations = NSPopUpButton(frame:.zero,pullsDown:true)
        operations.addItem(withTitle:"文件操作")
        let operationsMenu = operations.menu!
        addFileOperationItems(to:operationsMenu)
        let dedupButton=NSButton(title:"所选歌曲查重",target:self,action:#selector(sendSelectedToDedup))
        dedupButton.bezelStyle = .rounded
        dedupButton.toolTip="仅把选中的受支持歌曲送入查重，不扩大到所在文件夹"
        let pathsButton = NSButton(title:"检索目录…",target:self,action:#selector(settings))
        pathsButton.bezelStyle = .rounded
        let refreshButton = NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"更新索引")!,target:self,action:#selector(rescan))
        refreshButton.bezelStyle = .rounded; refreshButton.toolTip = "重新扫描检索目录"
        let header = NSStackView(views:[titleStack,NSView(),dedupButton,operations,refreshButton,pathsButton]); header.alignment = .centerY
        search.placeholderString = "搜索文件名，多个关键词用空格分隔…"; search.font = .systemFont(ofSize:17)
        search.controlSize = .large; search.delegate = self; search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        // NSSearchField sends this action on every edit, not just Return.
        // Incremental search must never transfer keyboard focus to the results.
        search.target = self; search.action = #selector(searchChanged)
        search.heightAnchor.constraint(equalToConstant:42).isActive = true
        category.selectedSegment = 0; category.target = self; category.action = #selector(filterChanged); category.segmentStyle = .rounded
        scope.target = self; scope.action = #selector(filterChanged); scope.toolTip = "限制到一个检索目录"
        let hint = NSTextField(labelWithString:"空格 预览  ↵ 打开  F2 重命名"); hint.textColor = .tertiaryLabelColor; hint.font = .systemFont(ofSize:11)
        let filters = NSStackView(views:[category,scope,NSView(),hint]); filters.spacing = 12
        let definitions=SearchColumns.definitions
        for (id,title,width) in definitions {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 160 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key:id,ascending:true); table.addTableColumn(column)
        }
        let columnHeader=ColumnMenuHeaderView(frame:NSRect(x:0,y:0,width:1,height:24))
        columnHeader.makeColumnMenu = { [weak self] in self?.columnMenu() ?? NSMenu() }
        columnHeader.toolTip="右键选择显示或隐藏列；点击列标题排序"
        table.headerView=columnHeader
        applyColumnVisibility()
        columnObserver=NotificationCenter.default.addObserver(forName:SearchColumns.changed,object:nil,queue:.main){[weak self] _ in self?.applyColumnVisibility()}
        table.dataSource = self; table.delegate = self; table.rowHeight = 35; table.usesAlternatingRowBackgroundColors = true; table.style = .fullWidth
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask([.copy,.move],forLocal:false)
        table.setDraggingSourceOperationMask([],forLocal:true)
        table.target = self; table.doubleAction = #selector(openSelected)
        table.preview = { [weak self] in self?.togglePreview() }; table.openFile = { [weak self] in self?.openSelected() }
        table.cutFiles = { [weak self] in self?.cutSelectedFiles() }
        table.copyFiles = { [weak self] in self?.copySelectedFiles() }
        table.pasteFiles = { [weak self] in self?.pasteSelectedFiles() }
        table.renameFile = { [weak self] in self?.renameSelectedFile() }
        let menu = NSMenu()
        menu.addItem(withTitle:"打开文件",action:#selector(openSelected),keyEquivalent:"").target = self
        menu.addItem(withTitle:"空格预览",action:#selector(previewSelected),keyEquivalent:"").target = self
        menu.addItem(withTitle:"在 Finder 中显示",action:#selector(revealSelected),keyEquivalent:"").target = self
        menu.addItem(withTitle:"复制文件路径",action:#selector(copyPath),keyEquivalent:"").target = self
        menu.addItem(withTitle:"所选歌曲查重",action:#selector(sendSelectedToDedup),keyEquivalent:"").target=self
        menu.addItem(.separator())
        addFileOperationItems(to:menu)
        table.menu = menu
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.autohidesScrollers = true
        emptyLabel.stringValue = "添加检索目录，开始寻找你的文件"; emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize:16,weight:.medium); emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo:scroll.centerXAnchor),emptyLabel.centerYAnchor.constraint(equalTo:scroll.centerYAnchor)])
        detail.font = .systemFont(ofSize:11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        footer.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); footer.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let bottom = NSStackView(views:[spinner,footer,NSView()]); bottom.spacing = 7
        let stack = NSStackView(views:[header,search,filters,scroll,detail,bottom]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        for item in [header,search,filters,scroll,detail,bottom] { item.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:view.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-14),stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-22),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150)])
        reloadScopes(); runSearch()

    }
    deinit{if let observer=columnObserver{NotificationCenter.default.removeObserver(observer)}}
    func columnMenu()->NSMenu {
        let menu=NSMenu(title:"显示列")
        for column in table.tableColumns {
            let item=NSMenuItem(title:column.title,action:#selector(toggleColumn(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=column.identifier.rawValue
            item.state=column.isHidden ? .off:.on;item.isEnabled=column.identifier.rawValue != "name"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle:"显示全部列",action:#selector(showAllColumns),keyEquivalent:"").target=self
        return menu
    }
    @objc func toggleColumn(_ sender:NSMenuItem){
        guard let id=sender.representedObject as? String,id != "name" else{return}
        var hidden=SearchColumns.hidden();if hidden.contains(id){hidden.remove(id)}else{hidden.insert(id)}
        SearchColumns.save(hidden)
    }
    @objc func showAllColumns(){SearchColumns.save([])}
    func applyColumnVisibility(){
        let hidden=SearchColumns.hidden()
        for column in table.tableColumns{column.isHidden=hidden.contains(column.identifier.rawValue)}
        if hidden.contains(sortKey){table.sortDescriptors=[NSSortDescriptor(key:"name",ascending:true)]}
    }
    override func viewDidAppear() { super.viewDidAppear(); focusSearch() }
    func focusSearch() { view.window?.makeFirstResponder(search) }
    func reloadScopes() {
        guard isViewLoaded else { return }; let old = scope.selectedItem?.representedObject as? String
        scope.removeAllItems(); scope.addItem(withTitle:"所有检索目录")
        for root in app?.roots ?? [] { scope.addItem(withTitle:URL(fileURLWithPath:root).lastPathComponent); scope.lastItem?.representedObject = root; scope.lastItem?.toolTip = root }
        if let old, let item = scope.itemArray.first(where:{ ($0.representedObject as? String) == old }) { scope.select(item) }
        runSearch()
    }
    func setStatus(_ text:String) { indexedStatus = text; updateFooter() }
    private func updateFooter() { footer.stringValue = "\(total.formatted()) 个匹配\(total > rows.count ? " · 显示前 \(rows.count.formatted()) 个，请缩小搜索范围" : "")  ·  \(String(format:"%.1f",elapsed*1000)) ms  ·  \(indexedStatus)" }
    func controlTextDidChange(_ obj:Notification) { runSearch(delay:0.08) }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchSubmit(); return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !rows.isEmpty {
            searchSubmit(); return true
        }
        return false
    }
    @objc private func searchChanged() { runSearch(delay:0.08) }
    private func searchSubmit() { if !rows.isEmpty { view.window?.makeFirstResponder(table); if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) } } }
    @objc private func filterChanged() { runSearch() }
    func runSearch(delay:Double = 0, showSpinner:Bool = true) {
        guard isViewLoaded else { return }; work?.cancel(); serial += 1; let request = serial
        let text = search.stringValue; let kind = ["all","audio","video","other"][max(0,category.selectedSegment)]
        let root = scope.selectedItem?.representedObject as? String; let sort = sortKey; let asc = ascending
        if showSpinner { spinner.startAnimation(nil) }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let result = self.db.search(text,kind:kind,root:root,sort:sort,ascending:asc)
            DispatchQueue.main.async {
                guard request == self.serial else { return }
                let selected = Set(self.selectedFiles.map { $0.path })
                self.rows = result.files; self.total = result.total; self.elapsed = result.elapsed
                self.table.reloadData()
                self.emptyLabel.isHidden = !self.rows.isEmpty
                self.emptyLabel.stringValue = self.app?.roots.isEmpty == true ? "点击右上角“检索目录”，添加需要搜索的文件夹" : "没有匹配的文件；新目录可能仍在建立索引"
                let indexes = IndexSet(self.rows.indices.filter { selected.contains(self.rows[$0].path) })
                self.table.selectRowIndexes(indexes,byExtendingSelection:false)
                self.spinner.stopAnimation(nil); self.updateFooter()
            }
        }
        work = item; queryQueue.asyncAfter(deadline:.now()+delay,execute:item)
    }
    func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int) -> NSPasteboardWriting? {
        guard app?.fileChangesBlocked == false, rows.indices.contains(row) else { return nil }
        let url = rows[row].url
        guard let values = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url as NSURL
    }
    func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,willBeginAt screenPoint:NSPoint,forRowIndexes rowIndexes:IndexSet) {
        draggedURLs = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].url : nil }
        app?.beginFileDrag()
    }
    func tableView(_ tableView:NSTableView,draggingSession session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
        // The receiving app performs the operation; never delete drag sources here.
        app?.indexer.filesChanged(draggedURLs.map { $0.path })
        draggedURLs.removeAll(); app?.endFileDrag()
    }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let file = rows[row]; let text:String
        let unavailable = file.metadataState == "pending" && file.kind != "other" ? "读取中" : "—"
        switch id {
        case "name": text = file.name
        case "bpm": text = file.kind == "audio" ? (file.bpm.isEmpty ? unavailable : file.bpm) : "—"
        case "key": text = file.kind == "audio" ? (file.key.isEmpty ? unavailable : file.key) : "—"
        case "duration": text = file.duration > 0 ? file.durationText : unavailable
        case "resolution": text = file.resolution.isEmpty ? (file.kind == "video" ? unavailable : "—") : file.resolution
        case "fps": text = file.fps > 0 ? String(format:"%.3g",file.fps) : (file.kind == "video" ? unavailable : "—")
        case "bitrate": text = file.bitrate > 0 ? file.bitrateText : unavailable
        case "ext": text = file.ext.uppercased()
        case "size": text = file.sizeText
        default: text = file.url.deletingLastPathComponent().path
        }
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableCellView ?? makeCell(id)
        cell.textField?.stringValue = text; cell.textField?.textColor = id == "name" ? .labelColor : .secondaryLabelColor
        cell.toolTip = id == "name" || id == "path" ? file.path : text
        if id == "name" { cell.imageView?.image = NSImage(systemSymbolName:file.kind == "audio" ? "music.note" : file.kind == "video" ? "film" : "doc",accessibilityDescription:nil); cell.imageView?.contentTintColor = file.kind == "audio" ? .systemTeal : file.kind == "video" ? .systemPurple : .secondaryLabelColor }
        return cell
    }
    private func makeCell(_ id:String) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = NSUserInterfaceItemIdentifier(id)
        let label = NSTextField(labelWithString:""); label.font = .systemFont(ofSize:12); label.lineBreakMode = id == "path" ? .byTruncatingMiddle : .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        var left = cell.leadingAnchor
        if id == "name" {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:7),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:17),icon.heightAnchor.constraint(equalToConstant:17)])
            left = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:left,constant:8),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView:NSTableView,sortDescriptorsDidChange oldDescriptors:[NSSortDescriptor]) {
        if let sort = tableView.sortDescriptors.first { sortKey = sort.key ?? "name"; ascending = sort.ascending; runSearch() }
    }
    @objc func sendSelectedToDedup(){app?.sendToDedup(selectedFiles.map{$0.url},selectedOnly:true)}
    var selectedFiles:[FileRecord] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    var selectedFile:FileRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var actionFile:FileRecord? { selectedFile }
    func tableViewSelectionDidChange(_ notification:Notification) {
        if selectedFiles.count > 1 { detail.stringValue = "已选择 \(selectedFiles.count) 个文件 · ⌘X 剪切 · ⌘C 复制 · ⌘V 选择文件夹粘贴" }
        else if let f = selectedFile { detail.stringValue = f.path + (f.metadataState == "unsupported" ? "  · 系统无法读取此媒体；可安装 FFmpeg 扩展格式支持" : f.kind == "audio" && f.metadataState != "pending" && (f.bpm.isEmpty || f.key.isEmpty) ? "  · BPM / KEY 未写入标签的项目显示 —" : "") }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),panel.isVisible { panel.reloadData() }
    }
    @objc func openSelected() { if let file = actionFile { if !NSWorkspace.shared.open(file.url) { app?.alert("无法打开文件，请确认文件仍然存在，并已安装对应程序。") } } }
    @objc func revealSelected() { NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map { $0.url }) }
    @objc func copyPath() {
        guard !selectedFiles.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedFiles.map { $0.path }.joined(separator:"\n"),forType:.string)
    }
    private func addFileOperationItems(to menu:NSMenu) {
        for (title,action) in [("重命名…",#selector(renameSelectedFile)),("剪切",#selector(cutSelectedFiles)),("复制",#selector(copySelectedFiles)),("粘贴到文件夹…",#selector(pasteSelectedFiles)),("移动到…",#selector(moveSelectedFiles)),("拷贝到…",#selector(copySelectedFilesTo))] {
            menu.addItem(withTitle:title,action:action,keyEquivalent:"").target = self
        }
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleColumn(_:)){return menuItem.representedObject as? String != "name"}
        if menuItem.action == #selector(sendSelectedToDedup){return !selectedFiles.isEmpty && app?.fileChangesBlocked == false}
        if menuItem.action == #selector(renameSelectedFile) { return selectedFiles.count == 1 && app?.fileChangesBlocked == false }
        if menuItem.action == #selector(pasteSelectedFiles) { return app?.fileChangesBlocked == false && app?.fileClipboard.snapshot() != nil }
        if [#selector(cutSelectedFiles),#selector(copySelectedFiles),#selector(moveSelectedFiles),#selector(copySelectedFilesTo)].contains(menuItem.action) { return !selectedFiles.isEmpty && app?.fileChangesBlocked == false }
        if [#selector(openSelected),#selector(revealSelected),#selector(copyPath),#selector(previewSelected)].contains(menuItem.action) { return !selectedFiles.isEmpty }
        return true
    }
    @objc func renameSelectedFile() {
        guard selectedFiles.count == 1, let file = selectedFile else { return }
        app?.renameFile(file.url)
    }
    @objc func cutSelectedFiles() { stageFiles(mode:.move) }
    @objc func copySelectedFiles() { stageFiles(mode:.copy) }
    private func stageFiles(mode:TransferMode) {
        let urls = selectedFiles.map { $0.url }; guard !urls.isEmpty, app?.fileChangesBlocked == false else { return }
        guard app?.fileClipboard.write(urls,mode:mode) == true else { app?.alert("无法把文件写入剪贴板，请重试。"); return }
        app?.setTransferStatus("已\(mode == .move ? "剪切" : "复制") \(urls.count) 个文件；按 ⌘V 选择目标文件夹\(mode == .move ? "，粘贴成功后才会移走原文件" : "")")
    }
    @objc func pasteSelectedFiles() {
        guard let snapshot = app?.fileClipboard.snapshot(), app?.fileChangesBlocked == false else { return }
        app?.chooseTransfer(snapshot.urls,mode:snapshot.mode,snapshot:snapshot,initialDirectory:preferredTransferDirectory)
    }
    @objc func moveSelectedFiles() { app?.chooseTransfer(selectedFiles.map { $0.url },mode:.move,initialDirectory:preferredTransferDirectory) }
    @objc func copySelectedFilesTo() { app?.chooseTransfer(selectedFiles.map { $0.url },mode:.copy,initialDirectory:preferredTransferDirectory) }
    private var preferredTransferDirectory:URL? {
        if let path = UserDefaults.standard.string(forKey:"LastTransferDirectory") { return URL(fileURLWithPath:path,isDirectory:true) }
        return selectedFile?.url.deletingLastPathComponent()
    }
    @objc func previewSelected() { togglePreview() }
    func togglePreview() {
        guard selectedFile != nil,let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { view.window?.makeFirstResponder(table); panel.makeKeyAndOrderFront(nil); panel.reloadData() }
    }
    override func acceptsPreviewPanelControl(_ panel:QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel:QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel:QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel:QLPreviewPanel!) -> Int { selectedFile == nil ? 0 : 1 }
    func previewPanel(_ panel:QLPreviewPanel!,previewItemAt index:Int) -> QLPreviewItem! { selectedFile?.url as NSURL? }
    func previewPanel(_ panel:QLPreviewPanel!,handle event:NSEvent!) -> Bool {
        if event.type == .keyDown && event.keyCode == 49 { panel.orderOut(nil); return true }
        if event.type == .keyDown && [125,126].contains(event.keyCode) { table.keyDown(with:event); return true }
        return false
    }
    @objc private func settings() { app?.showSettings() }
    @objc private func rescan() { app?.indexer.rescan() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var window:NSWindow!
    let dedup=Model()
    var studio:StudioController!
    var fileChangesBlocked:Bool {isTransferring || dedup.busy}
    var quickPopover:NSPopover!
    let fileClipboard = FileClipboard()
    private(set) var isTransferring = false
    private let transferQueue = DispatchQueue(label:"ShiyinSearch.transfers",qos:.userInitiated)
    private var modalDepth = 0
    var controller:SearchController!
    var quickController:SearchController!
    var db:Database!
    var indexer:Indexer!
    private var statusItem:NSStatusItem!
    var roots:[String] {
        let paths = (UserDefaults.standard.stringArray(forKey:"SearchRoots") ?? []).map(canonicalPath).sorted { $0.count < $1.count }
        var result = [String]()
        for path in paths where !result.contains(where: { isWithin(path, $0) }) { result.append(path) }
        return result
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        do {
            let support = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ShiyinStudio",isDirectory:true)
            db = try Database(url:support.appendingPathComponent("index.sqlite")); indexer = Indexer(db:db,excluded:support.path)
        } catch { alert("索引初始化失败：\(error.localizedDescription)"); NSApp.terminate(nil); return }
        buildMenu()
        controller = SearchController(db:db,app:self)
        studio=StudioController(search:controller,model:dedup,app:self)
        dedup.onFilesChanged = { [weak self] in guard let self else{return};self.indexer.configure(self.roots) }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1380,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "拾音工作台"; window.contentViewController = studio; window.minSize = NSSize(width:1120,height:850); window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("MainWindow")
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:"拾音工作台")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked); statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp]); statusItem.button?.toolTip = "拾音工作台 · 点击弹出搜索，右键显示菜单"
        indexer.status = { [weak self] text in
            guard let self, !self.isTransferring else { return }; self.controller.setStatus(text); self.quickController?.setStatus(text)
        }
        indexer.updated = { [weak self] in self?.controller.runSearch(showSpinner:false); self?.quickController?.runSearch(showSpinner:false) }
        indexer.configure(roots)
        showMain()
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if dedup.busy { alert("查重仍在运行，请先停止查重再退出。");return .terminateCancel }
        if isTransferring { alert("文件传输正在进行，请完成后再退出。"); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { showMain(); return true }
    private func buildMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"关于拾音工作台",action:#selector(about),keyEquivalent:"").target = self
        appMenu.addItem(withTitle:"检索目录…",action:#selector(showSettings),keyEquivalent:",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"退出拾音工作台",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(); let edit = NSMenu(title:"编辑"); editItem.submenu = edit; main.addItem(editItem)
        for (title,selector,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title:"文件"); fileItem.submenu = fileMenu; main.addItem(fileItem)
        fileMenu.addItem(withTitle:"聚焦搜索",action:#selector(focus),keyEquivalent:"f").target = self
        fileMenu.addItem(withTitle:"在 Finder 中显示",action:#selector(reveal),keyEquivalent:"r").target = self
        fileMenu.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        NSApp.mainMenu = main
    }
    @objc func showMain() { quickPopover?.performClose(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); studio.showSearch() }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            quickPopover?.performClose(nil)
            let menu = NSMenu(); menu.addItem(withTitle:"打开主窗口",action:#selector(showMain),keyEquivalent:"").target = self
            menu.addItem(withTitle:"检索目录…",action:#selector(showSettings),keyEquivalent:"").target = self
            menu.addItem(.separator()); menu.addItem(withTitle:"退出拾音工作台",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil; return
        }
        guard let button = statusItem.button else { return }
        if quickPopover?.isShown == true { quickPopover.performClose(nil); return }
        if quickPopover == nil {
            quickController = SearchController(db:db,app:self,compact:true)
            _ = quickController.view
            quickPopover = NSPopover(); quickPopover.contentViewController = quickController
            quickPopover.contentSize = NSSize(width:860,height:500)
            quickPopover.behavior = .transient; quickPopover.animates = true; quickPopover.delegate = self
        }
        NSApp.activate(ignoringOtherApps:true)
        quickPopover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        quickPopover.contentViewController?.view.window?.makeKey()
        quickController.runSearch()
        DispatchQueue.main.async { self.quickController.focusSearch() }
    }
    func popoverShouldClose(_ popover:NSPopover) -> Bool {
        if modalDepth > 0 { return false }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { return false }
        return true
    }
    private var activeController:SearchController {
        if let quick = quickController, quickPopover?.isShown == true, NSApp.keyWindow === quick.view.window { return quick }
        return controller
    }
    @objc private func focus() { if quickPopover?.isShown != true {studio.showSearch()};activeController.focusSearch() }
    @objc private func reveal() { activeController.revealSelected() }
    @objc private func about() { alert("拾音工作台 0.1.3\n本地文件名索引 · 音视频信息 · Quick Look\n不检索文档正文，不上传文件。\nBPM / KEY 读取已有标签，不自动分析歌曲。\n整合文件搜索与听纹整首歌曲查重。支持 Apple 芯片 Mac，macOS 14 及以上。") }
    func alert(_ message:String) { let alert = NSAlert(); alert.messageText = "拾音工作台"; alert.informativeText = message; alert.addButton(withTitle:"知道了"); alert.runModal() }
    @objc func showSettings() {
        modalDepth += 1; defer { modalDepth -= 1 }
        let alert = NSAlert(); alert.messageText = "检索目录"; alert.informativeText = "选择需要搜索的文件夹。子目录自动包含；隐藏文件、符号链接与应用包内部默认跳过。\nBPM / KEY 读取已有标签；缺失显示 —。系统不支持的媒体可安装 FFmpeg 后重新读取。"
        alert.addButton(withTitle:"完成"); alert.addButton(withTitle:"添加目录…"); alert.addButton(withTitle:"移除选中目录"); alert.addButton(withTitle:"重新读取媒体信息")
        let list = NSTextView(frame:NSRect(x:0,y:0,width:620,height:180)); list.isEditable = false; list.isSelectable = true; list.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        list.string = roots.isEmpty ? "尚未添加目录。点击“添加目录…”开始。" : roots.joined(separator:"\n")
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:620,height:180)); scroll.documentView = list; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; alert.accessoryView = scroll
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.title = "添加检索目录"; panel.prompt = "添加目录"; panel.message = "只会建立这些目录的文件名与媒体信息索引"
            if panel.runModal() == .OK {
                var paths = roots
                for url in panel.urls { let path = url.standardizedFileURL.path; if !paths.contains(path) { paths.append(path) } }
                saveRoots(paths)
            }
            showSettings()
        } else if response == .alertThirdButtonReturn {
            let range = (list.string as NSString).lineRange(for:list.selectedRange())
            let selected = (list.string as NSString).substring(with:range).split(separator:"\n").map(String.init)
            saveRoots(roots.filter { !selected.contains($0) }); showSettings()
        } else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
            indexer.retryMedia(); alertInfoProbe()
        }
    }
    private func alertInfoProbe() { alert("已安排重新读取媒体信息。\n" + (MediaReader.ffprobePath.map { "已检测到 ffprobe：\($0)" } ?? "未检测到 ffprobe，使用 macOS AVFoundation。可通过 Homebrew 安装 ffmpeg 以扩展 MKV、FLAC、OGG 等格式支持。")) }
    func setTransferStatus(_ text:String) {
        controller.setStatus(text); quickController?.setStatus(text)
    }
    func beginFileDrag() { modalDepth += 1 }
    func endFileDrag() { modalDepth = max(0,modalDepth - 1);dedup.invalidateAfterFileChange();indexer.configure(roots) }
    func renameFile(_ source:URL) {
        guard !fileChangesBlocked else { return }
        modalDepth += 1; defer { modalDepth -= 1 }
        let dialog = NSAlert(); dialog.messageText = "重命名文件"
        dialog.informativeText = "请输入完整文件名（包含扩展名）。已有同名文件不会被覆盖。"
        dialog.addButton(withTitle:"重命名"); dialog.addButton(withTitle:"取消")
        let input = NSTextField(frame:NSRect(x:0,y:0,width:420,height:26))
        input.stringValue = source.lastPathComponent; dialog.accessoryView = input
        dialog.window.initialFirstResponder = input
        let stem = source.pathExtension.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        DispatchQueue.main.async {
            dialog.window.makeFirstResponder(input); input.selectText(nil)
            (input.currentEditor() as? NSTextView)?.selectedRange = NSRange(location:0,length:(stem as NSString).length)
        }
        guard dialog.runModal() == .alertFirstButtonReturn, !fileChangesBlocked else { return }
        let name = input.stringValue
        if name == source.lastPathComponent { return }
        if URL(fileURLWithPath:name).pathExtension != source.pathExtension {
            let warning = NSAlert(); warning.messageText = "要更改文件扩展名吗？"
            warning.informativeText = "更改扩展名可能影响默认打开方式和媒体类型识别。"
            warning.addButton(withTitle:"更改"); warning.addButton(withTitle:"取消")
            guard warning.runModal() == .alertFirstButtonReturn else { return }
        }
        dedup.invalidateAfterFileChange()
        isTransferring = true; setTransferStatus("正在重命名…")
        transferQueue.async { [self] in
            do {
                let destination = try FileOperations.rename(source,to:name)
                db.remove(path:canonicalPath(source.path))
                DispatchQueue.main.async {
                    self.isTransferring = false
                    self.setTransferStatus("已重命名为：" + destination.lastPathComponent)
                    self.indexer.filesChanged([source.path,destination.path])
                    self.controller.runSearch(); self.quickController?.runSearch()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTransferring = false; self.setTransferStatus("重命名失败")
                    self.modalDepth += 1; defer { self.modalDepth -= 1 }
                    self.alert("重命名失败：" + error.localizedDescription)
                }
            }
        }
    }
    func chooseTransfer(_ sources:[URL],mode:TransferMode,snapshot:FileClipboardSnapshot? = nil,initialDirectory:URL? = nil) {
        guard !sources.isEmpty, !fileChangesBlocked else { return }
        modalDepth += 1; defer { modalDepth -= 1 }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = mode == .move ? "移动文件" : "拷贝文件"
        panel.prompt = mode == .move ? "移动到此文件夹" : "拷贝到此文件夹"
        panel.message = "已选 \(sources.count) 个文件。请选择目标文件夹：\n" + sources.prefix(3).map { $0.lastPathComponent }.joined(separator:"、") + (sources.count > 3 ? " 等" : "")
        panel.directoryURL = initialDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        // A user can change the clipboard while choosing a folder. Never move stale cut items.
        if let snapshot, snapshot.mode == .move, NSPasteboard.general.changeCount != snapshot.changeCount {
            alert("剪贴板内容已变化，本次移动已取消。请重新剪切需要移动的文件。"); return
        }
        var conflicts = ConflictPolicy.keepBoth
        let hasConflict = sources.contains { source in
            let candidate = directory.appendingPathComponent(source.lastPathComponent)
            if mode == .move && canonicalPath(candidate.path) == canonicalPath(source.path) { return false }
            return FileManager.default.fileExists(atPath:candidate.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath:candidate.path)) != nil
        }
        if hasConflict {
            let alert = NSAlert(); alert.messageText = "目标文件夹有同名文件"
            alert.informativeText = "\(directory.path)\n\n“保留两者”会为新文件添加“（副本 1）”等后缀。“跳过同名”只处理没有冲突的文件。"
            alert.addButton(withTitle:"保留两者"); alert.addButton(withTitle:"跳过同名"); alert.addButton(withTitle:"取消")
            let result = alert.runModal()
            if result == .alertThirdButtonReturn { return }
            conflicts = result == .alertSecondButtonReturn ? .skip : .keepBoth
        }
        if let snapshot, snapshot.mode == .move, NSPasteboard.general.changeCount != snapshot.changeCount {
            alert("剪贴板内容已变化，本次移动已取消。请重新剪切需要移动的文件。"); return
        }
        UserDefaults.standard.set(directory.path,forKey:"LastTransferDirectory")
        if mode == .move {dedup.invalidateAfterFileChange()}
        isTransferring = true
        let verb = mode == .move ? "移动" : "拷贝"
        setTransferStatus("正在\(verb) \(sources.count) 个文件到 \(directory.path)…")
        transferQueue.async { [self] in
            let report = FileOperations.transfer(sources,to:directory,mode:mode,conflicts:conflicts) { done,total in
                DispatchQueue.main.async { self.setTransferStatus("正在\(verb) · \(done)/\(total) 个文件 · \(directory.path)") }
            }
            // Remove only files the transfer actually moved. Rescan reconciles destinations.
            if mode == .move { for item in report.completed { db.remove(path:canonicalPath(item.source.path)) } }
            DispatchQueue.main.async {
                if let snapshot { self.fileClipboard.complete(report,snapshot:snapshot) }
                self.isTransferring = false
                let summary = "\(verb)完成：成功 \(report.completed.count) · 跳过 \(report.skipped.count) · 失败 \(report.failures.count)"
                self.setTransferStatus(summary)
                self.controller.runSearch(); self.quickController?.runSearch()
                self.indexer.filesChanged(report.completed.flatMap { [$0.source.path,$0.destination.path] })
                self.modalDepth += 1; defer { self.modalDepth -= 1 }
                var message = summary + "\n目标：\(directory.path)"
                if report.skipped.count > 0 { message += "\n同名文件、重复选择或原地移动会跳过。" }
                if !report.failures.isEmpty {
                    message += "\n\n未完成的文件：\n" + report.failures.prefix(10).map { $0.source.lastPathComponent + "：" + $0.message }.joined(separator:"\n")
                    if report.failures.count > 10 { message += "\n另有 \(report.failures.count - 10) 项失败。" }
                    if mode == .move { message += "\n失败项目不会从待剪切列表移除，可修正问题后重试。" }
                }
                if !self.roots.contains(where:{ isWithin(canonicalPath(directory.path),$0) }) { message += "\n\n目标不在检索目录内；如需搜索目标文件，请把该目录加入检索范围。" }
                let alert = NSAlert(); alert.messageText = "拾音工作台"; alert.informativeText = message
                alert.addButton(withTitle:"完成"); alert.addButton(withTitle:"打开目标文件夹")
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(directory) }
            }
        }
    }
    func saveRoots(_ paths:[String]) { UserDefaults.standard.set(paths,forKey:"SearchRoots"); indexer.configure(paths); controller.reloadScopes(); quickController?.reloadScopes() }
}

if !CommandLine.arguments.contains("--test") {
    // App-only language preference; never changes macOS global language.
    UserDefaults.standard.set(["zh-Hans"],forKey:"AppleLanguages")
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
