import SwiftUI
import AppKit
import AVFoundation
import CryptoKit

final class Model: ObservableObject {
    let gpuName = MetalCompare.deviceName
    let batchRecommendation=GPUBatchRecommendation.current
    @Published var gpuBatchAutomatic=UserDefaults.standard.object(forKey:"gpuBatchAutomatic") as? Bool ?? true {
        didSet{UserDefaults.standard.set(gpuBatchAutomatic,forKey:"gpuBatchAutomatic")}
    }
    @Published var gpuBatchManual=GPUBatchRecommendation.validated(UserDefaults.standard.object(forKey:"gpuBatchManual") as? Int ?? 128) {
        didSet{UserDefaults.standard.set(gpuBatchManual,forKey:"gpuBatchManual")}
    }
    @Published var gpuBatchActual=""
    var gpuBatchLimit:Int {gpuBatchAutomatic ? batchRecommendation.pairs:GPUBatchRecommendation.validated(gpuBatchManual)}
    @Published var fastIndexEnabled=UserDefaults.standard.object(forKey:"fastIndexEnabled") as? Bool ?? true {
        didSet{UserDefaults.standard.set(fastIndexEnabled,forKey:"fastIndexEnabled")}
    }
    @Published var searchSummary=""
    @Published var gpuEnabled = UserDefaults.standard.object(forKey:"gpuEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gpuEnabled,forKey:"gpuEnabled") }
    }
    @Published var hybridEnabled=UserDefaults.standard.object(forKey:"hybridEnabled") as? Bool ?? true {
        didSet {UserDefaults.standard.set(hybridEnabled,forKey:"hybridEnabled")}
    }
    @Published var multithreaded = UserDefaults.standard.bool(forKey: "multithreaded") {
        didSet { UserDefaults.standard.set(multithreaded, forKey: "multithreaded") }
    }
    let availableCores=max(1,ProcessInfo.processInfo.activeProcessorCount)
    @Published var selectedCores=max(1,min(ProcessInfo.processInfo.activeProcessorCount,UserDefaults.standard.object(forKey:"selectedCores") as? Int ?? ProcessInfo.processInfo.activeProcessorCount)) {
        didSet {UserDefaults.standard.set(selectedCores,forKey:"selectedCores")}
    }
    @Published var pairCacheEnabled=UserDefaults.standard.object(forKey:"pairCacheEnabled") as? Bool ?? true {
        didSet {UserDefaults.standard.set(pairCacheEnabled,forKey:"pairCacheEnabled")}
    }
    var workerCount: Int { multithreaded ? max(1,min(availableCores,selectedCores)) : 1 }
    var pairCacheURL:URL {cache.deletingLastPathComponent().appendingPathComponent("pairs-v1.sqlite")}
    func clearPairCache() {
        do {for suffix in ["","-wal","-shm"] {
            let url=URL(fileURLWithPath:pairCacheURL.path+suffix)
            if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
        };status="比对结果缓存已清除，频谱指纹仍保留"} catch {alert("清除失败",error.localizedDescription)}
    }
    @Published var folders: [URL] = []
    @Published var busy = false
    @Published var isPaused=false
    @Published var isStopping=false
    private var resumePhase=""
    func togglePause(){
        guard busy && !isStopping else{return}
        if isPaused {stop.resume();isPaused=false;phase=resumePhase;status="继续处理，进度已保留"}
        else {resumePhase=phase;stop.pause();isPaused=true;phase="已暂停";status="进度已保留；当前原生读取或 GPU 批次会安全收尾，点击继续恢复"}
    }
    func requestStop(){
        guard busy && !isStopping else{return}
        isStopping=true;isPaused=false;stop.set(true)
        phase="正在停止";status="已停止派发新任务，正在保留已完成结果…"
    }
    @Published var status = "添加歌曲或文件夹，开始寻找重复歌曲"
    @Published var progress: Double = 0
    @Published var comparisonStarted=false
    @Published var comparisonDone=0
    @Published var comparisonTotal:Int?=nil
    var progressPercent:String {String(format:"%.1f%%",floor(min(1,max(0,progress))*1000)/10)}
    var comparisonCountText:String {
        if let total=comparisonTotal{return "已完成比对 \(comparisonDone) / \(total) 对"}
        return busy ? "已完成比对 0 / 总数统计中":"已完成比对 0 / 总数未确定"
    }
    @Published var matches: [Match] = [] {didSet {rebuildVisible()}}
    @Published private(set) var shown:[Match]=[]
    @Published var page=0
    let pageSize=100
    var totalPages:Int {max(1,(shown.count+pageSize-1)/pageSize)}
    var pageMatches:[Match] {
        let start=min(max(0,page)*pageSize,shown.count)
        return Array(shown[start..<min(shown.count,start+pageSize)])
    }
    private var visibleFiles=[String:SongPrint]()
    @Published private(set) var selectedBytes:Int64=0
    @Published private(set) var selectedFiles:[SongPrint]=[]
    private func rebuildVisible() {
        shown=matches.filter{Double($0.score)>=threshold};page=0;visibleFiles=[:]
        for m in shown {visibleFiles[m.first.path]=m.first;visibleFiles[m.second.path]=m.second}
        updateSelectedBytes()
    }
    private func updateSelectedBytes(){
        selectedFiles=selection.compactMap{visibleFiles[$0]}.sorted{$0.path<$1.path}
        selectedBytes=selectedFiles.reduce(0){$0+$1.size}
    }
    @Published var selection: Set<String> = [] {didSet {updateSelectedBytes()}}
    @Published var errors: [String] = []
    @Published var threshold: Double = 0.88 {didSet {rebuildVisible()}}
    @Published var scanned = 0
    @Published var total = 0
    let mixer=AudioMixer()
    @Published var showMixer=false
    @Published var hasScanned = false
    @Published var phase = "准备就绪"
    @Published var lastTrash = ""
    private(set) var stop = StopFlag()
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.shiyin.studio/v4-full", isDirectory: true)
    var onFilesChanged:(()->Void)?
    func invalidateAfterFileChange() {
        guard !busy else{return}
        mixer.replace([],matches:[]);matches=[];selection=[];hasScanned=false;comparisonStarted=false
        comparisonTotal=nil;comparisonDone=0;progress=0;gpuBatchActual="";searchSummary=""
        phase="文件位置已变化";status="旧查重结果已清除，请重新选择范围并扫描"
    }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.title = "添加查重歌曲或文件夹"
        panel.message = "选择需要查重的歌曲或音乐文件夹；文件夹将包含子目录。"
        panel.prompt = "添加到查重范围"
        if panel.runModal() == .OK {
            for url in panel.urls where !folders.contains(url) {
                if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true || !StudioInput.songs([url]).isEmpty {folders.append(url)}
            }
        }
    }
    var comparisonCandidates:[SongPrint] {
        let current=Set(mixer.songs.map{$0.path})
        var songs=[String:SongPrint]()
        for m in shown {
            if current.isEmpty || current.contains(m.first.path) || current.contains(m.second.path) {
                for s in [m.first,m.second] where !current.contains(s.path) {songs[s.path]=s}
            }
        }
        return songs.values.sorted{$0.path<$1.path}
    }
    func addComparison(_ song:SongPrint) {
        if !mixer.songs.isEmpty && !comparisonCandidates.contains(where:{$0.path==song.path}) && !mixer.songs.contains(where:{$0.path==song.path}) {
            alert("请选择相似候选", "请添加与当前试听列表匹配的歌曲，或先在试听面板移除原有歌曲。");return
        }
        mixer.add(song,matches:shown)
    }
    func comparePlayback(_ match:Match) {
        mixer.replace([match.first,match.second],matches:shown);showMixer=true
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func alert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.addButton(withTitle: "知道了"); a.runModal()
    }
    func clearCache() {
        do { if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }; status = "指纹缓存已清除，下次扫描将重新分析" }
        catch { alert("清除失败",error.localizedDescription) }
    }
    func scan() {
        guard !folders.isEmpty, !busy else { return }
        searchSummary="";gpuBatchActual=""
        busy = true; hasScanned = false; matches = []; selection = []; errors = []; progress = 0; scanned = 0; total = 0;comparisonStarted=false;comparisonDone=0;comparisonTotal=nil; stop=StopFlag();isPaused=false;isStopping=false
        mixer.replace([],matches:[]); phase = "正在寻找音频文件"; status = "包含子文件夹；不跟随符号链接"
        let roots = folders; let cacheFolder = cache; let cancellation = stop
        let batchLimit=gpuBatchLimit,batchBudget=batchRecommendation.byteBudget
        let batchTelemetry=GPUBatchTelemetry()
        let useFastIndex=fastIndexEnabled
        let useGPU = gpuEnabled && gpuName != nil
        let workers = workerCount
        let hybrid=hybridEnabled && useGPU
        let usePairCache=pairCacheEnabled, databaseURL=pairCacheURL
        let mode = multithreaded ? "多线程（最多 \(workers) 路并行）" : "单线程"
        let relay=ProgressRelay()
        DispatchQueue.global(qos: .utility).async {
            var urls = [URL](); var visited = Set<String>(); var failures = [String]()
            let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.fileResourceIdentifierKey]
            for root in roots {
                if fileKind(root.pathExtension.lowercased())=="audio",AudioEngine.extensions.contains(root.pathExtension.lowercased()),
                   (try? root.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {
                    do {
                        let info=try root.resourceValues(forKeys:Set(keys))
                        if info.isSymbolicLink != true {
                            let identity=(info.fileResourceIdentifier as? NSObject)?.description ?? root.standardizedFileURL.path
                            if visited.insert(identity).inserted{urls.append(root)}
                        }
                    }catch{failures.append("\(root.path)：\(error.localizedDescription)")}
                    continue
                }
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles,.skipsPackageDescendants], errorHandler: { url,error in failures.append("\(url.path)：\(error.localizedDescription)"); return true }) else { failures.append("无法读取：\(root.path)"); continue }
                for case let url as URL in walk {
                    if !cancellation.checkpoint() { break }
                    guard fileKind(url.pathExtension.lowercased())=="audio",AudioEngine.extensions.contains(url.pathExtension.lowercased()) else { continue }
                    do {
                        let info = try url.resourceValues(forKeys:Set(keys))
                        guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                        let identity = (info.fileResourceIdentifier as? NSObject)?.description ?? url.standardizedFileURL.path
                        if visited.insert(identity).inserted { urls.append(url) }
                    } catch { failures.append("\(url.path)：\(error.localizedDescription)") }
                }
            }
            urls.sort { $0.path < $1.path }
            let count = urls.count
            DispatchQueue.main.async { self.total = count; if !self.isPaused && !self.isStopping {self.phase = "正在提取频谱指纹 · \(mode)"} }
            try? FileManager.default.createDirectory(at:cacheFolder,withIntermediateDirectories:true)
            let audioURLs = urls
            let outcomes: [Result<IndexedSong, Error>] = ParallelWork.run(count: count, workers: workers, cancelled: { cancellation.stopped },checkpoint:{cancellation.checkpoint()}, process: { index in
                let url = audioURLs[index]
                do {
                    if !cancellation.checkpoint() { throw CancellationError() }
                    let cacheKey = SHA256.hash(data:Data(url.path.utf8)).map { String(format:"%02x",$0) }.joined()
                    let cacheURL = cacheFolder.appendingPathComponent(cacheKey + ".plist")
                    let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    if let record=IndexedSong.summary(cacheURL,path:url.path,size:size,modified:modified) {return .success(record)}
                    if let bytes = try? Data(contentsOf:cacheURL), let saved = try? PropertyListDecoder().decode(SongPrint.self,from:bytes), saved.size == size, saved.modified == modified, saved.path == url.path {
                        let record=IndexedSong(saved,cacheURL:cacheURL);record.saveSummary();return .success(record)
                    }
                    let value = try AudioEngine().fingerprint(url,cancelled:{!cancellation.checkpoint()})
                    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                    try encoder.encode(value).write(to:cacheURL,options:.atomic)
                    let record=IndexedSong(value,cacheURL:cacheURL);record.saveSummary();return .success(record)
                } catch is CancellationError { return .failure(CancellationError()) }
                catch { return .failure(AudioError.message("\(url.path)：\(error.localizedDescription)")) }
            }, completed: { done, index in
                relay.submit {
                    guard !self.isPaused && !self.isStopping else{return}
                    self.scanned=done
                    self.status = "已处理 \(done) / \(count) · \(audioURLs[index].lastPathComponent)"
                    self.progress = Double(done) / Double(max(count,1))
                }
            })
            var prints = [IndexedSong]()
            for result in outcomes {
                switch result {
                case .success(let value):
                    prints.append(value)
                    if let note = value.song.note { failures.append("【已分析・尾部提示】\(value.song.path)：\(note)") }
                case .failure(let error):
                    if !(error is CancellationError) { failures.append(error.localizedDescription) }
                }
            }
            _=cancellation.checkpoint()
            let analyzedCount = prints.count
            DispatchQueue.main.async { self.scanned = analyzedCount;self.comparisonStarted=true;self.progress=0; if !self.isPaused && !self.isStopping {self.phase = "正在统计比对总数"; self.status = "按时长和整体频谱筛选，建立精确配对清单"} }
            var matches = [Match]()
            let records=prints.sorted{$0.song.duration == $1.song.duration ? $0.song.path<$1.song.path:$0.song.duration<$1.song.duration}
            let sortedPrints=records.map{$0.song}
            let repository=FingerprintRepository()
            let plan:CandidatePlan
            do {
                plan=try CandidatePlan(directory:cacheFolder.deletingLastPathComponent().appendingPathComponent("plans-v1"))
                func fullPlan()throws {
                    try plan.build(songs:sortedPrints,checkpoint:{cancellation.checkpoint()},progress:{done,total in
                        relay.submit {guard !self.isPaused && !self.isStopping else{return};self.phase="正在统计完整比对总数";self.status="已筛选 \(done) / \(total) 个文件批次";self.progress=total>0 ? Double(done)/Double(total):1}
                    })
                }
                var summary="原有完整筛选"
                if useFastIndex {
                    do {
                        let stats=try plan.buildFast(records:records,repository:repository,directory:cacheFolder.deletingLastPathComponent().appendingPathComponent("fast-v1"),checkpoint:{cancellation.checkpoint()},progress:{stage,done,total in
                            relay.submit{guard !self.isPaused && !self.isStopping else{return};self.phase=stage;self.status="已处理 \(done) / \(total) 首";self.progress=total>0 ? Double(done)/Double(total):1}
                        })
                        summary=stats.description
                    } catch is CancellationError {throw CancellationError()}
                    catch {failures.append("【快速索引已回退完整筛选】\(error.localizedDescription)");try fullPlan();summary="快速索引失败，已回退完整筛选"}
                } else {try fullPlan()}
                let finalSummary=summary
                DispatchQueue.main.async{self.searchSummary=finalSummary}

            } catch {
                relay.close();let stopped=cancellation.stopped
                let messages=failures+(stopped ? []:["【比对任务统计失败】\(error.localizedDescription)"])
                DispatchQueue.main.async{self.busy=false;self.isPaused=false;self.isStopping=false;self.hasScanned=true;self.errors=messages;self.phase=stopped ? "扫描已停止":"比对未开始";self.status="配对总数未统计完成，没有把部分任务误报为全部完成";self.progress=0}
                return
            }
            let plannedTotal=plan.count
            DispatchQueue.main.async{self.comparisonTotal=plannedTotal;self.comparisonDone=0;self.progress=0;if !self.isPaused && !self.isStopping{self.phase="正在比对歌曲";self.status="已完成比对 0 / \(plannedTotal) 对"}}
            let comparisonIssues=ScanIssues()
            var pairCache:PairCache?
            if usePairCache {do {pairCache=try PairCache(databaseURL,cancelled:{cancellation.stopped})} catch {failures.append("【缓存未启用】\(error.localizedDescription)")}}
            let comparisonCache=pairCache
            let identities=records.map{$0.identity}
            let results=ComparisonResults(sortedPrints)
            func publishComparison(){
                let current=results.counts(),done=current.cpu+current.gpu+current.cached
                relay.submit{guard !self.isPaused && !self.isStopping else{return}
                    self.gpuBatchActual=batchTelemetry.text()
                    self.comparisonDone=max(self.comparisonDone,done)
                    self.progress=plannedTotal>0 ? Double(self.comparisonDone)/Double(plannedTotal):1
                    self.phase=hybrid ? "CPU + GPU 协同比对":useGPU ? "GPU 比对":"CPU 比对"
                    self.status="CPU \(current.cpu) 对 · GPU \(current.gpu) 对 · 缓存 \(current.cached) 对"
                }
            }
            // Only the single GPU lane initializes and accesses this instance.
            var device:MetalCompare?
            let pipeline=ComparisonPipeline(workers:workers,useGPU:useGPU,hybrid:hybrid,gpuBatchPairs:batchLimit,gpuBatchBytes:batchBudget,cancelled:{cancellation.stopped},checkpoint:{cancellation.checkpoint()},cpu:{pair in
                if !cancellation.checkpoint() {return nil}
                do {
                    let a=try repository.load(records[pair.first]),b=try repository.load(records[pair.second])
                    if let score=AudioEngine().compare(a,b,cancelled:{!cancellation.checkpoint()}) {return PairScore(score:score.score,offset:score.offset)}
                    return cancellation.stopped ? nil:PairScore(score:-1,offset:0)
                } catch {comparisonIssues.record("【比对未完成】\(records[pair.first].song.path)：\(error.localizedDescription)");return nil}
            },gpu:{pairs in
                if device==nil {device=try MetalCompare()}
                let indices=Set(pairs.flatMap{[$0.first,$0.second]}).sorted()
                let local=Dictionary(uniqueKeysWithValues:indices.enumerated().map{($0.element,$0.offset)})
                let songs=try indices.map{index in if !cancellation.checkpoint(){throw CancellationError()};return try repository.load(records[index])}
                let mapped=pairs.map{AudioPair(first:local[$0.first]!,second:local[$0.second]!)}
                return try device!.compare(songs,pairs:mapped,cancelled:{cancellation.stopped})
            },complete:{pairs,scores,backend in
                if case .gpu=backend {batchTelemetry.record(pairs.count)}
                if !cancellation.stopped {comparisonCache?.storeBatch(zip(pairs,scores).map{(identities[$0.0.first],identities[$0.0.second],$0.1)})}
                results.add(pairs,scores:scores,backend:backend)
                publishComparison()
            },failure:{comparisonIssues.record($0)})
            var pending=[ComparisonJob](),pendingBytes=0
            func flush(){if !pending.isEmpty {pipeline.submit(pending);pending=[];pendingBytes=0}}
            var fed=0
            do {
                try plan.forEach(checkpoint:{cancellation.checkpoint()}){pair in
                    fed+=1
                    if let cache=comparisonCache,let score=cache.lookup(identities[pair.first],identities[pair.second]) {results.add([pair],scores:[score],backend:.cache)}
                    else {
                        let bytes=(records[pair.first].frameCount+records[pair.second].frameCount)*48*4
                        if !pending.isEmpty && pendingBytes+bytes>batchBudget {flush()}
                        pending.append(ComparisonJob(pair:pair,bytes:bytes));pendingBytes+=bytes
                        if pending.count>=batchLimit {flush()}
                    }
                    if fed%128==0 {publishComparison()}
                }
                if !cancellation.stopped {flush()}
            } catch is CancellationError {} catch {comparisonIssues.record("【任务清单读取失败】\(error.localizedDescription)")}
            pipeline.finish()
            let finished=results.snapshot();matches=finished.matches
            failures.append(contentsOf:comparisonIssues.take());if !cancellation.stopped {comparisonCache?.prune()}
            let cacheHits=finished.cached
            let backend:String
            if finished.cpu>0 && finished.gpu>0 {backend="CPU + GPU（CPU \(finished.cpu) 对 / GPU \(finished.gpu) 对）"}
            else if finished.gpu>0 {backend="GPU（\(finished.gpu) 对）"}
            else if finished.cpu>0 {backend="CPU \(workers) 路（\(finished.cpu) 对）"}
            else {backend=cacheHits>0 ? "比对缓存":"无需新增比对"}
            if !cancellation.stopped {matches.sort { $0.score == $1.score ? ($0.first.path + $0.second.path) < ($1.first.path + $1.second.path) : $0.score > $1.score }}
            let completedBackend = backend
            let finalMatches = matches; let finalErrors = failures; let cancelled = cancellation.stopped; let successCount = prints.count
            relay.close()
            DispatchQueue.main.async {
                self.matches = finalMatches; self.errors = finalErrors; self.busy = false; self.isPaused=false;self.isStopping=false;self.hasScanned = true
                self.gpuBatchActual=batchTelemetry.text()
                self.comparisonTotal=plannedTotal;self.comparisonDone=finished.cpu+finished.gpu+finished.cached
                self.progress=plannedTotal>0 ? Double(self.comparisonDone)/Double(plannedTotal):(cancelled ? 0:1)
                self.scanned = successCount; self.phase = cancelled ? "扫描已停止" : self.comparisonDone<plannedTotal ? "比对结束（部分失败）":"扫描完成"
                self.status = cancelled ? "当前展示已完成的结果，可重新开始" : "已分析 \(successCount) 首歌曲 · \(finalErrors.count) 个提示 · 比对：\(completedBackend) · 缓存命中 \(cacheHits)"
            }
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "听纹查重报告.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
        var lines = ["相似度,时间偏移秒,文件A,文件B,时长A秒,时长B秒,大小A字节,大小B字节"]
        for match in shown { lines.append([String(format:"%.2f%%",match.score*100),String(match.offset),quote(match.first.path),quote(match.second.path),String(match.first.duration),String(match.second.duration),String(match.first.size),String(match.second.size)].joined(separator:",")) }
        do { try ("\u{FEFF}" + lines.joined(separator:"\r\n")).write(to:url,atomically:true,encoding:.utf8) }
        catch { alert("导出失败",error.localizedDescription) }
    }
    func trash() {
        var files = [String:SongPrint]()
        for match in shown { files[match.first.path] = match.first; files[match.second.path] = match.second }
        let paths = selection.filter { files[$0] != nil }.sorted()
        guard !paths.isEmpty else { return }
        // Protect a surviving copy in every connected component, not just each row.
        var adjacency = [String:Set<String>]()
        for m in shown { adjacency[m.first.path, default: []].insert(m.second.path); adjacency[m.second.path, default: []].insert(m.first.path) }
        var seen = Set<String>()
        for path in paths where !seen.contains(path) {
            var stack = [path]; var component = Set<String>()
            while let next = stack.popLast() { if component.insert(next).inserted { stack.append(contentsOf:adjacency[next] ?? []) } }
            seen.formUnion(component)
            if component.allSatisfy({selection.contains($0)}) { alert("请至少保留一份", "某一组相似歌曲的所有文件都已勾选。请取消勾选一份，再继续。"); return }
        }
        let panel = NSAlert(); panel.alertStyle = .warning; panel.messageText = "将 \(paths.count) 个文件移到废纸篓？"
        panel.informativeText = "频谱相似不代表完全相同，请先试听。不会清空废纸篓。\n\n" + paths.joined(separator:"\n")
        let text = NSTextView(frame:NSRect(x:0,y:0,width:580,height:220)); text.string = paths.joined(separator:"\n\n"); text.isEditable = false; text.font = .systemFont(ofSize:11)
        let scroll = NSScrollView(frame:text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true; panel.accessoryView = scroll
        panel.informativeText = "频谱相似不代表完全相同，请先试听。以下文件将移到废纸篓，不会永久删除。"
        panel.addButton(withTitle:"移到废纸篓"); panel.addButton(withTitle:"取消")
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        mixer.stop()
        var removed = Set<String>(); var failures = [String](); var records = [[String:String]]()
        for path in paths {
            guard let song = files[path] else { continue }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath:path)
                guard (attrs[.size] as? NSNumber)?.int64Value == song.size, (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 == song.modified else { throw AudioError.message("文件已变化，请重新扫描") }
                let componentPeers = adjacency[path] ?? []
                guard componentPeers.contains(where:{ !selection.contains($0) && FileManager.default.fileExists(atPath:$0) }) else { throw AudioError.message("没有可确认仍存在的直接匹配副本，请取消部分勾选") }
                var trashURL: NSURL?
                try FileManager.default.trashItem(at:URL(fileURLWithPath:path),resultingItemURL:&trashURL)
                removed.insert(path); records.append(["original":path,"trash":trashURL?.path ?? "","time":ISO8601DateFormatter().string(from:Date())])
            } catch { failures.append("\(path)：\(error.localizedDescription)") }
        }
        let logs = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("拾音工作台",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
            let log = logs.appendingPathComponent("移除记录-\(Int(Date().timeIntervalSince1970)).json")
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:log,options:.atomic)
        } catch { failures.append("无法保存移动记录：\(error.localizedDescription)") }
        for path in removed {mixer.remove(path,matches:shown)}
        matches.removeAll { removed.contains($0.first.path) || removed.contains($0.second.path) }; selection.subtract(removed)
        if !removed.isEmpty {onFilesChanged?()}
        lastTrash = "已移到废纸篓：\(removed.count) 个文件"
        if !failures.isEmpty { alert("部分操作未完成",failures.joined(separator:"\n")) }
    }
}

