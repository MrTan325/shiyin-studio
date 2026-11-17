import Foundation
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    var changed: (([String]) -> Void)?
    @discardableResult func start(paths: [String]) -> Bool {
        stop(); guard !paths.isEmpty else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let items = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var result = items
            for i in 0..<count {
                if flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { result = ["__rescan__"]; break }
            }
            watcher.changed?(result)
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue.main); return FSEventStreamStart(stream) }
        return false
    }
    func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil }
    deinit { stop() }
}

final class Indexer {
    let db: Database
    private let queue = DispatchQueue(label: "MediaSearch.index", qos: .utility)
    private let mediaQueue = DispatchQueue(label: "MediaSearch.media", qos: .utility)
    private let watcher = FileWatcher()
    private let stateLock = NSLock()
    private var roots = [String]()
    private var revision = 0
    private var mediaRunning = false
    private var debounce: DispatchWorkItem?
    private var pendingPaths = Set<String>()
    private var polling: Timer?
    private var refreshScheduled = false
    private let excluded: String
    var status: ((String) -> Void)?
    var updated: (() -> Void)?
    init(db: Database, excluded: String) { self.db = db; self.excluded = canonicalPath(excluded) }
    private func notify(_ message: String) { DispatchQueue.main.async { self.status?(message) } }
    private func refresh() {
        DispatchQueue.main.async {
            guard !self.refreshScheduled else { return }; self.refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refreshScheduled = false; self.updated?() }
        }
    }
    private func finishMedia() { stateLock.lock(); mediaRunning = false; stateLock.unlock() }
    func configure(_ paths: [String]) {
        let normalized = paths.map { canonicalPath($0) }.sorted { $0.count < $1.count }
        var unique = [String]()
        for path in normalized where !unique.contains(where: { isWithin(path, $0) }) { unique.append(path) }
        stateLock.lock(); roots = unique; revision += 1; let rev = revision; stateLock.unlock()
        watcher.changed = { [weak self] paths in self?.schedule(paths) }
        polling?.invalidate(); polling = nil
        if !watcher.start(paths: unique) {
            notify("文件事件服务不可用，将每 30 秒同步索引")
            polling = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rescan() }
        }
        queue.async { [self] in
            db.retainRoots(unique)
            for root in unique { scan(root: root, subtree: root, revision: rev) }
            refresh(); startMedia()
        }
    }
    func filesChanged(_ paths:[String]) { schedule(paths) }
    func rescan() { stateLock.lock(); let paths = roots; stateLock.unlock(); configure(paths) }
    func retryMedia() { mediaQueue.async { self.db.retryMedia(); self.startMedia() } }
    private func active(_ rev: Int) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return revision == rev }
    private func schedule(_ paths: [String]) {
        pendingPaths.formUnion(paths.map { $0 == "__rescan__" ? $0 : canonicalPath($0) }); debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }; let paths = self.pendingPaths; self.pendingPaths.removeAll()
            self.stateLock.lock(); let roots = self.roots; let rev = self.revision; self.stateLock.unlock()
            self.queue.async {
                if paths.contains("__rescan__") { for root in roots { self.scan(root:root,subtree:root,revision:rev) } }
                else {
                    let ordered = paths.sorted { $0.count < $1.count }; var handled = [String]()
                    for path in ordered {
                        guard self.active(rev), !path.hasPrefix(self.excluded), !handled.contains(where: { isWithin(path, $0) }) else { continue }
                        guard let root = roots.first(where: { isWithin(path, $0) }) else { continue }
                        self.scan(root:root,subtree:path,revision:rev); handled.append(path)
                    }
                }
                self.refresh(); self.startMedia()
            }
        }
        debounce = item; DispatchQueue.main.asyncAfter(deadline:.now()+1.2,execute:item)
    }
    private func scan(root: String, subtree: String, revision rev: Int) {
        guard active(rev), !subtree.hasPrefix(excluded) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:subtree,isDirectory:&isDirectory) else {
            // Preserve an offline volume/root; remove a missing child only if its root remains reachable.
            if subtree != root && FileManager.default.isReadableFile(atPath:root) { db.remove(path:subtree) }
            notify("目录离线或文件已移除：\(URL(fileURLWithPath:subtree).lastPathComponent)"); return
        }
        let generation = UUID().uuidString
        let keys: [URLResourceKey] = [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.isPackageKey]
        var batch = [FileRecord](); var count = 0; var failed = false
        func add(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys:Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { return }
            let ext = url.pathExtension.lowercased()
            batch.append(FileRecord(path:url.path,name:url.lastPathComponent,ext:ext,kind:fileKind(ext),size:Int64(v.fileSize ?? 0),modified:v.contentModificationDate?.timeIntervalSince1970 ?? 0))
            count += 1
            if batch.count >= 300 { db.upsert(batch,root:root,generation:generation); batch.removeAll(keepingCapacity:true); notify("正在建立索引 · \(count.formatted()) 个文件 · \(URL(fileURLWithPath:root).lastPathComponent)"); refresh() }
        }
        if isDirectory.boolValue {
            guard let enumerator = FileManager.default.enumerator(at:URL(fileURLWithPath:subtree),includingPropertiesForKeys:keys,options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{ _,_ in failed = true; return true }) else { notify("无法读取目录：\(subtree)"); return }
            for case let url as URL in enumerator {
                guard active(rev) else { return }
                if url.path.hasPrefix(excluded) { enumerator.skipDescendants(); continue }
                add(url)
            }
        } else { add(URL(fileURLWithPath:subtree)) }
        guard active(rev) else { return }
        if !batch.isEmpty { db.upsert(batch,root:root,generation:generation) }
        if !failed { db.finishScan(root:root,subtree:subtree,generation:generation) }
        notify(failed ? "索引已更新，部分目录无读取权限；请检查系统隐私设置" : "文件索引已更新 · 后台读取媒体信息")
    }
    private func startMedia() {
        stateLock.lock(); if mediaRunning { stateLock.unlock(); return }; mediaRunning = true; stateLock.unlock()
        mediaQueue.async { [self] in
          Task {
            while true {
                let pending = db.pending()
                if pending.isEmpty { break }
                for file in pending {
                    let info = await MediaReader.read(file)
                    db.updateMedia(path:file.path,modified:file.modified,size:file.size,info:info)
                }
                refresh()
            }
            finishMedia()
            refresh(); notify("就绪 · 文件变化自动更新 · 空格预览")
          }
        }
    }
}