func sizeText(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount:size,countStyle:.file) }
func durationText(_ seconds: Double) -> String { String(format:"%d:%02d",Int(seconds)/60,Int(seconds)%60) }
struct Spectrum: View {
    let values: [Float]
    var body: some View {
        Canvas { context, size in
            guard let low = values.min(), let high = values.max(), high > low else { return }
            let width = size.width / CGFloat(values.count)
            for (i,v) in values.enumerated() {
                let height = CGFloat((v-low)/(high-low))*size.height*0.9+2
                let rect = CGRect(x:CGFloat(i)*width,y:size.height-height,width:max(1,width-2),height:height)
                context.fill(Path(roundedRect:rect,cornerRadius:1),with:.color(StudioTheme.accent.opacity(0.65)))
            }
        }.frame(height:36).accessibilityLabel("歌曲平均频谱")
    }
}
struct SongRow: View {
    @ObservedObject var model: Model
    let song: SongPrint
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            Toggle("选择待移除文件",isOn:Binding(get:{model.selection.contains(song.path)},set:{ if $0 { model.selection.insert(song.path) } else { model.selection.remove(song.path) } })).labelsHidden().toggleStyle(.checkbox).padding(.top,4)
            VStack(alignment:.leading,spacing:5) {
                Text(song.name).font(.system(size:14,weight:.semibold)).textSelection(.enabled)
                Text(song.path).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                HStack { Text("\(durationText(song.duration))  ·  \(sizeText(song.size))  ·  \(URL(fileURLWithPath:song.path).pathExtension.uppercased())").font(.caption).foregroundStyle(.secondary); Spacer() }
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(spacing:7) {
                Button { model.addComparison(song) } label: { Label("加入对比",systemImage:"plus.circle") }.frame(width:80)
                Button("定位文件") { model.reveal(song.path) }.buttonStyle(.link).font(.caption)
            }
        }.padding(12).background(model.selection.contains(song.path) ? StudioTheme.selection : StudioTheme.row,in:RoundedRectangle(cornerRadius:6))
    }
}
struct ContentView: View {
    @ObservedObject var model:Model
    @State var showErrors = false
    @State var showBatch = false
    @State var showSelected = false
    var body: some View {
        HStack(spacing:0) {
            ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Label("查重设置",systemImage:"slider.horizontal.3").font(.headline)
                Divider()
                HStack { Text("查重范围").font(.headline); Spacer(); Button { model.addFolder() } label: { Image(systemName:"plus") }.disabled(model.busy) }
                ScrollView {
                    VStack(spacing:9) {
                        if model.folders.isEmpty { Text("可从搜索页送入选中的歌曲，\n或添加文件夹扫描子目录。").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical) }
                        ForEach(model.folders,id:\.path) { folder in
                            HStack { Image(systemName:"folder.fill").foregroundStyle(StudioTheme.accent); VStack(alignment:.leading) { Text(folder.lastPathComponent).font(.subheadline); Text(folder.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button { model.folders.removeAll{$0 == folder} } label:{ Image(systemName:"xmark") }.buttonStyle(.plain).disabled(model.busy) }.padding(9).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }.frame(height:110)
                VStack(alignment:.leading,spacing:10) {
                    Text("匹配严格程度").font(.headline)
                    Slider(value:$model.threshold,in:0.72...0.98,step:0.01)
                    HStack { Text("更多候选"); Spacer(); Text("\(Int(model.threshold*100))%"); Spacer(); Text("更严格") }.font(.caption2).foregroundStyle(.secondary)
                    Text("相似度是筛选分数，不是准确率。建议先用 88%，再试听确认。").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("音频只在本机处理\n频谱指纹会缓存，方便下次扫描\n不会自动选择或删除文件").font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                Button("清除指纹缓存") { model.clearCache() }.buttonStyle(.link).font(.caption).disabled(model.busy)
                VStack(alignment:.leading,spacing:8) {
                    Text("候选检索方式").font(.headline)
                    Picker("候选检索方式",selection:$model.fastIndexEnabled){
                        Text("快速索引（试用）").tag(true)
                        Text("原有完整筛选").tag(false)
                    }.labelsHidden().disabled(model.busy)
                    Text("快速索引先匹配整首的时序指纹，再复核候选。可能漏检，可切换完整筛选对照。").font(.caption2).foregroundStyle(.secondary)
                    Text("扫描模式").font(.headline)
                    Picker("扫描模式", selection: $model.multithreaded) {
                        Text("单线程").tag(false)
                        Text("多线程").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
                    Stepper("CPU 并发：\(model.selectedCores) / \(model.availableCores)",value:$model.selectedCores,in:1...model.availableCores)
                        .disabled(model.busy || !model.multithreaded)
                    Text("可使用全部逻辑核心；这是任务并发数，不是核心绑定。").font(.caption2).foregroundStyle(.secondary)
                    Toggle("复用比对结果缓存",isOn:$model.pairCacheEnabled).disabled(model.busy)
                    Button("清除比对缓存") {model.clearPairCache()}.font(.caption).disabled(model.busy)
                    Toggle("GPU 加速比对",isOn:$model.gpuEnabled)
                        .disabled(model.busy || model.gpuName == nil)
                    Toggle("自动推荐 GPU 批次",isOn:$model.gpuBatchAutomatic).disabled(model.busy || !model.gpuEnabled || model.gpuName==nil)
                    if !model.gpuBatchAutomatic {
                        Picker("每批最多",selection:$model.gpuBatchManual){
                            ForEach(GPUBatchRecommendation.choices,id:\.self){count in Text("\(count) 对").tag(count)}
                        }.disabled(model.busy || !model.gpuEnabled || model.gpuName==nil)
                    }
                    Text("芯片：\(model.batchRecommendation.chip)\n建议每批最多 \(model.batchRecommendation.pairs) 对 · 当前上限 \(model.gpuBatchLimit) 对").font(.caption).foregroundStyle(.secondary)
                    Text(model.batchRecommendation.reason).font(.caption2).foregroundStyle(.secondary)
                    Text("按歌曲数据量缩小批次；输入预算约 \(model.batchRecommendation.byteBudget/1024/1024) MiB。批次较大可能增加等待时间。").font(.caption2).foregroundStyle(.secondary)
                    Toggle("CPU + GPU 协同比对",isOn:$model.hybridEnabled)
                        .disabled(model.busy || !model.gpuEnabled || model.gpuName==nil)
                    Text("协同时 CPU 处理零散配对，GPU 处理批次；任务不会重复。可用上方并发数限制 CPU 占用。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(model.gpuName.map { "GPU：\($0)" } ?? "未发现可用 GPU，使用 CPU")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(model.multithreaded ? "CPU 最多 \(model.workerCount) 路并行；可选 CPU/GPU 协同。" : "CPU 逐首分析；协同时保留 1 路 CPU 比对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(action:{ model.busy ? model.requestStop() : model.scan() }) { HStack { Image(systemName:model.busy ? "stop.circle" : "waveform.path"); Text(model.isStopping ? "正在停止…":model.busy ? "停止扫描" : "开始频谱扫描").fontWeight(.semibold) }.frame(maxWidth:.infinity).padding(.vertical,8) }.buttonStyle(.borderedProminent).tint(StudioTheme.accent).disabled(model.folders.isEmpty || model.isStopping)
                if model.busy {
                    Button(model.isPaused ? "继续扫描 / 比对":"暂停扫描 / 比对"){model.togglePause()}
                        .disabled(model.isStopping).frame(maxWidth:.infinity)
                }
            }.padding(24)
            }.frame(width:260).background(StudioTheme.sidebar)
            Divider()
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    VStack(alignment:.leading,spacing:6) { Text("歌曲查重").font(.system(size:25,weight:.bold)); Text("频谱形状 + 时间变化 · 支持不同格式和码率的候选匹配").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Button("批量勾选") {showBatch=true}.disabled(model.shown.isEmpty || model.busy)
                    Button("试听对比") {model.showMixer=true}.disabled(model.shown.isEmpty || model.busy)
                    Button { model.export() } label: { Label("导出报告",systemImage:"square.and.arrow.up") }.disabled(model.shown.isEmpty || model.busy)
                }
                HStack(spacing:14) {
                    stat("成功分析", "\(model.scanned)","首歌曲")
                    stat("相似候选", "\(model.shown.count)","对，可能交叉重复")
                    stat("已选择", "\(model.selection.count)",sizeText(model.selectedBytes))
                }
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(model.phase).font(.subheadline.bold()); Spacer(); if model.busy { ProgressView().controlSize(.small) }; if !model.errors.isEmpty { Button("查看 \(model.errors.count) 个问题") { showErrors = true }.buttonStyle(.link).font(.caption) } }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !model.gpuBatchActual.isEmpty {Text(model.gpuBatchActual).font(.caption).foregroundStyle(.secondary)}
                    if !model.searchSummary.isEmpty {Text(model.searchSummary).font(.caption).foregroundStyle(.secondary)}
                    if model.comparisonStarted {Text(model.comparisonCountText).font(.subheadline.bold()).monospacedDigit()}
                    if model.busy || model.hasScanned {
                        HStack(spacing:12){ProgressView(value:min(1,max(0,model.progress))).tint(StudioTheme.accent)
                            Text(model.progressPercent).font(.caption.bold()).monospacedDigit().frame(width:58,alignment:.trailing)}
                    }
                }.padding(14).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:8))
                if model.shown.isEmpty {
                    Spacer()
                    VStack(spacing:16) {
                        Image(systemName: model.busy ? "waveform" : "music.note.magnifyingglass").font(.system(size:54,weight:.light)).foregroundStyle(StudioTheme.accent.opacity(0.7))
                        Text(model.busy ? "正在聆听你的音乐库" : model.hasScanned ? "当前阈值下没有相似候选" : "把重复的旋律找出来").font(.title2.bold())
                        Text(model.hasScanned ? "可降低匹配阈值，或添加其他音乐文件夹。" : "在左侧添加文件夹，点击开始扫描。\n扫描结果可试听、定位和手动勾选。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing:16) {
                            ForEach(model.pageMatches) { match in
                                VStack(alignment:.leading,spacing:10) {
                                    HStack { Label(match.score >= 0.94 ? "高度相似" : "建议试听",systemImage:"waveform").font(.subheadline.bold()).foregroundStyle(match.score >= 0.94 ? StudioTheme.accent : Color.orange); Spacer(); Text(String(format:"%.1f%%",match.score*100)).font(.system(size:22,weight:.bold,design:.rounded)); Text("偏移 \(match.offset) 秒").font(.caption).foregroundStyle(.secondary);Button("对比这两首") {model.comparePlayback(match)} }
                                    HStack(spacing:14) { Spectrum(values:match.first.spectrum); Spectrum(values:match.second.spectrum) }.padding(.bottom,4)
                                    SongRow(model:model,song:match.first)
                                    SongRow(model:model,song:match.second)
                                }.padding(16).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(StudioTheme.border))
                            }
                        }
                    }.id(model.page)
                }
                if !model.shown.isEmpty {
                    HStack {
                        Button("上一页"){model.page-=1}.disabled(model.page==0)
                        Text("第 \(model.page+1) / \(model.totalPages) 页 · 每页最多 100 对 · 共 \(model.shown.count) 对").font(.caption).foregroundStyle(.secondary)
                        Button("下一页"){model.page+=1}.disabled(model.page+1>=model.totalPages)
                    }
                }
                HStack {
                    VStack(alignment:.leading,spacing:4) { Text(model.lastTrash.isEmpty ? "先试听，再决定保留哪一份" : model.lastTrash).font(.subheadline.bold()); Text("勾选表示待移除 · 每组至少保留一份 · 不清空废纸篓").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("查看已勾选 (\(model.selection.count))"){showSelected=true}.disabled(model.selection.isEmpty || model.busy)
                    Button { model.trash() } label:{ Label("移到废纸篓 (\(model.selection.count))",systemImage:"trash") }.tint(.orange).disabled(model.selection.isEmpty || model.busy)
                }.padding(14).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:8))
                Text("分析整首音频 · 允许前后约 20 秒偏移 · 变速、移调、现场和不同混音版本可能无法匹配").font(.caption2).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity).background(StudioTheme.content)
        }.frame(minWidth:1050,minHeight:760)
        .sheet(isPresented:$showSelected) {SelectedFilesView(model:model)}
        .sheet(isPresented:$showBatch) {BatchSelectionView(model:model)}
        .sheet(isPresented:$model.showMixer) {MixerView(model:model,mixer:model.mixer)}
        .sheet(isPresented:$showErrors) { VStack(alignment:.leading) { Text("读取提示和跳过记录").font(.title2.bold()); ScrollView { Text(model.errors.joined(separator:"\n\n")).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }; Button("关闭") { showErrors = false } }.padding(24).frame(width:750,height:480) }
        .onChange(of:model.threshold) { model.selection = [] }
    }
    func stat(_ title: String,_ value: String,_ caption: String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.caption).foregroundStyle(.secondary); HStack(alignment:.firstTextBaseline) { Text(value).font(.system(size:24,weight:.semibold,design:.rounded)); Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:8))
    }
}
